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

// Public so the encoder self-test (examples/encode_selftest.rs) can drive the
// same code CI checks with ffprobe.
pub mod annexb;
pub mod coords;
pub mod keymap;
pub mod link;
pub mod capture;
pub mod convert;
pub mod encode;
pub mod input;
pub mod sender;
pub mod wire;

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
    /// The network link the current session is running over (Task 10.2).
    link: std::sync::Mutex<Option<link::LinkInfo>>,
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
    sharing: State<'_, SharingState>,
    url: String,
    panel: Panel,
    identity: Option<serde_json::Value>,
    on_frame: Channel<InvokeResponseBody>,
) -> Result<(), String> {
    // The other half of the mutual exclusion in start_sharing. Guarding only
    // one direction would still let the loop form, just by starting the two in
    // the opposite order.
    if sharing.inner.lock().unwrap().is_some() {
        return Err("This PC is currently sharing its screen. Stop sharing first.".into());
    }
    let (stream, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| format!("connect to {url} failed: {e}"))?;

    // Which adapter the socket actually bound to. Asked here rather than
    // guessed from the sender's address: a machine with Wi-Fi and a cable both
    // up has two answers, and only the socket knows which one is carrying this.
    if let tokio_tungstenite::MaybeTlsStream::Plain(tcp) = stream.get_ref() {
        let described = tcp.local_addr().ok().and_then(|addr| link::describe(addr.ip()));
        *state.link.lock().unwrap() = described;
    }

    let (mut write, mut read) = stream.split();

    let mut hello = serde_json::json!({
        "type": "hello",
        "protocolVersion": 1,
        "client": concat!("display-share-receiver/", env!("CARGO_PKG_VERSION")),
        "receiver": panel,
    });
    // Identity + token, so a paired receiver goes straight through (SPEC §4.9).
    if let Some(identity) = identity {
        if let Some(map) = hello.as_object_mut() {
            for key in ["deviceId", "deviceName", "token"] {
                if let Some(value) = identity.get(key) {
                    if !value.is_null() {
                        map.insert(key.to_string(), value.clone());
                    }
                }
            }
        }
    }
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
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .manage(Arc::new(ConnectionState::default()))
        .manage(SharingState::default())
        .invoke_handler(tauri::generate_handler![
            detect_panel,
            default_host,
            discover_senders,
            device_identity,
            connect,
            send_control,
            set_fullscreen,
            capture_probe,
            link_info,
            start_sharing,
            stop_sharing,
            sharing_status,
            list_display_outputs
        ])
        .run(tauri::generate_context!())
        .expect("error while running Display Share receiver");
}

// --- Discovery (SPEC §4a) ---------------------------------------------------

/// A sender found on the local network.
#[derive(Debug, Clone, Serialize)]
pub struct DiscoveredSender {
    pub name: String,
    pub host: String,
    pub port: u16,
    pub addresses: Vec<String>,
    pub requires_pairing: bool,
    pub protocol_version: Option<u32>,
}

/// Browses `_displayshare._tcp` for up to `timeout_ms`.
///
/// A one-shot browse rather than a continuous subscription: the receiver shows a
/// list at launch, and a stale entry that no longer answers is less confusing
/// than a list that reshuffles under the user's cursor.
#[tauri::command]
async fn discover_senders(timeout_ms: Option<u64>) -> Result<Vec<DiscoveredSender>, String> {
    use mdns_sd::{ServiceDaemon, ServiceEvent};
    use std::collections::HashMap;
    use std::time::Duration;

    let daemon = ServiceDaemon::new().map_err(|e| format!("mDNS unavailable: {e}"))?;
    let receiver = daemon
        .browse("_displayshare._tcp.local.")
        .map_err(|e| format!("browse failed: {e}"))?;

    let deadline = tokio::time::Instant::now()
        + Duration::from_millis(timeout_ms.unwrap_or(2500));
    let mut found: HashMap<String, DiscoveredSender> = HashMap::new();

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, async { receiver.recv_async().await }).await {
            Ok(Ok(ServiceEvent::ServiceResolved(info))) => {
                let txt = |key: &str| {
                    info.get_property_val_str(key).map(|v| v.to_string())
                };
                let addresses: Vec<String> =
                    info.get_addresses().iter().map(|a| a.to_string()).collect();
                let name = txt("name")
                    .unwrap_or_else(|| info.get_fullname().split('.').next().unwrap_or("Mac").to_string());
                found.insert(
                    info.get_fullname().to_string(),
                    DiscoveredSender {
                        name,
                        host: info.get_hostname().trim_end_matches('.').to_string(),
                        port: info.get_port(),
                        addresses,
                        requires_pairing: txt("pair").as_deref() != Some("none"),
                        protocol_version: txt("v").and_then(|v| v.parse().ok()),
                    },
                );
            }
            Ok(Ok(_)) => {}
            Ok(Err(_)) | Err(_) => break,
        }
    }
    let _ = daemon.shutdown();

    let mut senders: Vec<_> = found.into_values().collect();
    senders.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(senders)
}

