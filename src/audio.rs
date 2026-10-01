use log::debug;
use std::ffi::c_void;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// CoreAudio property address specification.
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct AudioObjectPropertyAddress {
    /// 4-character code indicating the property selector.
    pub selector: u32,
    /// 4-character code indicating the property scope (e.g. global, input).
    pub scope: u32,
    /// Element/channel number (0 for main).
    pub element: u32,
}

pub const K_AUDIO_OBJECT_SYSTEM_OBJECT: u32 = 1;
pub const K_AUDIO_OBJECT_UNKNOWN: u32 = 0;
pub const K_AUDIO_HARDWARE_PROPERTY_DEFAULT_INPUT_DEVICE: u32 = 0x64496e20; // 'dIn '
pub const K_AUDIO_DEVICE_PROPERTY_VOLUME_SCALAR: u32 = 0x766f6c73; // 'vols'
pub const K_AUDIO_DEVICE_PROPERTY_SCOPE_INPUT: u32 = 0x696e7074; // 'inpt'
pub const K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL: u32 = 0x676c6f62; // 'glob'
pub const K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN: u32 = 0;

pub type AudioObjectPropertyListenerProc = unsafe extern "C" fn(
    in_object_id: u32,
    in_number_addresses: u32,
    in_addresses: *const AudioObjectPropertyAddress,
    in_client_data: *mut c_void,
) -> i32;

#[link(name = "CoreAudio", kind = "framework")]
unsafe extern "C" {
    fn AudioObjectGetPropertyData(
        in_object_id: u32,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: *const c_void,
        io_data_size: *mut u32,
        out_data: *mut c_void,
    ) -> i32;

    fn AudioObjectSetPropertyData(
        in_object_id: u32,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: *const c_void,
        in_data_size: u32,
        in_data: *const c_void,
    ) -> i32;

    fn AudioObjectHasProperty(
        in_object_id: u32,
        in_address: *const AudioObjectPropertyAddress,
    ) -> u8;

    fn AudioObjectAddPropertyListener(
        in_object_id: u32,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: *mut c_void,
    ) -> i32;

    #[allow(dead_code)]
    fn AudioObjectRemovePropertyListener(
        in_object_id: u32,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: *mut c_void,
    ) -> i32;
}

/// Represents microphone volume and mute status for reporting.
#[derive(Debug, Clone, serde::Serialize)]
pub struct MicStatus {
    /// True if microphone input is muted.
    #[serde(rename = "isMuted")]
    pub is_muted: bool,
    /// Current input volume scalar between 0.0 and 1.0.
    pub volume: f32,
    /// Input volume percentage between 0 and 100.
    pub percentage: i32,
}

/// Inner state of the AudioController shared with C callbacks.
struct AudioInner {
    /// Currently selected default input device ID.
    current_device_id: u32,
}

/// Controller for macOS microphone input volume and mute status.
pub struct AudioController {
    /// Cached last non-zero volume scalar for restoring upon unmute (as u32 bits).
    last_unmuted_volume_bits: AtomicU32,
    /// Inner mutable state protected by a Mutex.
    inner: Arc<Mutex<AudioInner>>,
}

unsafe extern "C" fn on_audio_property_changed(
    _in_object_id: u32,
    _in_number_addresses: u32,
    _in_addresses: *const AudioObjectPropertyAddress,
    in_client_data: *mut c_void,
) -> i32 {
    if !in_client_data.is_null() {
        let sender = &*(in_client_data as *const mpsc::UnboundedSender<()>);
        let _ = sender.send(());
    }
    0
}

impl AudioController {
    /// Creates and initializes a new `AudioController`.
    pub fn new() -> Arc<Self> {
        let (tx, mut rx) = mpsc::unbounded_channel::<()>();

        let initial_device = Self::get_default_input_device_id();
        let inner = Arc::new(Mutex::new(AudioInner {
            current_device_id: initial_device,
        }));

        let controller = Arc::new(Self {
            last_unmuted_volume_bits: AtomicU32::new(1.0f32.to_bits()),
            inner: inner.clone(),
        });

        // Initialize last unmuted volume if current is > 0.05
        let vol = controller.input_volume();
        if vol > 0.05 {
            controller
                .last_unmuted_volume_bits
                .store(vol.to_bits(), Ordering::SeqCst);
        }

        // Register default input device change listener
        let sys_addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_PROPERTY_DEFAULT_INPUT_DEVICE,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        let sender_ptr = Box::into_raw(Box::new(tx)) as *mut c_void;
        unsafe {
            AudioObjectAddPropertyListener(
                K_AUDIO_OBJECT_SYSTEM_OBJECT,
                &sys_addr,
                on_audio_property_changed,
                sender_ptr,
            );
        }

        // Setup device volume listener if device is valid
        if initial_device != K_AUDIO_OBJECT_UNKNOWN {
            if let Some(vol_addr) = Self::get_volume_address_for_device(initial_device) {
                unsafe {
                    AudioObjectAddPropertyListener(
                        initial_device,
                        &vol_addr,
                        on_audio_property_changed,
                        sender_ptr,
                    );
                }
            }
        }

        // Spawn a background task to handle listener triggers and device changes
        let weak_controller = Arc::downgrade(&controller);
        tokio::spawn(async move {
            while let Some(()) = rx.recv().await {
                if let Some(ctl) = weak_controller.upgrade() {
                    ctl.handle_hardware_change();
                } else {
                    break;
                }
            }
        });

        controller
    }

