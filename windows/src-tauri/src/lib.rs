//! Display Share receiver — Rust backend.
//!
//! The backend owns the WebSocket connection and forwards frames to the
//! webview; the frontend only decodes and paints. Two reasons, both from the
//! build plan:
//!
//! 1. **No secure context needed.** WebCodecs requires a secure context, and a
//!    page talking to `ws://192.168.x.x` from a plain LAN IP does not have one.
//!    With the socket in Rust, the webview only ever sees `tauri://localhost`,
//!    which is secure — so the self-signed-certificate problem disappears.
//! 2. **Reconnect control.** Backoff, cancellation and panel re-negotiation are
//!    far easier to reason about in Rust than across a webview lifecycle.

use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

/// The receiver's physical panel, reported to the sender in `hello`
/// (protocol/SPEC.md §4.1) so it can size the virtual display to match.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Panel {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    #[serde(rename = "refreshRate")]
    pub refresh_rate: u32,
}

impl Default for Panel {
    fn default() -> Self {
        Self { width: 1920, height: 1080, scale: 1.0, refresh_rate: 60 }
    }
}

#[derive(Default)]
pub struct ConnectionState {
    /// Sender half for outbound control messages; None when disconnected.
    outbound: Mutex<Option<mpsc::UnboundedSender<String>>>,
}

/// Reads the ACTUAL panel geometry from the monitor the window is on.
///
/// Task 3.3: the Vivobook's panel must not be assumed to be 1920x1080.
/// `Monitor::size` is in physical pixels, which is exactly what the encoder
/// needs; `scale_factor` is the OS scaling the user has set.
#[tauri::command]
fn detect_panel(app: AppHandle) -> Panel {
    let window = app.get_webview_window("main");

    // Prefer the monitor the window is actually on; fall back to primary.
    let monitor = window
        .as_ref()
        .and_then(|w| w.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());

    match monitor {
        Some(m) => {
            let size = m.size();
            Panel {
                width: size.width,
                height: size.height,
                scale: m.scale_factor(),
                // Tauri does not expose refresh rate; the frontend refines this
                // if the browser can tell us more.
                refresh_rate: 60,
            }
        }
        None => Panel::default(),
    }
}

/// Connects to the sender and streams frames into `on_frame`.
///
/// Video is forwarded as RAW bytes — the complete wire message, header and all,
/// exactly as it came off the socket. That keeps the frontend parsing the
/// documented format (so it can be tested against protocol/vectors/) and avoids
/// the cost of JSON-encoding megabytes of video through the IPC bridge.
#[tauri::command]
async fn connect(
    app: AppHandle,
    state: State<'_, Arc<ConnectionState>>,
    url: String,
    panel: Panel,
    on_frame: Channel<InvokeResponseBody>,
) -> Result<(), String> {
    let (stream, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| format!("connect to {url} failed: {e}"))?;
    let (mut write, mut read) = stream.split();

    let hello = serde_json::json!({
        "type": "hello",
        "protocolVersion": 1,
        "client": concat!("display-share-receiver/", env!("CARGO_PKG_VERSION")),
        "receiver": panel,
    });
    write
        .send(Message::Text(hello.to_string()))
        .await
        .map_err(|e| format!("hello failed: {e}"))?;

    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    *state.outbound.lock().await = Some(tx);

    // Outbound pump: control messages from the frontend.
    let writer = tokio::spawn(async move {
        while let Some(text) = rx.recv().await {
            if write.send(Message::Text(text)).await.is_err() {
                break;
            }
        }
        let _ = write.close().await;
    });

    let _ = app.emit("ds://connected", &url);

    while let Some(message) = read.next().await {
        match message {
            Ok(Message::Binary(bytes)) => {
                // Raw passthrough; the frontend parses SPEC §3.
                if on_frame.send(InvokeResponseBody::Raw(bytes)).is_err() {
                    break;
                }
            }
            Ok(Message::Text(text)) => {
                let _ = app.emit("ds://control", text);
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }

    *state.outbound.lock().await = None;
    writer.abort();
    let _ = app.emit("ds://disconnected", ());
    Ok(())
}

/// Sends a JSON control message to the sender (request_keyframe, resize, stats).
#[tauri::command]
async fn send_control(state: State<'_, Arc<ConnectionState>>, message: String) -> Result<(), String> {
    let guard = state.outbound.lock().await;
    match guard.as_ref() {
        Some(tx) => tx.send(message).map_err(|e| e.to_string()),
        None => Err("not connected".into()),
    }
}

/// Optional preset host (DS_HOST), so the receiver can be launched
/// non-interactively for testing and kiosk use.
#[tauri::command]
fn default_host() -> Option<String> {
    std::env::var("DS_HOST").ok().filter(|s| !s.is_empty())
}

#[tauri::command]
fn set_fullscreen(app: AppHandle, enabled: bool) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        window.set_fullscreen(enabled).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(ConnectionState::default()))
        .invoke_handler(tauri::generate_handler![
            detect_panel,
            default_host,
            connect,
            send_control,
            set_fullscreen
        ])
        .run(tauri::generate_context!())
        .expect("error while running Display Share receiver");
}
