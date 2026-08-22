//! The receiver's connect path, against a stub sender.
//!
//! This is the code that has failed in front of a user twice — "retrying,
//! retrying" and "invalid authority" — and until now nothing could exercise it
//! without a Mac at the other end, so every regression in it reached a release.
//!
//! The stub speaks the real protocol: `wire::frame_message` builds the frames,
//! so the bytes on this socket are the bytes a Mac sends. What is being checked
//! is the receiver's half — that it opens with a well-formed `hello`, carries a
//! stored token so a paired machine goes straight through, forwards video
//! untouched, surfaces control messages instead of swallowing them, and ends
//! cleanly rather than hanging.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use display_share_receiver_lib::{
    handoff, hello_message, run_session, wire, ConnectionState, Panel, SessionEvent,
};
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

/// What the stub sender should do once a receiver connects.
enum Script {
    /// Send these, then close.
    Send(Vec<Message>),
    /// Send a frame, wait for one control message from the receiver, echo it
    /// back as text, then close.
    EchoOneControl,
}

/// What the stub saw. The receiver's `hello` is the interesting half.
#[derive(Default)]
struct Seen {
    hello: Option<String>,
    control: Vec<String>,
}

async fn stub_sender(script: Script) -> (SocketAddr, tokio::task::JoinHandle<Seen>) {
    // Port 0: the OS picks a free one, so tests never collide with each other
    // or with a real sender on the developer's machine.
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");

    let handle = tokio::spawn(async move {
        let mut seen = Seen::default();
        let (tcp, _) = listener.accept().await.expect("accept");
        let mut socket = tokio_tungstenite::accept_async(tcp).await.expect("handshake");

        // A receiver must open with hello before anything else happens.
        if let Some(Ok(Message::Text(text))) = socket.next().await {
            seen.hello = Some(text);
        }

        match script {
            Script::Send(messages) => {
                for message in messages {
                    if socket.send(message).await.is_err() {
                        break;
                    }
                }
            }
            Script::EchoOneControl => {
                let frame = wire::frame_message(&[0, 0, 0, 1, 0x65, 0xAA], true, 1_000);
                let _ = socket.send(Message::Binary(frame)).await;
                if let Some(Ok(Message::Text(text))) = socket.next().await {
                    seen.control.push(text.clone());
                    let _ = socket.send(Message::Text(text)).await;
                }
            }
        }
        let _ = socket.close(None).await;
        seen
    });

    (addr, handle)
}

fn panel() -> Panel {
    Panel { width: 2560, height: 1440, scale: 1.5, refresh_rate: 120 }
}

struct Session {
    frames: Vec<Vec<u8>>,
    events: Vec<String>,
    result: Result<(), String>,
}

/// Drives one session against an already-listening stub.
async fn drive(
    addr: SocketAddr,
    identity: Option<serde_json::Value>,
    state: Arc<ConnectionState>,
) -> Session {
    let frames = Arc::new(Mutex::new(Vec::new()));
    let events = Arc::new(Mutex::new(Vec::new()));
    let collected = frames.clone();
    let noted = events.clone();

    let result = run_session(
        &format!("ws://{addr}"),
        &panel(),
        identity,
        state,
        move |bytes| {
            collected.lock().unwrap().push(bytes);
            true
        },
        move |event| {
            noted.lock().unwrap().push(match event {
                SessionEvent::Connected(_) => "connected".to_string(),
                SessionEvent::Control(text) => format!("control:{text}"),
                SessionEvent::Handoff(sample) => {
                    format!("handoff:{}:{}", sample.timestamp_us, sample.forwarded_epoch_us)
                }
                SessionEvent::Disconnected => "disconnected".to_string(),
            });
        },
    )
    .await;

    Session {
        frames: Arc::try_unwrap(frames).unwrap().into_inner().unwrap(),
        events: Arc::try_unwrap(events).unwrap().into_inner().unwrap(),
        result,
    }
}

// --------------------------------------------------------------- the hello

