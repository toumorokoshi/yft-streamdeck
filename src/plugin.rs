use crate::audio::AudioController;
use crate::media::MediaController;
use futures_util::{SinkExt, StreamExt};
use log::{debug, error, info, warn};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

pub const ACTION_MIC_MUTE: &str = "com.toumorokoshi.yftsandbox.micmute";
pub const ACTION_TEAMS_MUTE: &str = "com.toumorokoshi.yftsandbox.teamsmute";

pub const ACTION_PLAY_PAUSE: &str = "com.toumorokoshi.yftsandbox.playpause";
pub const ACTION_PLAY: &str = "com.toumorokoshi.yftsandbox.play";
pub const ACTION_PAUSE: &str = "com.toumorokoshi.yftsandbox.pause";
pub const ACTION_NEXT: &str = "com.toumorokoshi.yftsandbox.next";
pub const ACTION_PREVIOUS: &str = "com.toumorokoshi.yftsandbox.previous";

pub const ACTION_PLAY_PAUSE_LEGACY: &str = "com.toumorokoshi.macosmedia.playpause";
pub const ACTION_PLAY_LEGACY: &str = "com.toumorokoshi.macosmedia.play";
pub const ACTION_PAUSE_LEGACY: &str = "com.toumorokoshi.macosmedia.pause";
pub const ACTION_NEXT_LEGACY: &str = "com.toumorokoshi.macosmedia.next";
pub const ACTION_PREVIOUS_LEGACY: &str = "com.toumorokoshi.macosmedia.previous";

/// Outgoing registration payload sent upon WebSocket connection.
#[derive(Debug, Serialize)]
pub struct RegisterEvent<'a> {
    /// Event name provided by Stream Deck host.
    pub event: &'a str,
    /// Plugin UUID assigned by Stream Deck host.
    pub uuid: &'a str,
}

/// Outgoing setState message payload.
#[derive(Debug, Serialize)]
pub struct SetStatePayload {
    /// Desired button state index (0 or 1).
    pub state: usize,
}

/// Outgoing setState message.
#[derive(Debug, Serialize)]
pub struct SetStateMessage<'a> {
    /// Message event type (`setState`).
    pub event: &'static str,
    /// Stream Deck button context token.
    pub context: &'a str,
    /// State value payload.
    pub payload: SetStatePayload,
}

/// Outgoing setTitle message payload.
#[derive(Debug, Serialize)]
pub struct SetTitlePayload<'a> {
    /// Text to display on the button.
    pub title: &'a str,
    /// Target display (0 = hardware and software).
    pub target: u8,
}

/// Outgoing setTitle message.
#[derive(Debug, Serialize)]
pub struct SetTitleMessage<'a> {
    /// Message event type (`setTitle`).
    pub event: &'static str,
    /// Stream Deck button context token.
    pub context: &'a str,
    /// Title text payload.
    pub payload: SetTitlePayload<'a>,
}

/// Tracks active Stream Deck contexts currently visible on the screen.
struct PluginState {
    /// Active contexts showing media play/pause.
    active_play_pause: HashSet<String>,
    /// Active contexts showing mic mute.
    active_mic_mute: HashSet<String>,
    /// Last sent mic mute state.
    last_mic_state: Option<usize>,
    /// Last sent mic title string.
    last_mic_title: Option<String>,
    /// Last sent media play/pause state.
    last_media_state: Option<usize>,
}

