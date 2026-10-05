mod audio;
mod media;
mod plugin;
mod teams;

use clap::Parser;
use log::{error, info};
use std::sync::Arc;
use std::time::Duration;

/// yft sandbox - OpenDeck & Stream Deck Plugin CLI and daemon.
#[derive(Parser, Debug)]
#[command(
    name = "macos-media",
    about = "yft sandbox - OpenDeck & Stream Deck Plugin"
)]
struct Cli {
    /// Port number of Stream Deck WebSocket server
    #[arg(long, short = 'p')]
    port: Option<u16>,

    /// Unique plugin UUID from Stream Deck
    #[arg(long = "pluginUUID")]
    plugin_uuid: Option<String>,

    /// Register event name
    #[arg(long = "registerEvent")]
    register_event: Option<String>,

    /// Plugin info JSON string
    #[arg(long)]
    info: Option<String>,

    /// Toggle media play/pause on macOS
    #[arg(long)]
    toggle: bool,

    /// Start media playback on macOS
    #[arg(long)]
    play: bool,

    /// Pause media playback on macOS
    #[arg(long)]
    pause: bool,

    /// Skip to next track on macOS
    #[arg(long)]
    next: bool,

    /// Return to previous track on macOS
    #[arg(long)]
    previous: bool,

    /// Print current playback status (JSON)
    #[arg(long)]
    status: bool,

    /// Toggle microphone mute (0% vs 100%/restored)
    #[arg(long = "toggle-mic")]
    toggle_mic: bool,

    /// Mute microphone (set input volume to 0%)
    #[arg(long)]
    mute: bool,

    /// Unmute microphone (restore input volume / 100%)
    #[arg(long)]
    unmute: bool,

    /// Print current microphone volume and mute status (JSON)
    #[arg(long = "mic-status")]
    mic_status: bool,

    /// Toggle the Microsoft Teams camera in the current meeting
    #[arg(long = "toggle-teams-camera")]
    toggle_teams_camera: bool,

    /// Toggle the Microsoft Teams microphone mute in the current meeting
    #[arg(long = "toggle-teams-mute")]
    toggle_teams_mute: bool,

    /// Print current Microsoft Teams meeting state (JSON)
    #[arg(long = "teams-status")]
    teams_status: bool,
}

/// Connects to Teams and waits briefly for the initial meeting state.
async fn connect_teams() -> Arc<teams::TeamsController> {
    let teams = teams::TeamsController::new();
    let mut rx = teams.subscribe();
    let _ = tokio::time::timeout(Duration::from_secs(2), rx.wait_for(|s| s.connected)).await;
    if teams.get_status().connected {
        // Teams pushes a meetingUpdate shortly after connecting.
        let _ = tokio::time::timeout(Duration::from_millis(500), rx.changed()).await;
    }
    teams
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize env_logger with default info level if not set
    if std::env::var("RUST_LOG").is_err() {
        std::env::set_var("RUST_LOG", "info");
    }
    env_logger::init();

    // Normalize arguments: translate single-dash Stream Deck parameters (-port, -pluginUUID, etc.)
    // into standard double-dash long flags for clap.
    let raw_args: Vec<String> = std::env::args()
        .enumerate()
        .map(|(i, arg)| {
            if i == 0 {
                arg
            } else if arg == "-port" {
                "--port".to_string()
            } else if arg == "-pluginUUID" {
                "--pluginUUID".to_string()
            } else if arg == "-registerEvent" {
                "--registerEvent".to_string()
            } else if arg == "-info" {
                "--info".to_string()
            } else {
                arg
            }
        })
        .collect();

    let cli = match Cli::try_parse_from(&raw_args) {
        Ok(c) => c,
        Err(e) => {
            e.exit();
        }
    };

    let audio = audio::AudioController::new();
    let media = media::MediaController::new();

    // Check standalone commands first
    if cli.toggle {
        let ok = media.toggle_play_pause();
        println!(
            "Play/Pause toggled: {}",
            if ok { "success" } else { "failed" }
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.play {
        let ok = media.play();
        println!(
            "Play command sent: {}",
            if ok { "success" } else { "failed" }
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.pause {
        let ok = media.pause();
        println!(
            "Pause command sent: {}",
            if ok { "success" } else { "failed" }
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.next {
        let ok = media.next_track();
        println!(
            "Next track command sent: {}",
            if ok { "success" } else { "failed" }
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.previous {
        let ok = media.previous_track();
        println!(
            "Previous track command sent: {}",
            if ok { "success" } else { "failed" }
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.status {
        let status = media.get_status();
        println!("{}", serde_json::to_string(&status)?);
        std::process::exit(0);
    }
    if cli.toggle_mic {
        let ok = audio.toggle_mute();
        println!(
            "Mic mute toggled: {} (current muted: {})",
            if ok { "success" } else { "failed" },
            audio.is_muted()
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.mute {
        let ok = audio.mute();
        println!("Mic muted: {}", if ok { "success" } else { "failed" });
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.unmute {
        let ok = audio.unmute();
        println!("Mic unmuted: {}", if ok { "success" } else { "failed" });
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.mic_status {
        let status = audio.get_status();
        println!("{}", serde_json::to_string(&status)?);
        std::process::exit(0);
    }

    if cli.toggle_teams_camera || cli.toggle_teams_mute {
        let teams = connect_teams().await;
        let ok = if cli.toggle_teams_camera {
            teams.toggle_video()
        } else {
            teams.toggle_mute()
        };
        // Wait for Teams to apply the toggle (or for the pairing prompt to be accepted).
        if ok {
            let mut rx = teams.subscribe();
            let _ = tokio::time::timeout(Duration::from_secs(5), rx.changed()).await;
        }
        println!(
            "Teams toggle sent: {} (state: {})",
            if ok { "success" } else { "failed" },
            serde_json::to_string(&teams.get_status())?
        );
        std::process::exit(if ok { 0 } else { 1 });
    }
    if cli.teams_status {
        let teams = connect_teams().await;
        println!("{}", serde_json::to_string(&teams.get_status())?);
        std::process::exit(0);
    }

    // Stream Deck daemon mode
    let port = cli.port;
    let plugin_uuid = cli.plugin_uuid;
    let register_event = cli.register_event;

    if let (Some(port), Some(plugin_uuid), Some(register_event)) =
        (port, plugin_uuid, register_event)
    {
        info!(
            "[yft sandbox] Starting plugin for port: {}, UUID: {}, event: {}",
            port, plugin_uuid, register_event
        );
        if let Err(e) = plugin::run_plugin(
            port,
            plugin_uuid,
            register_event,
            cli.info,
            audio,
            media,
            teams::TeamsController::new(),
        )
        .await
        {
            error!("[yft sandbox] Plugin exited with error: {:?}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    // If incomplete parameters provided
    eprintln!("[yft sandbox] Incomplete parameters provided. Use --help for usage.");
    std::process::exit(1);
}