#[test]
fn hello_reports_the_panel_and_the_protocol_version() {
    let hello = hello_message(&panel(), None);
    assert_eq!(hello["type"], "hello");
    assert_eq!(hello["protocolVersion"], 1);
    assert!(
        hello["client"].as_str().unwrap().starts_with("display-share-receiver/"),
        "the sender logs this to tell versions apart: {hello}"
    );
    assert_eq!(hello["receiver"]["width"], 2560);
    assert_eq!(hello["receiver"]["height"], 1440);
    assert_eq!(hello["receiver"]["refreshRate"], 120);
}

/// SPEC §4.9. A paired receiver goes straight through because its token rides
/// in `hello`; drop the field and the only symptom is being asked for a PIN
/// again, which reads as pairing being broken rather than as a missing key.
#[test]
fn hello_carries_a_stored_identity() {
    let identity = serde_json::json!({
        "deviceId": "a3f1", "deviceName": "VIVOBOOK", "token": "secret",
    });
    let hello = hello_message(&panel(), Some(&identity));
    assert_eq!(hello["deviceId"], "a3f1");
    assert_eq!(hello["deviceName"], "VIVOBOOK");
    assert_eq!(hello["token"], "secret");
}

/// An unpaired receiver has an id and a name but no token yet. Sending
/// `"token": null` is not the same as sending nothing.
#[test]
fn hello_omits_a_null_token_rather_than_sending_one() {
    let identity = serde_json::json!({
        "deviceId": "a3f1", "deviceName": "VIVOBOOK", "token": null,
    });
    let hello = hello_message(&panel(), Some(&identity));
    assert!(hello.get("token").is_none(), "a null token must not be sent: {hello}");
    assert_eq!(hello["deviceId"], "a3f1");
}

// ------------------------------------------------------------- the session

#[tokio::test]
async fn a_session_opens_with_hello_and_forwards_video_untouched() {
    let frame = wire::frame_message(&[0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65, 0x88], true, 1_234);
    let (addr, stub) = stub_sender(Script::Send(vec![Message::Binary(frame.clone())])).await;

    let session = drive(addr, None, Arc::new(ConnectionState::default())).await;
    let seen = stub.await.expect("stub");

    assert!(session.result.is_ok(), "session failed: {:?}", session.result);

    let hello: serde_json::Value =
        serde_json::from_str(seen.hello.as_deref().expect("no hello sent")).expect("hello is JSON");
    assert_eq!(hello["type"], "hello");
    assert_eq!(hello["receiver"]["width"], 2560);

    // Byte-for-byte: the frontend parses the documented wire format, so
    // anything rewritten here breaks it in a way only a decoder would notice.
    assert_eq!(session.frames, vec![frame], "video must be forwarded verbatim");
    assert_eq!(session.events.first().map(String::as_str), Some("connected"));
    assert_eq!(session.events.last().map(String::as_str), Some("disconnected"));
}

/// The pairing prompt arrives as a control message. Swallowing it, or dropping
/// the connection when one appears, is how a fixable state ends up hidden
/// behind "Retrying…" — which this project shipped.
#[tokio::test]
async fn a_pairing_prompt_reaches_the_interface_and_does_not_end_the_session() {
    let refusal = r#"{"type":"error","code":"pairing_required","message":"Enter the PIN"}"#;
    let frame = wire::frame_message(&[0, 0, 0, 1, 0x65], false, 7);
    let (addr, stub) = stub_sender(Script::Send(vec![
        Message::Text(refusal.to_string()),
        Message::Binary(frame.clone()),
    ]))
    .await;

    let session = drive(addr, None, Arc::new(ConnectionState::default())).await;
    let _ = stub.await;

    assert!(
        session.events.iter().any(|e| e.contains("pairing_required")),
        "the prompt never reached the interface: {:?}",
        session.events
    );
    assert_eq!(
        session.frames,
        vec![frame],
        "the session must survive a control message and keep streaming"
    );
}

