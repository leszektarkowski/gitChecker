//! HTTP API (axum). Read-only status endpoints plus manual triggers for the
//! background scan/check loops.

use crate::config::Config;
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

/// Shared state handed to every request.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    /// Config, for the scan roots used by `POST /scan`.
    pub cfg: Arc<Config>,
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

/// Synchronously re-discover repos under the configured roots, then check them,
/// and return once done — so a client that POSTs here can immediately GET the
/// updated list including any newly found repos.
async fn trigger_scan(State(state): State<AppState>) -> StatusCode {
    if let Err(e) = crate::run_scan(&state.db, &state.cfg).await {
        tracing::error!(error = %e, "manual scan failed");
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    crate::check_all(&state.db).await;
    StatusCode::OK
}

/// Synchronously re-inspect every repo and return once done, so a client that
/// POSTs here can immediately GET fresh status.
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
