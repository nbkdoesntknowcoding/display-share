//! Timing the hand-off from the socket to the WebView.
//!
//! This is the one stage of the pipeline nothing could see. A frame's life is
//! measured at both ends — the Mac times its encode and its send, the frontend
//! times its decode — but between the socket read here and the callback in
//! `main.ts` sits the Tauri IPC bridge and WebView2, and that gap has only ever
//! been reasoned about. It was reasoned about wrongly once already: forwarding
//! frames as JSON cost about 6.7ms each, which is why they are `Raw` now, and
//! nobody ever measured whether that fixed it.
//!
//! Two constraints shape the design.
//!
//! The wire format cannot change. Both implementations are verified against the
//! golden vectors in protocol/vectors/, so adding a field for instrumentation
//! would mean a spec revision — far too much machinery for a diagnostic. So the
//! sample carries no new bytes across the socket at all: it uses the sender's
//! timestamp, already in every frame, as the key the frontend matches on.
//!
//! And the measurement must not become the cost. Every frame is timestamped
//! anyway, but only one in `SAMPLE_EVERY` is reported, because the point is to
//! characterise a gap that is roughly constant, not to trace each frame.

/// One frame's hand-off, as seen from this side.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Handoff {
    /// The sender's timestamp, straight from the frame header. The key the
    /// frontend matches on — it has the same value against its own arrival.
    pub timestamp_us: u64,
    /// When this process read the frame off the socket, on the wall clock.
    ///
    /// Wall clock rather than monotonic because the other half of the
    /// subtraction happens in JavaScript, and `performance.timeOrigin` is the
    /// only shared reference the two runtimes have. The cost is that a clock
    /// adjustment mid-sample produces nonsense; the frontend bounds the result
    /// rather than trusting it.
    pub forwarded_epoch_us: u64,
}

/// One in every N frames is reported. At 60fps that is four a second, which is
/// plenty to characterise the gap and few enough to be free.
pub const SAMPLE_EVERY: u64 = 15;

/// Reads the sender's timestamp out of a frame (SPEC §3: bytes 8..16, big
/// endian, after the 4-byte length, type, flags and reserved fields).
///
/// Returns `None` for anything that is not a video message, so a future message
/// type cannot silently be timed as though it were a frame.
pub fn sender_timestamp(frame: &[u8]) -> Option<u64> {
    if frame.len() < crate::wire::HEADER_LEN || frame[4] != crate::wire::TYPE_VIDEO {
        return None;
    }
    Some(u64::from_be_bytes(frame[8..16].try_into().ok()?))
}

/// Decides which frames are reported.
#[derive(Debug, Default)]
pub struct HandoffSampler {
    seen: u64,
}

impl HandoffSampler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Offers a frame. `Some` means this one is being reported.
    ///
    /// The very first frame is sampled: a session that ends before fifteen
    /// frames have gone by should still say something, and the first frame
    /// after a connect is the interesting one anyway — it carries the keyframe.
    pub fn note(&mut self, frame: &[u8], now_epoch_us: u64) -> Option<Handoff> {
        let timestamp_us = sender_timestamp(frame)?;
        let index = self.seen;
        self.seen += 1;
        if index % SAMPLE_EVERY != 0 {
            return None;
        }
        Some(Handoff { timestamp_us, forwarded_epoch_us: now_epoch_us })
    }
}

/// The event body sent to the frontend.
///
/// These two key names are the contract with `HandoffSample` in
/// `windows/src/timing.ts`. Renaming one side alone does not fail to compile
/// anywhere — the frontend simply reads `undefined`, pairs nothing, and the
/// HUD row quietly never appears. The test below pins them; the mirror is
/// named in a comment there, because a two-field diagnostic does not justify
/// the golden-vector machinery the wire protocol has.
pub fn payload(sample: &Handoff) -> serde_json::Value {
    serde_json::json!({
        "timestampMicros": sample.timestamp_us,
        "forwardedEpochMicros": sample.forwarded_epoch_us,
    })
}

/// Now, in microseconds since the Unix epoch.
pub fn epoch_micros() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire;

    #[test]
    fn the_timestamp_comes_from_the_frame_the_sender_actually_built() {
        // Against `frame_message` rather than a hand-built buffer, so a change
        // to the header layout breaks this instead of quietly shifting what
        // gets read.
        let frame = wire::frame_message(&[0, 0, 0, 1, 0x65], true, 1_234_567);
        assert_eq!(sender_timestamp(&frame), Some(1_234_567));
    }

    #[test]
    fn a_short_or_foreign_message_is_not_timed() {
        assert_eq!(sender_timestamp(&[]), None);
        assert_eq!(sender_timestamp(&[0; 15]), None, "shorter than a header");

        let mut foreign = wire::frame_message(&[1, 2, 3], false, 42);
        foreign[4] = 9; // some future message type
        assert_eq!(sender_timestamp(&foreign), None, "only video frames are timed");
    }

    #[test]
    fn the_first_frame_is_always_reported() {
        let mut sampler = HandoffSampler::new();
        let frame = wire::frame_message(&[1], true, 7);
        let sample = sampler.note(&frame, 1_000).expect("the first frame must be reported");
        assert_eq!(sample.timestamp_us, 7);
        assert_eq!(sample.forwarded_epoch_us, 1_000);
    }

    #[test]
    fn reporting_is_one_frame_in_fifteen() {
        let mut sampler = HandoffSampler::new();
        let reported = (0..90)
            .filter(|i| {
                let frame = wire::frame_message(&[1], false, *i as u64);
                sampler.note(&frame, 0).is_some()
            })
            .count();
        assert_eq!(reported, 6, "90 frames at one in {SAMPLE_EVERY} is six reports");
    }

    /// Pins the names `windows/src/timing.ts` reads.
    #[test]
    fn the_event_body_uses_the_names_the_frontend_reads() {
        let body = payload(&Handoff { timestamp_us: 5, forwarded_epoch_us: 9 });
        let object = body.as_object().expect("an object");

        let mut keys: Vec<_> = object.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            ["forwardedEpochMicros", "timestampMicros"],
            "these are read by HandoffSample in windows/src/timing.ts — renaming one \
             side does not break a build, it just makes the measurement disappear"
        );
        assert_eq!(body["timestampMicros"], 5);
        assert_eq!(body["forwardedEpochMicros"], 9);
    }

    /// A message that is not a frame must not consume a slot in the count,
    /// or the sampling interval would drift with the control traffic.
    #[test]
    fn messages_that_are_not_frames_do_not_advance_the_count() {
        let mut sampler = HandoffSampler::new();
        let frame = wire::frame_message(&[1], false, 1);

        assert!(sampler.note(&frame, 0).is_some(), "first");
        for _ in 0..50 {
            assert_eq!(sampler.note(&[0; 4], 0), None, "not a frame");
        }
        // Still on the original cadence: the next report is the fifteenth
        // FRAME, not the fifteenth message.
        let reported = (1..SAMPLE_EVERY)
            .filter(|_| sampler.note(&frame, 0).is_some())
            .count();
        assert_eq!(reported, 0, "nothing until the interval is up");
        assert!(sampler.note(&frame, 0).is_some(), "the fifteenth frame");
    }
}