    /// Handles a hardware notification by updating the device and refreshing volume listeners.
    fn handle_hardware_change(&self) {
        let new_device = Self::get_default_input_device_id();
        let mut inner = self.inner.lock().unwrap();
        if new_device != inner.current_device_id {
            debug!(
                "[AudioController] Default input device changed: {} -> {}",
                inner.current_device_id, new_device
            );
            inner.current_device_id = new_device;
        }
        let vol = self.input_volume();
        if vol > 0.05 {
            self.last_unmuted_volume_bits
                .store(vol.to_bits(), Ordering::SeqCst);
        }
    }

    /// Queries the default input device ID from CoreAudio.
    fn get_default_input_device_id() -> u32 {
        let addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_HARDWARE_PROPERTY_DEFAULT_INPUT_DEVICE,
            scope: K_AUDIO_OBJECT_PROPERTY_SCOPE_GLOBAL,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };
        let mut device_id: u32 = K_AUDIO_OBJECT_UNKNOWN;
        let mut size = std::mem::size_of::<u32>() as u32;
        let status = unsafe {
            AudioObjectGetPropertyData(
                K_AUDIO_OBJECT_SYSTEM_OBJECT,
                &addr,
                0,
                std::ptr::null(),
                &mut size,
                &mut device_id as *mut _ as *mut c_void,
            )
        };
        if status == 0 {
            device_id
        } else {
            K_AUDIO_OBJECT_UNKNOWN
        }
    }

    /// Finds the property address for volume scalar on the given device ID.
    fn get_volume_address_for_device(device_id: u32) -> Option<AudioObjectPropertyAddress> {
        if device_id == K_AUDIO_OBJECT_UNKNOWN {
            return None;
        }

        let mut addr = AudioObjectPropertyAddress {
            selector: K_AUDIO_DEVICE_PROPERTY_VOLUME_SCALAR,
            scope: K_AUDIO_DEVICE_PROPERTY_SCOPE_INPUT,
            element: K_AUDIO_OBJECT_PROPERTY_ELEMENT_MAIN,
        };

        if unsafe { AudioObjectHasProperty(device_id, &addr) } != 0 {
            return Some(addr);
        }

        // Fallback to channel 1
        addr.element = 1;
        if unsafe { AudioObjectHasProperty(device_id, &addr) } != 0 {
            return Some(addr);
        }

        None
    }

    /// Returns the current input volume scalar between 0.0 and 1.0.
    pub fn input_volume(&self) -> f32 {
        let device_id = {
            let inner = self.inner.lock().unwrap();
            inner.current_device_id
        };

        if let Some(addr) = Self::get_volume_address_for_device(device_id) {
            let mut vol: f32 = 0.0;
            let mut size = std::mem::size_of::<f32>() as u32;
            let status = unsafe {
                AudioObjectGetPropertyData(
                    device_id,
                    &addr,
                    0,
                    std::ptr::null(),
                    &mut size,
                    &mut vol as *mut _ as *mut c_void,
                )
            };
            if status == 0 {
                return vol.clamp(0.0, 1.0);
            }
        }

        // AppleScript fallback
        if let Ok(output) = Command::new("osascript")
            .args(["-e", "input volume of (get volume settings)"])
            .output()
        {
            if output.status.success() {
                let s = String::from_utf8_lossy(&output.stdout);
                if let Ok(int_vol) = s.trim().parse::<f32>() {
                    return (int_vol / 100.0).clamp(0.0, 1.0);
                }
            }
        }

        0.0
    }

    /// Returns true if the microphone input volume is zero/muted.
    pub fn is_muted(&self) -> bool {
        self.input_volume() <= 0.001
    }

    /// Sets the microphone input volume between 0.0 and 1.0.
    pub fn set_input_volume(&self, volume: f32) -> bool {
        let clamped = volume.clamp(0.0, 1.0);
        let device_id = {
            let inner = self.inner.lock().unwrap();
            inner.current_device_id
        };

        let mut success = false;
        if let Some(addr) = Self::get_volume_address_for_device(device_id) {
            let val = clamped;
            let status = unsafe {
                AudioObjectSetPropertyData(
                    device_id,
                    &addr,
                    0,
                    std::ptr::null(),
                    std::mem::size_of::<f32>() as u32,
                    &val as *const _ as *const c_void,
                )
            };
            if status == 0 {
                success = true;
            } else {
                debug!("[AudioController] CoreAudio set volume failed: {}", status);
            }
        }

        if !success {
            // AppleScript fallback
            let pct = (clamped * 100.0).round() as i32;
            let script = format!("set volume input volume {}", pct);
            if let Ok(res) = Command::new("osascript").args(["-e", &script]).output() {
                success = res.status.success();
            }
        }

        if success && clamped > 0.05 {
            self.last_unmuted_volume_bits
                .store(clamped.to_bits(), Ordering::SeqCst);
        }

        success
    }

    /// Mutes the microphone by setting input volume to 0%.
    pub fn mute(&self) -> bool {
        let current = self.input_volume();
        if current > 0.05 {
            self.last_unmuted_volume_bits
                .store(current.to_bits(), Ordering::SeqCst);
        }
        self.set_input_volume(0.0)
    }

    /// Unmutes the microphone by restoring previous non-zero volume or 100%.
    pub fn unmute(&self) -> bool {
        let mut target = f32::from_bits(self.last_unmuted_volume_bits.load(Ordering::SeqCst));
        if target <= 0.05 {
            target = 1.0;
        }
        self.set_input_volume(target)
    }

    /// Toggles the microphone input mute state.
    pub fn toggle_mute(&self) -> bool {
        if self.is_muted() {
            self.unmute()
        } else {
            self.mute()
        }
    }

    /// Returns the current mic status structure.
    pub fn get_status(&self) -> MicStatus {
        let vol = self.input_volume();
        let is_muted = self.is_muted();
        let pct = (vol * 100.0).round() as i32;
        MicStatus {
            is_muted,
            volume: (vol * 100.0).round() / 100.0,
            percentage: pct,
        }
    }
}