/// Runs the Stream Deck / OpenDeck plugin WebSocket event loop.
pub async fn run_plugin(
    port: u16,
    plugin_uuid: String,
    register_event: String,
    _info_json: Option<String>,
    audio: Arc<AudioController>,
    media: Arc<MediaController>,
) -> Result<(), Box<dyn std::error::Error>> {
    let url = format!("ws://127.0.0.1:{}", port);
    info!("[StreamDeckPlugin] Connecting to {}...", url);

    let (ws_stream, _) = connect_async(&url).await?;
    info!("[StreamDeckPlugin] WebSocket connection opened successfully");

    let (mut write, mut read) = ws_stream.split();

    // 1. Send registration event
    let reg_msg = RegisterEvent {
        event: &register_event,
        uuid: &plugin_uuid,
    };
    let reg_json = serde_json::to_string(&reg_msg)?;
    write.send(Message::Text(reg_json)).await?;
    info!(
        "[StreamDeckPlugin] Registered with event: {}, uuid: {}",
        register_event, plugin_uuid
    );

    let state = Arc::new(Mutex::new(PluginState {
        active_play_pause: HashSet::new(),
        active_mic_mute: HashSet::new(),
        last_mic_state: None,
        last_mic_title: None,
        last_media_state: None,
    }));

    // Channel for outgoing WebSocket text messages
    let (tx_out, mut rx_out) = tokio::sync::mpsc::unbounded_channel::<String>();

    // Spawn WebSocket writer task
    let writer_handle = tokio::spawn(async move {
        while let Some(msg_text) = rx_out.recv().await {
            if let Err(e) = write.send(Message::Text(msg_text)).await {
                error!(
                    "[StreamDeckPlugin] Error sending WebSocket message: {:?}",
                    e
                );
                break;
            }
        }
    });

    // Periodic state poller task to sync changes made outside Stream Deck (e.g. AirPods, settings)
    let poller_state = state.clone();
    let poller_audio = audio.clone();
    let poller_media = media.clone();
    let poller_tx = tx_out.clone();
    let poller_handle = tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(500));
        loop {
            interval.tick().await;

            // Sync mic mute keys
            let mic_status = poller_audio.get_status();
            let current_mic_state = if mic_status.is_muted { 0 } else { 1 };
            let current_mic_title = if mic_status.is_muted {
                "0%".to_string()
            } else {
                format!("{}%", mic_status.percentage)
            };

            // Sync media playback keys
            let current_media_state = if poller_media.is_playing() { 1 } else { 0 };

            let mut st = poller_state.lock().await;

            if st.last_mic_state != Some(current_mic_state)
                || st.last_mic_title.as_ref() != Some(&current_mic_title)
            {
                st.last_mic_state = Some(current_mic_state);
                st.last_mic_title = Some(current_mic_title.clone());

                for ctx in &st.active_mic_mute {
                    let set_state = SetStateMessage {
                        event: "setState",
                        context: ctx,
                        payload: SetStatePayload {
                            state: current_mic_state,
                        },
                    };
                    let set_title = SetTitleMessage {
                        event: "setTitle",
                        context: ctx,
                        payload: SetTitlePayload {
                            title: &current_mic_title,
                            target: 0,
                        },
                    };
                    if let Ok(json) = serde_json::to_string(&set_state) {
                        let _ = poller_tx.send(json);
                    }
                    if let Ok(json) = serde_json::to_string(&set_title) {
                        let _ = poller_tx.send(json);
                    }
                }
            }

            if st.last_media_state != Some(current_media_state) {
                st.last_media_state = Some(current_media_state);
                for ctx in &st.active_play_pause {
                    let set_state = SetStateMessage {
                        event: "setState",
                        context: ctx,
                        payload: SetStatePayload {
                            state: current_media_state,
                        },
                    };
                    if let Ok(json) = serde_json::to_string(&set_state) {
                        let _ = poller_tx.send(json);
                    }
                }
            }
        }
    });

    // Inbound message reader loop
    while let Some(msg_res) = read.next().await {
        let msg = match msg_res {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(_)) => {
                info!("[StreamDeckPlugin] WebSocket connection closed by host.");
                break;
            }
            Err(e) => {
                error!("[StreamDeckPlugin] WebSocket read error: {:?}", e);
                break;
            }
            _ => continue,
        };

        let parsed: Value = match serde_json::from_str(&msg) {
            Ok(val) => val,
            Err(e) => {
                warn!("[StreamDeckPlugin] Error parsing JSON: {:?}", e);
                continue;
            }
        };

        let event = parsed.get("event").and_then(|v| v.as_str()).unwrap_or("");
        let action = parsed.get("action").and_then(|v| v.as_str()).unwrap_or("");
        let context = parsed.get("context").and_then(|v| v.as_str()).unwrap_or("");

        match event {
            "willAppear" => {
                debug!(
                    "[StreamDeckPlugin] Action willAppear: {}, context: {}",
                    action, context
                );
                let mut st = state.lock().await;

                if action == ACTION_PLAY_PAUSE || action == ACTION_PLAY_PAUSE_LEGACY {
                    st.active_play_pause.insert(context.to_string());
                    let is_playing = media.is_playing();
                    let state_val = if is_playing { 1 } else { 0 };
                    st.last_media_state = Some(state_val);

                    let msg = SetStateMessage {
                        event: "setState",
                        context,
                        payload: SetStatePayload { state: state_val },
                    };
                    if let Ok(json) = serde_json::to_string(&msg) {
                        let _ = tx_out.send(json);
                    }
                } else if action == ACTION_MIC_MUTE || action == ACTION_TEAMS_MUTE {
                    st.active_mic_mute.insert(context.to_string());
                    let status = audio.get_status();
                    let state_val = if status.is_muted { 0 } else { 1 };
                    let title_val = if status.is_muted {
                        "0%".to_string()
                    } else {
                        format!("{}%", status.percentage)
                    };

                    st.last_mic_state = Some(state_val);
                    st.last_mic_title = Some(title_val.clone());

                    let set_state = SetStateMessage {
                        event: "setState",
                        context,
                        payload: SetStatePayload { state: state_val },
                    };
                    let set_title = SetTitleMessage {
                        event: "setTitle",
                        context,
                        payload: SetTitlePayload {
                            title: &title_val,
                            target: 0,
                        },
                    };
                    if let Ok(json) = serde_json::to_string(&set_state) {
                        let _ = tx_out.send(json);
                    }
                    if let Ok(json) = serde_json::to_string(&set_title) {
                        let _ = tx_out.send(json);
                    }
                }
            }
            "willDisappear" => {
                debug!(
                    "[StreamDeckPlugin] Action willDisappear: {}, context: {}",
                    action, context
                );
                let mut st = state.lock().await;
                st.active_play_pause.remove(context);
                st.active_mic_mute.remove(context);
            }
            "keyDown" => {
                debug!("[StreamDeckPlugin] Key down for action: {}", action);
                if action == ACTION_MIC_MUTE || action == ACTION_TEAMS_MUTE {
                    audio.toggle_mute();

                    // Immediately broadcast updated status to all active mic mute keys
                    let status = audio.get_status();
                    let state_val = if status.is_muted { 0 } else { 1 };
                    let title_val = if status.is_muted {
                        "0%".to_string()
                    } else {
                        format!("{}%", status.percentage)
                    };

                    let mut st = state.lock().await;
                    st.last_mic_state = Some(state_val);
                    st.last_mic_title = Some(title_val.clone());

                    for ctx in &st.active_mic_mute {
                        let set_state = SetStateMessage {
                            event: "setState",
                            context: ctx,
                            payload: SetStatePayload { state: state_val },
                        };
                        let set_title = SetTitleMessage {
                            event: "setTitle",
                            context: ctx,
                            payload: SetTitlePayload {
                                title: &title_val,
                                target: 0,
                            },
                        };
                        if let Ok(json) = serde_json::to_string(&set_state) {
                            let _ = tx_out.send(json);
                        }
                        if let Ok(json) = serde_json::to_string(&set_title) {
                            let _ = tx_out.send(json);
                        }
                    }
                } else if action == ACTION_PLAY_PAUSE || action == ACTION_PLAY_PAUSE_LEGACY {
                    media.toggle_play_pause();
                    let media_clone = media.clone();
                    let tx_clone = tx_out.clone();
                    let state_clone = state.clone();

                    // Trigger verification check after brief pause
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(150)).await;
                        let is_playing = media_clone.is_playing();
                        let state_val = if is_playing { 1 } else { 0 };

                        let mut st = state_clone.lock().await;
                        st.last_media_state = Some(state_val);
                        for ctx in &st.active_play_pause {
                            let msg = SetStateMessage {
                                event: "setState",
                                context: ctx,
                                payload: SetStatePayload { state: state_val },
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                let _ = tx_clone.send(json);
                            }
                        }
                    });
                } else if action == ACTION_PLAY || action == ACTION_PLAY_LEGACY {
                    media.play();
                } else if action == ACTION_PAUSE || action == ACTION_PAUSE_LEGACY {
                    media.pause();
                } else if action == ACTION_NEXT || action == ACTION_NEXT_LEGACY {
                    media.next_track();
                } else if action == ACTION_PREVIOUS || action == ACTION_PREVIOUS_LEGACY {
                    media.previous_track();
                }
            }
            _ => {}
        }
    }

    poller_handle.abort();
    writer_handle.abort();
    Ok(())
}
