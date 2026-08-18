//! BGRA -> NV12 colour conversion (Task 8.1).
//!
//! The H.264 encoder wants NV12; DXGI Desktop Duplication produces BGRA. This
//! is deliberately plain arithmetic with no Windows types in it, because it is
//! the only part of the encode path that can be tested away from a Windows
//! machine — and it is also where a silent mistake (swapped planes, wrong
//! coefficients, U and V transposed) shows up as a picture that decodes fine and
//! merely looks wrong, which no decoder check would catch.

/// Rounding term for the 16-bit fixed-point conversions below.
const HALF: i32 = 1 << 15;

/// NV12 = full-resolution Y plane, then one interleaved half-resolution UV plane.
pub struct Nv12 {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

impl Nv12 {
    pub fn y_size(&self) -> usize {
        (self.width * self.height) as usize
    }
}

/// Converts packed BGRA8 to NV12 using BT.709 studio range.
///
/// BT.709 rather than BT.601: the stream is tagged 709 in the encoder config,
/// and a mismatch between the coefficients used here and the ones the decoder
/// applies is exactly the "colours look slightly off" bug that is miserable to
/// track down later.
///
/// Odd widths and heights are handled by clamping the chroma sample rather than
/// reading past the row — a 1919x1079 window is not hypothetical.
pub fn bgra_to_nv12(bgra: &[u8], width: u32, height: u32) -> Nv12 {
    let w = width as usize;
    let h = height as usize;
    let y_size = w * h;
    // Chroma is half resolution, rounded UP: a 3-pixel row still needs 2 samples.
    let cw = w.div_ceil(2);
    let ch = h.div_ceil(2);
    let mut data = vec![0u8; y_size + cw * ch * 2];

    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let b = bgra[i] as i32;
            let g = bgra[i + 1] as i32;
            let r = bgra[i + 2] as i32;
            // One fixed-point step, not two. Scaling full-range luma down to
            // studio range afterwards loses a count to truncation and white
            // comes out 234 instead of 235; the 219/255 factor is folded into
            // the coefficients instead, and HALF rounds instead of floors.
            let luma = (11966 * r + 40254 * g + 4064 * b + HALF) >> 16;
            data[y * w + x] = (luma + 16).clamp(16, 235) as u8;
        }
    }

    let uv_base = y_size;
    for cy in 0..ch {
        for cx in 0..cw {
            // Average the 2x2 block so chroma downsampling does not alias into
            // the crawling-edges artefact that point sampling produces on text.
            let (mut sr, mut sg, mut sb, mut n) = (0i32, 0i32, 0i32, 0i32);
            for dy in 0..2 {
                for dx in 0..2 {
                    let px = cx * 2 + dx;
                    let py = cy * 2 + dy;
                    if px >= w || py >= h {
                        continue;
                    }
                    let i = (py * w + px) * 4;
                    sb += bgra[i] as i32;
                    sg += bgra[i + 1] as i32;
                    sr += bgra[i + 2] as i32;
                    n += 1;
                }
            }
            let (r, g, b) = (sr / n, sg / n, sb / n);
            // Studio-range chroma coefficients (the 224/255 factor folded in),
            // matching the luma plane. Full-range coefficients here would drive
            // saturated blues and reds past 240 and get flattened by the clamp,
            // quietly desaturating exactly the colours that are most visible.
            let u = ((-6593 * r - 22189 * g + 28782 * b + HALF) >> 16) + 128;
            let v = ((28782 * r - 26142 * g - 2640 * b + HALF) >> 16) + 128;
            let o = uv_base + (cy * cw + cx) * 2;
            // U first, then V. Reversing these is the classic NV12 bug: skin
            // tones go blue and everything else looks plausible.
            data[o] = u.clamp(16, 240) as u8;
            data[o + 1] = v.clamp(16, 240) as u8;
        }
    }

    Nv12 { data, width, height }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, b: u8, g: u8, r: u8) -> Vec<u8> {
        let mut v = Vec::with_capacity((width * height * 4) as usize);
        for _ in 0..width * height {
            v.extend_from_slice(&[b, g, r, 255]);
        }
        v
    }

    fn uv_at(n: &Nv12, cx: usize, cy: usize) -> (u8, u8) {
        let cw = (n.width as usize).div_ceil(2);
        let o = n.y_size() + (cy * cw + cx) * 2;
        (n.data[o], n.data[o + 1])
    }

    #[test]
    fn plane_sizes_follow_nv12_layout() {
        let n = bgra_to_nv12(&solid(4, 2, 0, 0, 0), 4, 2);
        assert_eq!(n.y_size(), 8);
        assert_eq!(n.data.len(), 8 + 2 * 1 * 2);
    }

    #[test]
    fn odd_dimensions_round_chroma_up() {
        // A 3x3 image needs 2x2 chroma samples, and the edge block is a partial
        // 2x2 — the case that panics if the loop reads past the row.
        let n = bgra_to_nv12(&solid(3, 3, 10, 20, 30), 3, 3);
        assert_eq!(n.y_size(), 9);
        assert_eq!(n.data.len(), 9 + 2 * 2 * 2);
    }

    #[test]
    fn black_and_white_hit_studio_range_limits() {
        let black = bgra_to_nv12(&solid(2, 2, 0, 0, 0), 2, 2);
        assert_eq!(black.data[0], 16, "black must be 16, not 0, in studio range");
        let white = bgra_to_nv12(&solid(2, 2, 255, 255, 255), 2, 2);
        assert_eq!(white.data[0], 235, "white must be 235, not 255");
    }

    #[test]
    fn grey_is_chroma_neutral() {
        let n = bgra_to_nv12(&solid(2, 2, 128, 128, 128), 2, 2);
        let (u, v) = uv_at(&n, 0, 0);
        assert!((u as i32 - 128).abs() <= 1, "grey must not tint: U={u}");
        assert!((v as i32 - 128).abs() <= 1, "grey must not tint: V={v}");
    }

    #[test]
    fn u_is_blue_and_v_is_red_not_the_other_way_round() {
        // The plane-order bug this guards is invisible in a decode check: the
        // stream is valid either way, the picture is just wrong.
        let blue = bgra_to_nv12(&solid(2, 2, 255, 0, 0), 2, 2);
        let (ub, vb) = uv_at(&blue, 0, 0);
        assert!(ub > 200, "pure blue must push U high, got {ub}");
        assert!(vb < 128, "pure blue must not push V high, got {vb}");

        let red = bgra_to_nv12(&solid(2, 2, 0, 0, 255), 2, 2);
        let (ur, vr) = uv_at(&red, 0, 0);
        assert!(vr > 200, "pure red must push V high, got {vr}");
        assert!(ur < 128, "pure red must not push U high, got {ur}");
    }

    #[test]
    fn green_is_the_brightest_primary() {
        // Catches transposed luma coefficients, which otherwise survive every
        // structural check.
        let y = |b, g, r| bgra_to_nv12(&solid(2, 2, b, g, r), 2, 2).data[0];
        let (r, g, b) = (y(0, 0, 255), y(0, 255, 0), y(255, 0, 0));
        assert!(g > r && r > b, "BT.709 luma order must be G>R>B, got {g}/{r}/{b}");
    }

    #[test]
    fn chroma_averages_the_block_rather_than_point_sampling() {
        // Half red, half blue in one 2x2 block must land between the two, not on
        // whichever pixel happened to be sampled.
        let mut px = Vec::new();
        px.extend_from_slice(&[0, 0, 255, 255]);
        px.extend_from_slice(&[255, 0, 0, 255]);
        px.extend_from_slice(&[0, 0, 255, 255]);
        px.extend_from_slice(&[255, 0, 0, 255]);
        let n = bgra_to_nv12(&px, 2, 2);
        let (u, v) = uv_at(&n, 0, 0);
        let pure_red_v = uv_at(&bgra_to_nv12(&solid(2, 2, 0, 0, 255), 2, 2), 0, 0).1;
        assert!(v < pure_red_v && v > 128, "V must sit between the two: {v}");
        assert!(u > 128, "U must sit between the two: {u}");
    }
}
