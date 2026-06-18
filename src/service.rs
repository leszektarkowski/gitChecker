//! Windows Service Control Manager (SCM) integration. Compiled only on Windows.
//!
//! When the binary is launched as `gitchecker.exe --service` (how the install
//! script registers it), `main` calls [`run`], which hands the process to the
//! SCM dispatcher. The dispatcher invokes `service_main`, which reports the
//! service RUNNING, drives the normal server via [`crate::run_server`], and
//! cleanly reports STOPPED when the SCM asks us to stop.

use anyhow::Result;
use std::ffi::OsString;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Notify;
use windows_service::service::{
    ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
    ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::{define_windows_service, service_dispatcher};

/// Must match the name the service is registered under (see install-service.ps1).
pub const SERVICE_NAME: &str = "gitchecker";

/// We are the only process in our own service.
const SERVICE_TYPE: ServiceType = ServiceType::OWN_PROCESS;

/// Connect to the SCM and start dispatching. Blocks until the service stops.
pub fn run() -> Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
    Ok(())
}

// Generates the `extern "system"` trampoline the SCM calls, which forwards to
// `service_main` below.
define_windows_service!(ffi_service_main, service_main);

fn service_main(_arguments: Vec<OsString>) {
    if let Err(e) = run_service() {
        // There is no console attached to a service; surface to stderr in case
        // it's been redirected, and let the runtime exit non-zero.
        eprintln!("gitchecker service error: {e:?}");
    }
}

fn run_service() -> Result<()> {
    // Resolves when the SCM sends Stop/Shutdown. `notify_one` stores a permit, so
    // a stop arriving before the server starts awaiting is not lost.
    let shutdown = Arc::new(Notify::new());

    let handler_shutdown = shutdown.clone();
    let event_handler = move |control_event| -> ServiceControlHandlerResult {
        match control_event {
            ServiceControl::Stop | ServiceControl::Shutdown => {
                handler_shutdown.notify_one();
                ServiceControlHandlerResult::NoError
            }
            // Required: report we're alive when interrogated.
            ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
            _ => ServiceControlHandlerResult::NotImplemented,
        }
    };

    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;

    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Running,
        controls_accepted: ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    // Run the server until the SCM asks us to stop.
    let signal = shutdown.clone();
    let result = crate::run_server(async move { signal.notified().await });

    status_handle.set_service_status(ServiceStatus {
        service_type: SERVICE_TYPE,
        current_state: ServiceState::Stopped,
        controls_accepted: ServiceControlAccept::empty(),
        exit_code: ServiceExitCode::Win32(if result.is_ok() { 0 } else { 1 }),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    })?;

    result
}
