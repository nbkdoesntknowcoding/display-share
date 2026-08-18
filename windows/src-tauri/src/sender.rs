//! Serves captured, encoded frames over the existing wire protocol (Task 8.1).
//!
//! This is the Windows machine acting as a SENDER — the reverse of everything
//! before Phase 8. The protocol is reused unchanged (protocol/SPEC.md): framing,
//! the control channel and pairing are all direction-agnostic, so the Mac viewer
//! in Task 8.2 can be a plain client of the format the receiver already speaks.
//!
//! Capture and encode live on a dedicated OS thread rather than in the async
//! runtime. Both hold COM objects that are not `Send`, and `AcquireNextFrame`
//! blocks — parking a tokio worker on it would stall unrelated tasks.

#![cfg(target_os = "windows")]

use crate::{convert, encode, wire};
use futures_util::SinkExt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::net::TcpListener;
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct Frame {
    pub data: Arc<Vec<u8>>,
    pub keyframe: bool,
    pub timestamp_us: u64,
}

#[derive(Clone)]
pub struct SenderHandle {
    frames: broadcast::Sender<Frame>,
    /// Set when a client connects so the next encoded frame is an IDR.
    force_idr: Arc<AtomicBool>,
    pub clients: Arc<AtomicU64>,
    pub port: u16,
}

/// Where the frames come from.
#[derive(Clone, Copy, PartialEq)]
pub enum Source {
    /// The real desktop, via DXGI Desktop Duplication.
    Desktop,
    /// A generated test pattern. Exists so the WebSocket path can be proven in
    /// CI: desktop duplication needs an interactive session with a GPU, which a
    /// hosted runner does not reliably have, and a test that silently skips is
    /// worse than no test.
    Synthetic { width: u32, height: u32 },
}

/// Starts capture and the WebSocket listener. Returns once the socket is bound.
pub async fn serve(port: u16, source: Source, fps: u32, bitrate: u32) -> Result<SenderHandle, String> {
    // Capacity is small on purpose: a client that cannot keep up should lose old
    // frames and resync on the next keyframe, not accumulate latency for ever.
    let (frames, _) = broadcast::channel::<Frame>(8);
    let handle = SenderHandle {
        frames: frames.clone(),
        force_idr: Arc::new(AtomicBool::new(true)),
        clients: Arc::new(AtomicU64::new(0)),
        port,
    };

    let listener = TcpListener::bind(("0.0.0.0", port))
        .await
        .map_err(|e| format!("could not bind port {port}: {e}"))?;

    {
        let force_idr = handle.force_idr.clone();
        std::thread::Builder::new()
            .name("ds-capture".into())
            .spawn(move || {
                if let Err(e) = capture_loop(frames, force_idr, source, fps, bitrate) {
                    eprintln!("capture loop stopped: {e}");
                }
            })
            .map_err(|e| e.to_string())?;
    }

    let accept = handle.clone();
    tokio::spawn(async move {
        loop {
            let Ok((stream, peer)) = listener.accept().await else { continue };
            let mut rx = accept.frames.subscribe();
            // A client joining mid-stream cannot decode a delta frame, so ask
            // for a keyframe now rather than making it wait for the next
            // scheduled one.
            accept.force_idr.store(true, Ordering::SeqCst);
            accept.clients.fetch_add(1, Ordering::SeqCst);
            let clients = accept.clients.clone();

            tokio::spawn(async move {
                let ws = match tokio_tungstenite::accept_async(stream).await {
                    Ok(ws) => ws,
                    Err(e) => {
                        eprintln!("handshake with {peer} failed: {e}");
                        clients.fetch_sub(1, Ordering::SeqCst);
                        return;
                    }
                };
                let (mut sink, _read) = futures_util::StreamExt::split(ws);

                let mut started = false;
                loop {
                    match rx.recv().await {
                        Ok(frame) => {
                            // Never open with a delta frame: the decoder would
                            // show nothing until the next keyframe rather than
                            // reporting an error.
                            if !started {
                                if !frame.keyframe {
                                    continue;
                                }
                                started = true;
                            }
                            let msg = wire::frame_message(
                                &frame.data,
                                frame.keyframe,
                                frame.timestamp_us,
                            );
                            if sink
                                .send(tokio_tungstenite::tungstenite::Message::Binary(msg))
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        // Fell behind: resync from the next keyframe instead of
                        // sending frames the decoder cannot use.
                        Err(broadcast::error::RecvError::Lagged(_)) => started = false,
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
                clients.fetch_sub(1, Ordering::SeqCst);
            });
        }
    });

    Ok(handle)
}

fn capture_loop(
    frames: broadcast::Sender<Frame>,
    force_idr: Arc<AtomicBool>,
    source: Source,
    fps: u32,
    bitrate: u32,
) -> Result<(), String> {
    let origin = Instant::now();
    let interval = std::time::Duration::from_micros(1_000_000 / fps.max(1) as u64);

    let mut desktop = match source {
        Source::Desktop => {
            Some(encode_err(crate::capture::DesktopCapture::new())?)
        }
        Source::Synthetic { .. } => None,
    };
    let (width, height) = match (&desktop, source) {
        (Some(d), _) => d.size(),
        (None, Source::Synthetic { width, height }) => (width, height),
        _ => return Err("no capture source".into()),
    };

    let mut encoder = encode_err(encode::H264Encoder::new(width, height, fps, bitrate))?;
    let mut tick = 0u32;
    let mut last = Instant::now();

    loop {
        let bgra = match desktop.as_mut() {
            Some(d) => match encode_err(d.next_frame(100))? {
                Some(f) => f.bgra,
                // Idle desktop: nothing changed, so there is nothing to encode.
                None => continue,
            },
            None => {
                // Synthetic source has no natural pacing of its own.
                let elapsed = last.elapsed();
                if elapsed < interval {
                    std::thread::sleep(interval - elapsed);
                }
                last = Instant::now();
                convert::test_pattern(width, height, tick)
            }
        };
        tick = tick.wrapping_add(1);

        let nv12 = convert::bgra_to_nv12(&bgra, width, height);
        let idr = force_idr.swap(false, Ordering::SeqCst);
        for encoded in encode_err(encoder.encode(&nv12, idr))? {
            let frame = Frame {
                data: Arc::new(encoded.data),
                keyframe: encoded.keyframe,
                timestamp_us: origin.elapsed().as_micros() as u64,
            };
            // Err only means nobody is listening yet; capture continues so a
            // client that connects later does not wait for a restart.
            let _ = frames.send(frame);
        }
    }
}

fn encode_err<T>(r: windows::core::Result<T>) -> Result<T, String> {
    r.map_err(|e| e.to_string())
}
