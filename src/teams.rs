use futures_util::{SinkExt, StreamExt};
use log::{debug, info, warn};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

/// Default endpoint of the Microsoft Teams third-party app API.
const DEFAULT_TEAMS_API_URL: &str = "ws://127.0.0.1:8124";
/// Environment variable overriding the Teams API endpoint (used by tests).
const TEAMS_API_URL_ENV: &str = "YFT_TEAMS_API_URL";
/// Environment variable overriding the pairing token file location (used by tests).
const TEAMS_TOKEN_PATH_ENV: &str = "YFT_TEAMS_TOKEN_PATH";

const RECONNECT_MIN: Duration = Duration::from_secs(1);
const RECONNECT_MAX: Duration = Duration::from_secs(10);

/// Snapshot of the Teams meeting state as reported by the Teams local API.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct TeamsState {
    /// Whether the plugin is connected to the Teams local API.
    pub connected: bool,
    /// Whether the user is currently in a meeting.
    pub in_meeting: bool,
    /// Whether the Teams microphone is muted.
    pub is_muted: bool,
    /// Whether the Teams camera is on.
    pub is_video_on: bool,
    /// Whether Teams currently permits toggling mute.
    pub can_toggle_mute: bool,
    /// Whether Teams currently permits toggling video.
    pub can_toggle_video: bool,
}

/// `meetingUpdate.meetingState` payload from Teams.
#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct MeetingState {
    is_in_meeting: bool,
    is_muted: bool,
    is_video_on: bool,
}

/// `meetingUpdate.meetingPermissions` payload from Teams.
#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct MeetingPermissions {
    can_toggle_mute: bool,
    can_toggle_video: bool,
}

/// `meetingUpdate` payload from Teams.
#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct MeetingUpdate {
    meeting_state: MeetingState,
    meeting_permissions: MeetingPermissions,
}

/// Outgoing action request sent to Teams.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActionRequest<'a> {
    action: &'a str,
    parameters: Value,
    request_id: u64,
}

/// Client for the Microsoft Teams third-party app API (protocol 2.0.0).
///
/// Maintains a persistent WebSocket connection to Teams, reconnecting while
/// Teams is unavailable, and publishes meeting state changes via a watch channel.
pub struct TeamsController {
    state: watch::Sender<TeamsState>,
    commands: mpsc::UnboundedSender<String>,
    next_request_id: AtomicU64,
}

impl TeamsController {
    /// Creates the controller and spawns its connection task on the current Tokio runtime.
    pub fn new() -> Arc<Self> {
        let (state_tx, _) = watch::channel(TeamsState::default());
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        let controller = Arc::new(Self {
            state: state_tx,
            commands: cmd_tx,
            next_request_id: AtomicU64::new(1),
        });
        tokio::spawn(run_connection(controller.clone(), cmd_rx));
        controller
    }

    /// Returns the latest known Teams state.
    pub fn get_status(&self) -> TeamsState {
        self.state.borrow().clone()
    }

    /// Subscribes to Teams state changes.
    pub fn subscribe(&self) -> watch::Receiver<TeamsState> {
        self.state.subscribe()
    }

    /// Toggles the Teams camera. Returns false if Teams is not connected.
    pub fn toggle_video(&self) -> bool {
        self.send_action("toggle-video")
    }

    /// Toggles the Teams microphone mute. Returns false if Teams is not connected.
    pub fn toggle_mute(&self) -> bool {
        self.send_action("toggle-mute")
    }

    fn send_action(&self, action: &str) -> bool {
        if !self.state.borrow().connected {
            warn!("[Teams] Cannot send '{}': not connected to Teams", action);
            return false;
        }
        let request = ActionRequest {
            action,
            parameters: Value::Object(Default::default()),
            request_id: self.next_request_id.fetch_add(1, Ordering::Relaxed),
        };
        match serde_json::to_string(&request) {
            Ok(json) => self.commands.send(json).is_ok(),
            Err(_) => false,
        }
    }