/// Stable per-install identity, generated once. Pairing tokens are bound to it.
#[tauri::command]
fn device_identity(app: AppHandle) -> Result<serde_json::Value, String> {
    use std::io::Write;
    let dir = app
        .path()
        .app_config_dir()
        .map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join("device-id");

    let id = match std::fs::read_to_string(&path) {
        Ok(existing) if !existing.trim().is_empty() => existing.trim().to_string(),
        _ => {
            use rand::Rng;
            let bytes: [u8; 16] = rand::thread_rng().gen();
            let id = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
            let mut file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
            file.write_all(id.as_bytes()).map_err(|e| e.to_string())?;
            id
        }
    };

    let name = hostname_or_default();
    Ok(serde_json::json!({ "deviceId": id, "deviceName": name }))
}

fn hostname_or_default() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Receiver".to_string())
}

// ---------------------------------------------------------------- Task 8.1
/// Result of a desktop-capture smoke test.
#[derive(serde::Serialize)]
pub struct CaptureProbe {
    pub width: u32,
    pub height: u32,
    pub frames: u64,
    pub idle: u64,
    pub reinits: u64,
    pub fps: f64,
    /// Bytes in the last frame — proves pixels actually arrived rather than an
    /// empty buffer of the right shape.
    pub last_frame_bytes: usize,
    /// Mean luminance of the last frame. A duplication that "succeeds" but hands
    /// back a black texture is a real failure mode, and frame counts alone
    /// cannot tell it apart from a working capture.
    pub last_frame_mean: f64,
}

/// Grabs a few frames from the real desktop and reports what came back.
///
/// Exists so capture can be proven on hardware before any encoder is attached;
/// if this fails, nothing downstream is worth debugging.
#[tauri::command]
async fn capture_probe(frames: Option<u32>, output: Option<u32>) -> Result<CaptureProbe, String> {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (frames, output);
        Err("desktop capture is only implemented on Windows".into())
    }

    #[cfg(target_os = "windows")]
    {
        let want = frames.unwrap_or(30).clamp(1, 600);
        // Probing a specific display matters for the dummy-adapter setup: the
        // whole point is to confirm the SECOND output is being captured, not
        // the laptop's own screen.
        let output = output.unwrap_or(0);
        tauri::async_runtime::spawn_blocking(move || {
            let mut cap = capture::DesktopCapture::new(output).map_err(|e| e.to_string())?;
            let (width, height) = cap.size();
            let mut last_bytes = 0usize;
            let mut last_mean = 0.0f64;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);

            while cap.stats.frames < want as u64 {
                // An idle desktop produces no frames at all, so a frame target
                // alone would hang forever on a still screen.
                if std::time::Instant::now() > deadline {
                    break;
                }
                match cap.next_frame(100) {
                    Ok(Some(frame)) => {
                        last_bytes = frame.bgra.len();
                        // Sample rather than sum 8 MB per frame; every 997th byte
                        // is coprime with the 4-byte pixel stride, so this does
                        // not land on one channel.
                        let sum: u64 = frame.bgra.iter().step_by(997).map(|b| *b as u64).sum();
                        let n = frame.bgra.len().div_ceil(997).max(1);
                        last_mean = sum as f64 / n as f64;
                    }
                    Ok(None) => {}
                    Err(e) => return Err(e.to_string()),
                }
            }

            Ok(CaptureProbe {
                width,
                height,
                frames: cap.stats.frames,
                idle: cap.stats.idle,
                reinits: cap.stats.reinits,
                fps: cap.fps(),
                last_frame_bytes: last_bytes,
                last_frame_mean: last_mean,
            })
        })
        .await
        .map_err(|e| e.to_string())?
    }
}

// ------------------------------------------------- Task 8.2: sharing this PC
/// The reverse direction's port. Separate from the Mac sender's 8787/8788 so a
/// single machine can hold both roles without a clash (SPEC §2).
/// A display attached to this machine.
///
/// Enumerated so the user can share a screen OTHER than the primary one. That is
/// what makes a dummy display adapter useful: Windows extends onto it, and
/// sharing that output gives a genuinely separate desktop rather than a mirror
/// of the laptop's own screen. Extending without extra hardware would need an
/// Indirect Display Driver, which requires a signed driver this project has
/// decided not to buy.
#[derive(Clone, serde::Serialize)]
pub struct OutputInfo {
    pub index: u32,
    /// Windows' device name, e.g. `\\\\.\\DISPLAY2`.
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub x: i32,
    pub y: i32,
    /// The display whose top-left corner is the desktop origin.
    pub is_primary: bool,
    pub attached: bool,
}

pub const REVERSE_PORT: u16 = 7879;
/// A distinct Bonjour type, NOT `_displayshare._tcp`. Sharing one type would
/// make this app list other Windows machines as senders, and the Mac list
/// itself. Kept under the 15-character DNS-SD service name limit.
pub const REVERSE_SERVICE: &str = "_dsreverse._tcp.local.";

