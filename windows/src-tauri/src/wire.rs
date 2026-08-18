//! Binary video framing (protocol/SPEC.md §3).
//!
//! Shared with the Mac sender's format rather than reinvented: the framing and
//! control channel are direction-agnostic, and a second protocol would double
//! the surface that has to stay in sync between two codebases.
//!
//! Platform-independent so it can be tested here rather than only in CI.

/// Message type 1 = video access unit.
pub const TYPE_VIDEO: u8 = 1;
/// flags bit0 = keyframe.
pub const FLAG_KEYFRAME: u8 = 0x01;
pub const HEADER_LEN: usize = 16;

/// Wraps one access unit in the 16-byte header.
///
/// `length` counts the bytes AFTER the length field itself — 12 header bytes
/// plus the payload — which is the detail a hand-rolled reimplementation gets
/// wrong.
pub fn frame_message(payload: &[u8], keyframe: bool, timestamp_us: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&((12 + payload.len()) as u32).to_be_bytes());
    out.push(TYPE_VIDEO);
    out.push(if keyframe { FLAG_KEYFRAME } else { 0 });
    out.extend_from_slice(&0u16.to_be_bytes());
    out.extend_from_slice(&timestamp_us.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_is_sixteen_bytes_and_length_excludes_itself() {
        let m = frame_message(&[0xaa; 100], true, 0);
        assert_eq!(m.len(), HEADER_LEN + 100);
        let len = u32::from_be_bytes(m[0..4].try_into().unwrap());
        // SPEC §3: a receiver MUST reject a message whose length != size - 4.
        assert_eq!(len as usize, m.len() - 4);
        assert_eq!(len as usize, 12 + 100);
    }

    #[test]
    fn fields_are_big_endian_and_in_the_right_slots() {
        let m = frame_message(&[1, 2, 3], false, 0x0102_0304_0506_0708);
        assert_eq!(m[4], TYPE_VIDEO);
        assert_eq!(m[5], 0, "non-keyframe must not set bit0");
        assert_eq!(&m[6..8], &[0, 0], "reserved must be zero");
        assert_eq!(&m[8..16], &[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(&m[16..], &[1, 2, 3]);
    }

    #[test]
    fn keyframe_sets_only_bit_zero() {
        let m = frame_message(&[0], true, 7);
        assert_eq!(m[5], FLAG_KEYFRAME);
        assert_eq!(m[5] & !FLAG_KEYFRAME, 0, "reserved flag bits must stay clear");
    }
}