/// `request_keyframe` travels this way. Without it a corrupted GOP is
/// permanent: the receiver has no other means of asking for a fresh IDR.
#[tokio::test]
async fn control_messages_from_the_interface_reach_the_sender() {
    let (addr, stub) = stub_sender(Script::EchoOneControl).await;
    let state = Arc::new(ConnectionState::default());

    let pump = {
        let state = state.clone();
        tokio::spawn(async move {
            // Wait for the session to publish its outbound channel.
            for _ in 0..200 {
                if state
                    .send_control(r#"{"type":"request_keyframe"}"#.to_string())
                    .await
                    .is_ok()
                {
                    return true;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
            false
        })
    };

    let session = drive(addr, None, state).await;
    let sent = pump.await.expect("pump");
    let seen = stub.await.expect("stub");

    assert!(sent, "the outbound channel was never published");
    assert!(
        seen.control.iter().any(|c| c.contains("request_keyframe")),
        "the sender never received it: {:?}",
        seen.control
    );
    assert!(
        session.events.iter().any(|e| e.contains("request_keyframe")),
        "the echo should come back as a control event: {:?}",
        session.events
    );
}

/// A refused connection must fail fast with the address in it, not hang. The
/// UI turns this into human copy (Command 3 of the UI/UX audit); what matters
/// here is that it returns at all.
#[tokio::test]
async fn a_refused_connection_reports_rather_than_hanging() {
    // Bind and drop, so the port is free but nothing is listening.
    let addr = {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap()
    };

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        drive(addr, None, Arc::new(ConnectionState::default())),
    )
    .await
    .expect("connecting to a dead port hung");

    let error = result.result.expect_err("connecting to nothing should fail");
    assert!(error.contains(&addr.to_string()), "the address belongs in the error: {error}");
}

/// The outbound channel must be cleared when a session ends. Left in place, the
/// next `send_control` writes into a socket that is gone and reports success.
#[tokio::test]
async fn the_outbound_channel_is_cleared_when_the_session_ends() {
    let (addr, stub) = stub_sender(Script::Send(vec![])).await;
    let state = Arc::new(ConnectionState::default());

    let session = drive(addr, None, state.clone()).await;
    let _ = stub.await;

    assert!(session.result.is_ok());
    assert!(
        !state.is_connected().await,
        "a finished session must not leave a live-looking channel behind"
    );
}

// ------------------------------------------------------------ the hand-off

/// The IPC gap is measured by pairing this stamp with the frontend's arrival,
/// keyed on the sender's timestamp. If the stamp never leaves the session, or
/// carries a timestamp the frontend will not recognise, the measurement reports
/// nothing at all — and reports it silently, which is the failure worth
/// catching here rather than in a browser.
#[tokio::test]
async fn a_session_reports_when_it_handed_a_frame_to_the_webview() {
    let frame = wire::frame_message(&[0, 0, 0, 1, 0x65, 0x11], true, 4_242);
    let (addr, stub) = stub_sender(Script::Send(vec![Message::Binary(frame)])).await;

    let before = handoff::epoch_micros();
    let session = drive(addr, None, Arc::new(ConnectionState::default())).await;
    let after = handoff::epoch_micros();
    let _ = stub.await;

    let sample = session
        .events
        .iter()
        .find_map(|e| e.strip_prefix("handoff:"))
        .expect("no hand-off was reported for a frame that was forwarded");

    let (timestamp, forwarded) = sample.split_once(':').expect("malformed sample");
    assert_eq!(
        timestamp, "4242",
        "the sample must carry the SENDER's timestamp — it is the only key the          frontend can match its own arrival against"
    );

    // Stamped when the frame was read, so it belongs inside the window this
    // test ran in. A stamp from a different clock or a different unit lands
    // wildly outside it.
    let forwarded: u64 = forwarded.parse().expect("epoch is a number");
    assert!(
        (before..=after).contains(&forwarded),
        "hand-off stamped at {forwarded}, outside the {before}..={after} window this test ran in"
    );
}
