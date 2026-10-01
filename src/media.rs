use block2::RcBlock;
use log::{debug, warn};
use objc2::runtime::Bool;
use std::ffi::c_void;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub const K_MR_PLAY: i32 = 0;
pub const K_MR_PAUSE: i32 = 1;
pub const K_MR_TOGGLE_PLAY_PAUSE: i32 = 2;
pub const K_MR_NEXT_TRACK: i32 = 3;
pub const K_MR_PREVIOUS_TRACK: i32 = 4;

type SendCommandFn = unsafe extern "C" fn(command: i32, options: *mut c_void) -> bool;
type GetIsPlayingFn = unsafe extern "C" fn(queue: *mut c_void, completion: *const c_void);
type RegisterNotificationsFn = unsafe extern "C" fn(queue: *mut c_void);

unsafe extern "C" {
    fn dispatch_get_global_queue(identifier: isize, flags: usize) -> *mut c_void;
}

/// Represents playback status reported to CLI or Stream Deck.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PlaybackStatus {
    /// True if media is currently actively playing.
    #[serde(rename = "isPlaying")]
    pub is_playing: bool,
}

/// Controller for macOS system media playback.
pub struct MediaController {
    /// Handle to loaded MediaRemote library.
    _lib: Option<libloading::Library>,
    /// Pointer to `MRMediaRemoteSendCommand`.
    send_command: Option<SendCommandFn>,
    /// Pointer to `MRMediaRemoteGetNowPlayingApplicationIsPlaying`.
    get_is_playing: Option<GetIsPlayingFn>,
    /// Last verified playback state.
    last_known_is_playing: AtomicBool,
}

impl MediaController {
    /// Creates and initializes a new `MediaController` loading MediaRemote dynamically.
    pub fn new() -> Arc<Self> {
        let mut send_command = None;
        let mut get_is_playing = None;
        let mut library = None;

        unsafe {
            match libloading::Library::new(
                "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            ) {
                Ok(lib) => {
                    let cmd_sym: Result<libloading::Symbol<SendCommandFn>, _> =
                        lib.get(b"MRMediaRemoteSendCommand\0");
                    if let Ok(sym) = cmd_sym {
                        send_command = Some(*sym);
                    }

                    let is_playing_sym: Result<libloading::Symbol<GetIsPlayingFn>, _> =
                        lib.get(b"MRMediaRemoteGetNowPlayingApplicationIsPlaying\0");
                    if let Ok(sym) = is_playing_sym {
                        get_is_playing = Some(*sym);
                    }

                    let register_sym: Result<libloading::Symbol<RegisterNotificationsFn>, _> =
                        lib.get(b"MRMediaRemoteRegisterForNowPlayingNotifications\0");
                    if let Ok(sym) = register_sym {
                        let q = dispatch_get_global_queue(0, 0);
                        sym(q);
                        debug!("[MediaController] Registered for system media notifications");
                    }

                    library = Some(lib);
                }
                Err(e) => {
                    warn!(
                        "[MediaController] Could not open MediaRemote.framework: {:?}",
                        e
                    );
                }
            }
        }

        Arc::new(Self {
            _lib: library,
            send_command,
            get_is_playing,
            last_known_is_playing: AtomicBool::new(false),
        })
    }

    /// Queries whether an application is currently playing audio/video.
    pub fn is_playing(&self) -> bool {
        if let Some(get_fn) = self.get_is_playing {
            let (tx, rx) = std::sync::mpsc::channel();
            let block = RcBlock::new(move |playing: Bool| {
                let _ = tx.send(playing.as_bool());
            });

            unsafe {
                let q = dispatch_get_global_queue(0, 0);
                let block_ptr = RcBlock::as_ptr(&block) as *const c_void;
                get_fn(q, block_ptr);
            }

            match rx.recv_timeout(Duration::from_millis(500)) {
                Ok(playing) => {
                    self.last_known_is_playing.store(playing, Ordering::SeqCst);
                    return playing;
                }
                Err(_) => {
                    debug!("[MediaController] Timeout querying isPlaying from MediaRemote");
                }
            }
        }
        self.last_known_is_playing.load(Ordering::SeqCst)
    }

    /// Executes AppleScript fallback to control Spotify or Apple Music.
    fn execute_applescript_fallback(&self, command: &str) {
        let script = format!(
            "tell application \"System Events\" to set pNames to name of processes\n\
             if pNames contains \"Spotify\" then\n  \
                 tell application \"Spotify\" to {cmd}\n\
             else if pNames contains \"Music\" then\n  \
                 tell application \"Music\" to {cmd}\n\
             end if",
            cmd = command
        );
        let _ = Command::new("osascript").args(["-e", &script]).output();
    }

    /// Sends a MediaRemote command or executes AppleScript fallback.
    fn send_command_or_fallback(&self, cmd: i32, applescript_cmd: &str) -> bool {
        let mut success = false;
        if let Some(send_fn) = self.send_command {
            unsafe {
                success = send_fn(cmd, std::ptr::null_mut());
            }
        }

        if !success {
            self.execute_applescript_fallback(applescript_cmd);
            success = true;
        }

        success
    }

    /// Toggles play / pause on system media playback.
    pub fn toggle_play_pause(&self) -> bool {
        self.send_command_or_fallback(K_MR_TOGGLE_PLAY_PAUSE, "playpause")
    }

    /// Starts or resumes media playback.
    pub fn play(&self) -> bool {
        self.send_command_or_fallback(K_MR_PLAY, "play")
    }

    /// Pauses media playback.
    pub fn pause(&self) -> bool {
        self.send_command_or_fallback(K_MR_PAUSE, "pause")
    }

    /// Skips to the next track.
    pub fn next_track(&self) -> bool {
        self.send_command_or_fallback(K_MR_NEXT_TRACK, "next track")
    }

    /// Returns to the previous track.
    pub fn previous_track(&self) -> bool {
        self.send_command_or_fallback(K_MR_PREVIOUS_TRACK, "previous track")
    }

    /// Returns the current playback status for CLI.
    pub fn get_status(&self) -> PlaybackStatus {
        PlaybackStatus {
            is_playing: self.is_playing(),
        }
    }
}
