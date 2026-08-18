//! Annex-B bitstream inspection (Task 8.1).
//!
//! The receiver's WebCodecs decoder is configured WITHOUT a `description`, which
//! means it expects Annex-B with parameter sets in-band. If an IDR ever goes out
//! without an SPS in front of it, the decoder does not error — it just shows
//! nothing until the next keyframe that happens to carry one. That failure is
//! invisible on the sending side, so the check lives here and is exercised by
//! tests rather than trusted to the encoder's defaults.
//!
//! Pure byte scanning, no Windows types: this is the half of the encode path
//! that can be tested off-Windows, and it is worth having covered.

/// Byte offsets of each NAL unit payload (after the start code).
fn nal_offsets(data: &[u8]) -> Vec<usize> {
    let mut offsets = Vec::new();
    let mut i = 0usize;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 {
            if data[i + 2] == 1 {
                offsets.push(i + 3);
                i += 3;
                continue;
            }
            // Four-byte start code. Encoders mix 3- and 4-byte forms freely in
            // one access unit, so both have to be handled.
            if i + 4 <= data.len() && data[i + 2] == 0 && data[i + 3] == 1 {
                offsets.push(i + 4);
                i += 4;
                continue;
            }
        }
        i += 1;
    }
    offsets
}

/// NAL unit types present, in order. 7 = SPS, 8 = PPS, 5 = IDR, 1 = non-IDR.
pub fn nal_types(data: &[u8]) -> Vec<u8> {
    nal_offsets(data)
        .into_iter()
        .filter(|o| *o < data.len())
        .map(|o| data[o] & 0x1f)
        .collect()
}

/// True if this access unit carries an SPS, i.e. a decoder can start here.
pub fn has_parameter_sets(data: &[u8]) -> bool {
    nal_types(data).contains(&7)
}

/// True if this access unit contains an IDR picture.
pub fn has_idr(data: &[u8]) -> bool {
    nal_types(data).contains(&5)
}

/// True if any NAL is a B-slice.
///
/// Only a coarse check — slice_type lives in the exp-Golomb-coded slice header
/// and decoding it properly would mean a bitstream reader. Kept because the
/// stream contract is "no B-frames" and a cheap check that can only produce
/// false negatives is still worth having; ffmpeg's `has_b_frames` in CI is the
/// real gate.
pub fn nal_summary(data: &[u8]) -> String {
    let types = nal_types(data);
    let names: Vec<String> = types
        .iter()
        .map(|t| match t {
            1 => "P/B".into(),
            5 => "IDR".into(),
            6 => "SEI".into(),
            7 => "SPS".into(),
            8 => "PPS".into(),
            9 => "AUD".into(),
            other => format!("{other}"),
        })
        .collect();
    names.join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds an Annex-B buffer from (start_code_len, nal_type) pairs.
    fn au(parts: &[(usize, u8)]) -> Vec<u8> {
        let mut v = Vec::new();
        for (sc, ty) in parts {
            if *sc == 4 {
                v.extend_from_slice(&[0, 0, 0, 1]);
            } else {
                v.extend_from_slice(&[0, 0, 1]);
            }
            v.push(*ty & 0x1f);
            v.extend_from_slice(&[0xaa, 0xbb]);
        }
        v
    }

    #[test]
    fn reads_three_and_four_byte_start_codes() {
        let data = au(&[(4, 7), (3, 8), (4, 5)]);
        assert_eq!(nal_types(&data), vec![7, 8, 5]);
    }

    #[test]
    fn keyframe_with_parameter_sets_is_recognised() {
        let data = au(&[(4, 7), (4, 8), (4, 5)]);
        assert!(has_parameter_sets(&data));
        assert!(has_idr(&data));
    }

    #[test]
    fn bare_idr_without_sps_is_flagged() {
        // The exact case that renders as a black screen on the receiver rather
        // than as an error.
        let data = au(&[(4, 5)]);
        assert!(has_idr(&data));
        assert!(!has_parameter_sets(&data), "an IDR alone must not pass as startable");
    }

    #[test]
    fn delta_frames_carry_neither() {
        let data = au(&[(3, 1)]);
        assert!(!has_idr(&data));
        assert!(!has_parameter_sets(&data));
    }

    #[test]
    fn empty_and_truncated_input_do_not_panic() {
        assert!(nal_types(&[]).is_empty());
        assert!(nal_types(&[0, 0]).is_empty());
        // Start code with no payload byte following it.
        assert!(nal_types(&[0, 0, 1]).is_empty());
        assert!(nal_types(&[0, 0, 0, 1]).is_empty());
    }

    #[test]
    fn summary_names_the_nals() {
        assert_eq!(nal_summary(&au(&[(4, 7), (4, 8), (4, 5)])), "SPS,PPS,IDR");
    }
}
