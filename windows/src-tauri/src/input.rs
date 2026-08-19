//! Injecting the Mac's mouse and keyboard into Windows (Task 8.3).
//!
//! The wire format from SPEC §4.10 is reused unchanged, including both pointer
//! modes: absolute `move` normalised inside the video, and relative `moverel`
//! for roaming past the edge.
//!
//! **Windows needs no permission for this**, unlike macOS with Accessibility.
//! It does silently refuse to inject into windows running elevated (Task
//! Manager, an admin PowerShell, the UAC prompt itself) unless the receiver is
//! elevated too. That is a deliberate OS security boundary, not a bug here: it
//! looks like the keyboard has died over one window and works everywhere else.

#![cfg(target_os = "windows")]

use crate::{coords, keymap};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, MAPVK_VK_TO_VSC, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
    MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS, MapVirtualKeyW,
    VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN,
};

/// One notch of the scroll wheel.
const WHEEL_DELTA: f64 = 120.0;

/// An input event exactly as SPEC §4.10 puts it on the wire.
#[derive(serde::Deserialize, Debug, Clone)]
pub struct InputEvent {
    pub k: String,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub b: Option<i32>,
    #[serde(default)]
    pub dx: Option<f64>,
    #[serde(default)]
    pub dy: Option<f64>,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub down: Option<bool>,
}

pub struct Injector {
    /// The display being shared, in desktop pixels.
    output: coords::Rect,
}

impl Injector {
    /// Builds an injector for the shared output.
    ///
    /// The output's position on the desktop is captured once here; a normalised
    /// coordinate means nothing without it (see `coords`).
    pub fn new(output_index: u32) -> Self {
        let output = crate::capture::list_outputs()
            .ok()
            .and_then(|outputs| {
                outputs
                    .into_iter()
                    .find(|o| o.index == output_index)
                    .map(|o| coords::Rect::new(o.x, o.y, o.width as i32, o.height as i32))
            })
            // Falling back to the primary screen's size is better than refusing
            // all input; the cursor may be offset on a multi-monitor desktop,
            // which is visible and recoverable.
            .unwrap_or_else(|| coords::Rect::new(0, 0, 1920, 1080));
        Self { output }
    }

    /// The whole desktop, read fresh each time.
    ///
    /// Not cached: monitors get plugged in, unplugged and rearranged while a
    /// session runs, and a stale rectangle sends the cursor to the wrong screen.
    fn virtual_desktop() -> coords::Rect {
        unsafe {
            coords::Rect::new(
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1),
                GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1),
            )
        }
    }

    pub fn handle(&self, event: &InputEvent) {
        match event.k.as_str() {
            "move" => {
                if let (Some(x), Some(y)) = (event.x, event.y) {
                    let (ax, ay) = coords::to_absolute(x, y, self.output, Self::virtual_desktop());
                    self.mouse(
                        ax,
                        ay,
                        MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                        0,
                    );
                }
            }
            "moverel" => {
                // Relative motion is in pixels and must NOT carry the absolute
                // flag, or the deltas would be read as desktop coordinates and
                // throw the cursor into the top-left corner.
                let dx = event.dx.unwrap_or(0.0).round() as i32;
                let dy = event.dy.unwrap_or(0.0).round() as i32;
                if dx != 0 || dy != 0 {
                    self.mouse(dx, dy, MOUSEEVENTF_MOVE, 0);
                }
            }
            "down" | "up" => {
                let pressed = event.k == "down";
                // DOM button numbering: 0 left, 1 middle, 2 right.
                let flags = match (event.b.unwrap_or(0), pressed) {
                    (0, true) => MOUSEEVENTF_LEFTDOWN,
                    (0, false) => MOUSEEVENTF_LEFTUP,
                    (1, true) => MOUSEEVENTF_MIDDLEDOWN,
                    (1, false) => MOUSEEVENTF_MIDDLEUP,
                    (2, true) => MOUSEEVENTF_RIGHTDOWN,
                    (2, false) => MOUSEEVENTF_RIGHTUP,
                    _ => return,
                };
                self.mouse(0, 0, flags, 0);
            }
            "scroll" => {
                // The sender reports line-ish units; Windows counts notches of
                // WHEEL_DELTA.
                let dy = event.dy.unwrap_or(0.0);
                if dy != 0.0 {
                    self.mouse(0, 0, MOUSEEVENTF_WHEEL, (dy * WHEEL_DELTA) as i32 as u32);
                }
                let dx = event.dx.unwrap_or(0.0);
                if dx != 0.0 {
                    // Horizontal wheel runs the opposite way to the vertical one.
                    self.mouse(0, 0, MOUSEEVENTF_HWHEEL, (-dx * WHEEL_DELTA) as i32 as u32);
                }
            }
            "key" => {
                let Some(code) = event.code.as_deref() else { return };
                // An unmapped code is dropped rather than guessed at.
                let Some(mapped) = keymap::lookup(code) else { return };
                self.key(mapped, event.down.unwrap_or(true));
            }
            _ => {}
        }
    }

    fn mouse(&self, dx: i32, dy: i32, flags: MOUSE_EVENT_FLAGS, data: u32) {
        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx,
                    dy,
                    mouseData: data,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        unsafe {
            SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
        }
    }

    fn key(&self, mapped: keymap::Key, pressed: bool) {
        let mut flags = KEYBD_EVENT_FLAGS(0);
        if mapped.extended {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        if !pressed {
            flags |= KEYEVENTF_KEYUP;
        }
        // The scan code is sent alongside the virtual key so applications that
        // read raw input (games, terminals) see a real keypress rather than an
        // event with a zero scan code.
        let scan = unsafe { MapVirtualKeyW(mapped.virtual_key as u32, MAPVK_VK_TO_VSC) } as u16;
        let input = INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(mapped.virtual_key),
                    wScan: scan,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        unsafe {
            SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
        }
    }
}
