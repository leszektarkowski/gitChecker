//! HTTP API (axum). Read-only status endpoints plus manual triggers for the
//! background scan/check loops.

use crate::db::Db;
use crate::model::Summary;
use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use std::sync::Arc;
use tokio::sync::Notify;

/// Shared state handed to every request.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    /// Wake the discovery loop (POST /scan).
    pub scan_notify: Arc<Notify>,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/repos", get(list_repos))
        .route("/repos/{id}", get(get_repo))
        .route("/summary", get(summary))
        .route("/scan", post(trigger_scan))
        .route("/check", post(trigger_check))
        .with_state(state)
}

async fn healthz() -> &'static str {
    "ok"
}

async fn list_repos(State(state): State<AppState>) -> Result<impl IntoResponse, ApiError> {
    let repos = state.db.list_statuses()?;
    Ok(Json(repos))
}

async fn summary(State(state): State<AppState>) -> Result<impl IntoResponse, ApiError> {
    let repos = state.db.list_statuses()?;
    Ok(Json(Summary::from_statuses(&repos)))
}

async fn get_repo(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<impl IntoResponse, ApiError> {
    match state.db.get_status(&id)? {
        Some(status) => Ok(Json(status)),
        None => Err(ApiError::NotFound),
    }
}

async fn trigger_scan(State(state): State<AppState>) -> StatusCode {
    state.scan_notify.notify_one();
    StatusCode::ACCEPTED
}

/// Synchronously re-inspect every repo and return once done, so a client that
/// POSTs here can immediately GET fresh status. (Contrast `/scan`, which stays
/// fire-and-forget.)
async fn trigger_check(State(state): State<AppState>) -> StatusCode {
    crate::check_all(&state.db).await;
    StatusCode::OK
}

/// Minimal error type mapping internal failures to HTTP responses.
enum ApiError {
    NotFound,
    Internal(anyhow::Error),
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        ApiError::Internal(e)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        match self {
            ApiError::NotFound => (StatusCode::NOT_FOUND, "repo not found").into_response(),
            ApiError::Internal(e) => {
                tracing::error!(error = %e, "request failed");
                (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response()
            }
        }
    }
}