#[derive(Default)]
pub struct SharingState {
    inner: std::sync::Mutex<Option<SharingInfo>>,
    /// Held so the advertisement lives as long as the process. Dropping the
    /// daemon silently withdraws the service and the Mac stops seeing it.
    mdns: std::sync::Mutex<Option<mdns_sd::ServiceDaemon>>,
}

#[derive(Clone, serde::Serialize)]
pub struct SharingInfo {
    pub port: u16,
    pub host: String,
    pub service: String,
    pub output: u32,
}

/// Starts capturing and serving this PC's screen.
///
/// Idempotent: calling it again returns the running session rather than binding
/// a second listener, so a double click on the button cannot half-start a
/// second capture thread.
#[tauri::command]
async fn start_sharing(
    state: State<'_, SharingState>,
    connection: State<'_, Arc<ConnectionState>>,
    port: Option<u16>,
    output: Option<u32>,
) -> Result<SharingInfo, String> {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (state, connection, port, output);
        Err("sharing this screen is only implemented on Windows".into())
    }

    #[cfg(target_os = "windows")]
    {
        // One direction at a time. Two machines each capturing and encoding the
        // other is a feedback loop: it saturates the link, and the adaptive
        // bitrate controller assumes a single stream, so it reacts to congestion
        // it is itself creating.
        if connection.outbound.lock().await.is_some() {
            return Err(
                "This PC is currently receiving a screen. Disconnect first, then share."
                    .into(),
            );
        }
        if let Some(existing) = state.inner.lock().unwrap().clone() {
            return Ok(existing);
        }
        let port = port.unwrap_or(REVERSE_PORT);
        let output = output.unwrap_or(0);
        sender::serve(port, sender::Source::Desktop { output }, 30, 8_000_000)
            .await
            .map_err(|e| format!("could not start sharing: {e}"))?;

        let host = hostname();
        let info = SharingInfo {
            port,
            host: host.clone(),
            service: REVERSE_SERVICE.to_string(),
            output,
        };

        // Advertising is best-effort: a firewall or a missing mDNS responder
        // must not stop sharing, because the Mac can still be pointed at the
        // address by hand.
        match advertise(&host, port) {
            Ok(daemon) => *state.mdns.lock().unwrap() = Some(daemon),
            Err(e) => eprintln!("could not advertise on Bonjour: {e}"),
        }

        *state.inner.lock().unwrap() = Some(info.clone());
        Ok(info)
    }
}

#[tauri::command]
fn sharing_status(state: State<'_, SharingState>) -> Option<SharingInfo> {
    state.inner.lock().unwrap().clone()
}

fn hostname() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "Windows PC".into())
}

#[cfg(target_os = "windows")]
fn advertise(host: &str, port: u16) -> Result<mdns_sd::ServiceDaemon, String> {
    let daemon = mdns_sd::ServiceDaemon::new().map_err(|e| e.to_string())?;
    // Instance names may not contain dots: mdns-sd would read them as label
    // separators and register a name nobody browses for.
    let instance = host.replace('.', "-");
    let service = mdns_sd::ServiceInfo::new(
        REVERSE_SERVICE,
        &instance,
        &format!("{instance}.local."),
        (),
        port,
        &[("v", "1"), ("platform", "windows")][..],
    )
    .map_err(|e| e.to_string())?
    // Let the daemon track this machine's addresses itself: hard-coding one
    // breaks the moment the user moves between Wi-Fi and Ethernet.
    .enable_addr_auto();
    daemon.register(service).map_err(|e| e.to_string())?;
    Ok(daemon)
}

/// Withdraws the advertisement and forgets the session.
///
/// The capture thread and listener stay up for this process's lifetime — tearing
/// a DXGI duplication down and back up mid-session is a reliable way to hit
/// ACCESS_LOST — but the machine stops advertising, so it is no longer offered
/// to viewers and the direction can be switched.
#[tauri::command]
fn stop_sharing(state: State<'_, SharingState>) -> Result<(), String> {
    if let Some(daemon) = state.mdns.lock().unwrap().take() {
        let _ = daemon.shutdown();
    }
    *state.inner.lock().unwrap() = None;
    Ok(())
}

/// Displays available to share.
#[tauri::command]
fn list_display_outputs() -> Result<Vec<OutputInfo>, String> {
    #[cfg(not(target_os = "windows"))]
    {
        Err("listing displays is only implemented on Windows".into())
    }

    #[cfg(target_os = "windows")]
    {
        capture::list_outputs().map_err(|e| e.to_string())
    }
}

/// The link the current session is using, or None when not connected.
///
/// Exposed so the receiver can name it in the HUD and, when a wireless link is
/// measurably costing time, say that a cable would remove it — advice that is
/// only worth giving when both halves are true.
#[tauri::command]
fn link_info(state: State<'_, Arc<ConnectionState>>) -> Option<link::LinkInfo> {
    state.link.lock().unwrap().clone()
}