    fn update_state(&self, f: impl FnOnce(&mut TeamsState)) {
        self.state.send_if_modified(|s| {
            let before = s.clone();
            f(s);
            *s != before
        });
    }

    fn handle_message(&self, text: &str) {
        let parsed: Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => {
                warn!("[Teams] Error parsing message: {:?}", e);
                return;
            }
        };

        if let Some(token) = parsed.get("tokenRefresh").and_then(|v| v.as_str()) {
            info!("[Teams] Received pairing token");
            save_token(token);
        }

        if let Some(update) = parsed.get("meetingUpdate") {
            let update: MeetingUpdate = match serde_json::from_value(update.clone()) {
                Ok(u) => u,
                Err(e) => {
                    warn!("[Teams] Error parsing meetingUpdate: {:?}", e);
                    return;
                }
            };
            self.update_state(|s| {
                s.in_meeting = update.meeting_state.is_in_meeting;
                s.is_muted = update.meeting_state.is_muted;
                s.is_video_on = update.meeting_state.is_video_on;
                s.can_toggle_mute = update.meeting_permissions.can_toggle_mute;
                s.can_toggle_video = update.meeting_permissions.can_toggle_video;
            });
        }

        if let Some(err) = parsed.get("errorMsg").and_then(|v| v.as_str()) {
            warn!("[Teams] Error response: {}", err);
        } else if parsed.get("response").is_some() {
            debug!("[Teams] Response: {}", text);
        }
    }
}

/// Connects to Teams, processing messages and commands, and reconnects on failure.
async fn run_connection(
    controller: Arc<TeamsController>,
    mut commands: mpsc::UnboundedReceiver<String>,
) {
    let base_url =
        std::env::var(TEAMS_API_URL_ENV).unwrap_or_else(|_| DEFAULT_TEAMS_API_URL.to_string());
    let mut backoff = RECONNECT_MIN;

    loop {
        // Drop commands queued while disconnected so stale toggles are not replayed.
        while commands.try_recv().is_ok() {}

        let url = format!(
            "{}?token={}&protocol-version=2.0.0&manufacturer=toumorokoshi&device=StreamDeck&app=yft-sandbox&app-version={}",
            base_url,
            load_token().unwrap_or_default(),
            env!("CARGO_PKG_VERSION"),
        );

        match connect_async(&url).await {
            Ok((ws_stream, _)) => {
                info!("[Teams] Connected to {}", base_url);
                backoff = RECONNECT_MIN;
                controller.update_state(|s| s.connected = true);

                let (mut write, mut read) = ws_stream.split();
                loop {
                    tokio::select! {
                        msg = read.next() => match msg {
                            Some(Ok(Message::Text(text))) => controller.handle_message(&text),
                            Some(Ok(Message::Close(_))) | None => break,
                            Some(Err(e)) => {
                                warn!("[Teams] WebSocket read error: {:?}", e);
                                break;
                            }
                            Some(Ok(_)) => {}
                        },
                        Some(cmd) = commands.recv() => {
                            debug!("[Teams] Sending {}", cmd);
                            if let Err(e) = write.send(Message::Text(cmd)).await {
                                warn!("[Teams] WebSocket send error: {:?}", e);
                                break;
                            }
                        }
                    }
                }

                info!("[Teams] Disconnected");
                controller.update_state(|s| *s = TeamsState::default());
            }
            Err(e) => debug!("[Teams] Connection to {} failed: {:?}", base_url, e),
        }

        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(RECONNECT_MAX);
    }
}

fn token_path() -> Option<PathBuf> {
    if let Ok(path) = std::env::var(TEAMS_TOKEN_PATH_ENV) {
        return Some(PathBuf::from(path));
    }
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join("Library/Application Support/yft-sandbox/teams_token"))
}

fn load_token() -> Option<String> {
    let token = std::fs::read_to_string(token_path()?).ok()?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_string())
}

fn save_token(token: &str) {
    let Some(path) = token_path() else {
        warn!("[Teams] Cannot determine token path; pairing will not persist");
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(e) = std::fs::write(&path, token) {
        warn!("[Teams] Failed to save token to {:?}: {:?}", path, e);
    }
}
