//! Configuration: loaded from a TOML file, with sensible defaults written out
//! on first run. Intervals are expressed in seconds for easy hand-editing.

use anyhow::{Context, Result};
use directories::{BaseDirs, ProjectDirs};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Directories to recursively scan for `.git` folders.
    pub scan_roots: Vec<PathBuf>,
    /// Directory names to never descend into during a scan.
    pub scan_excludes: Vec<String>,

    /// How often to re-discover repositories, in seconds (default: 1 day).
    pub scan_interval_secs: u64,
    /// How often to recompute local status, in seconds (default: 5 min).
    pub check_interval_secs: u64,
    /// How often to `git fetch` each repo, in seconds (default: 30 min).
    pub fetch_interval_secs: u64,
    /// Whether to perform network fetches at all.
    pub fetch_enabled: bool,

    /// Address the HTTP API listens on.
    pub listen_addr: SocketAddr,
}

impl Default for Config {
    fn default() -> Self {
        // Default scan root is ~/code; fall back to ~ if home is unknown.
        let default_root = BaseDirs::new()
            .map(|d| d.home_dir().join("code"))
            .unwrap_or_else(|| PathBuf::from("."));

        Config {
            scan_roots: vec![default_root],
            scan_excludes: vec![
                "node_modules".into(),
                "target".into(),
                "vendor".into(),
                ".cache".into(),
            ],
            scan_interval_secs: 24 * 60 * 60,
            check_interval_secs: 5 * 60,
            fetch_interval_secs: 30 * 60,
            fetch_enabled: true,
            listen_addr: "127.0.0.1:7878".parse().unwrap(),
        }
    }
}

impl Config {
    pub fn scan_interval(&self) -> Duration {
        Duration::from_secs(self.scan_interval_secs)
    }
    pub fn check_interval(&self) -> Duration {
        Duration::from_secs(self.check_interval_secs)
    }
    pub fn fetch_interval(&self) -> Duration {
        Duration::from_secs(self.fetch_interval_secs)
    }

    /// Resolve `~` in scan roots to the user's home directory.
    pub fn resolved_scan_roots(&self) -> Vec<PathBuf> {
        let home = BaseDirs::new().map(|d| d.home_dir().to_path_buf());
        self.scan_roots
            .iter()
            .map(|p| match (p.strip_prefix("~"), &home) {
                (Ok(rest), Some(home)) => home.join(rest),
                _ => p.clone(),
            })
            .collect()
    }
}

/// Locate the platform config directory for gitchecker.
fn project_dirs() -> Result<ProjectDirs> {
    ProjectDirs::from("", "", "gitchecker")
        .context("could not determine a home directory for config/data")
}

/// Default config file path (`~/.config/gitchecker/config.toml` on Linux/macOS).
pub fn config_path() -> Result<PathBuf> {
    Ok(project_dirs()?.config_dir().join("config.toml"))
}

/// Default SQLite database path.
pub fn db_path() -> Result<PathBuf> {
    Ok(project_dirs()?.data_dir().join("state.db"))
}

/// Load config from `path`, creating it with defaults if it does not exist.
pub fn load_or_init(path: &PathBuf) -> Result<Config> {
    if path.exists() {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading config {}", path.display()))?;
        let cfg: Config =
            toml::from_str(&text).with_context(|| format!("parsing config {}", path.display()))?;
        Ok(cfg)
    } else {
        let cfg = Config::default();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating config dir {}", parent.display()))?;
        }
        let text = toml::to_string_pretty(&cfg)?;
        std::fs::write(path, text)
            .with_context(|| format!("writing default config {}", path.display()))?;
        Ok(cfg)
    }
}
