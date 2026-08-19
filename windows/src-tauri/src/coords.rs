//! Mapping normalised pointer positions onto Windows' absolute mouse space
//! (Task 8.3).
//!
//! Three coordinate systems meet here, and conflating any two of them produces a
//! cursor that lands on the wrong screen:
//!
//! 1. **The wire** (SPEC §4.10) sends `x`/`y` in 0..1, normalised inside the
//!    VIDEO — which is one shared display, not the whole desktop.
//! 2. **The Windows desktop** is in physical pixels and may start at a negative
//!    origin, because the primary monitor defines (0,0) and anything to its left
//!    or above has negative coordinates.
//! 3. **SendInput with MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK** wants
//!    0..65535 spanning the ENTIRE virtual desktop.
//!
//! So a normalised 0.5 does not mean "half way across the virtual desktop"; it
//! means half way across the shared output, which may sit anywhere within it.
//! Sharing a second monitor and skipping step 2 is exactly the off-by-a-screen
//! bug this file exists to prevent.

/// A rectangle in Windows desktop pixels. `x`/`y` may be negative.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self { x, y, width, height }
    }
}

/// Converts a position normalised within `output` into absolute SendInput
/// coordinates across `virtual_desktop`.
///
/// Values outside 0..1 are clamped: the sender can legitimately report a
/// position slightly past the edge while the pointer is being pushed against it,
/// and wrapping to the far side of the desktop would be worse than stopping.
pub fn to_absolute(nx: f64, ny: f64, output: Rect, virtual_desktop: Rect) -> (i32, i32) {
    let nx = nx.clamp(0.0, 1.0);
    let ny = ny.clamp(0.0, 1.0);

    // Where this lands on the desktop, in pixels.
    let px = output.x as f64 + nx * output.width as f64;
    let py = output.y as f64 + ny * output.height as f64;

    // Then into 0..65535 across the whole virtual desktop. The divisor is
    // width-1, not width: with width the final pixel column maps to 65535 only
    // when nx overshoots, leaving the right-hand edge unreachable.
    let span_x = (virtual_desktop.width - 1).max(1) as f64;
    let span_y = (virtual_desktop.height - 1).max(1) as f64;
    let ax = (px - virtual_desktop.x as f64) * 65535.0 / span_x;
    let ay = (py - virtual_desktop.y as f64) * 65535.0 / span_y;

    (
        ax.round().clamp(0.0, 65535.0) as i32,
        ay.round().clamp(0.0, 65535.0) as i32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One 1920x1080 monitor at the origin — the simple case.
    fn single() -> (Rect, Rect) {
        let r = Rect::new(0, 0, 1920, 1080);
        (r, r)
    }

    #[test]
    fn corners_reach_the_full_range_on_a_single_monitor() {
        let (output, desktop) = single();
        assert_eq!(to_absolute(0.0, 0.0, output, desktop), (0, 0));
        // The far edge must be reachable; with the wrong divisor it stops short.
        assert_eq!(to_absolute(1.0, 1.0, output, desktop), (65535, 65535));
    }

    #[test]
    fn centre_is_the_middle() {
        let (output, desktop) = single();
        let (x, y) = to_absolute(0.5, 0.5, output, desktop);
        // Tolerance is expressed in PIXELS, not raw units: one pixel is
        // 65535/height ≈ 61 units on a 1080-tall screen, and the width-1 divisor
        // puts the midpoint half a pixel past centre by construction. Anything
        // under a pixel is invisible to the user; a raw-unit tolerance just
        // encodes the axis length.
        let unit_x = 65535 / desktop.width;
        let unit_y = 65535 / desktop.height;
        assert!((x - 32767).abs() <= unit_x, "x was {x}, off by more than a pixel");
        assert!((y - 32767).abs() <= unit_y, "y was {y}, off by more than a pixel");
    }

    #[test]
    fn sharing_the_second_monitor_does_not_land_on_the_first() {
        // Two 1920x1080 monitors side by side; we share the RIGHT one.
        let desktop = Rect::new(0, 0, 3840, 1080);
        let second = Rect::new(1920, 0, 1920, 1080);

        // The left edge of the second monitor is the MIDDLE of the desktop.
        let (x, _) = to_absolute(0.0, 0.0, second, desktop);
        assert!((x - 32767).abs() <= 20, "expected mid-desktop, got {x}");
        // Not zero — that would put the cursor on the wrong screen entirely,
        // which is the bug this whole module exists for.
        assert!(x > 30000, "cursor landed on the first monitor: {x}");

        let (x_right, _) = to_absolute(1.0, 0.0, second, desktop);
        assert_eq!(x_right, 65535);
    }

    #[test]
    fn a_monitor_left_of_primary_has_a_negative_origin() {
        // Windows puts (0,0) at the primary monitor, so a screen to its left
        // occupies negative coordinates. Treating the desktop as starting at 0
        // shifts everything by a full screen.
        let desktop = Rect::new(-1920, 0, 3840, 1080);
        let left = Rect::new(-1920, 0, 1920, 1080);

        assert_eq!(to_absolute(0.0, 0.0, left, desktop).0, 0);
        let (mid, _) = to_absolute(1.0, 0.0, left, desktop);
        assert!((mid - 32767).abs() <= 20, "expected mid-desktop, got {mid}");
    }

    #[test]
    fn a_taller_second_monitor_maps_vertically_too() {
        // Stacked vertically, and the desktop starts above the primary.
        let desktop = Rect::new(0, -1080, 1920, 2160);
        let top = Rect::new(0, -1080, 1920, 1080);
        assert_eq!(to_absolute(0.0, 0.0, top, desktop).1, 0);
        let (_, y) = to_absolute(0.0, 1.0, top, desktop);
        assert!((y - 32767).abs() <= 20, "expected mid-desktop, got {y}");
    }

    #[test]
    fn out_of_range_input_clamps_instead_of_wrapping() {
        let (output, desktop) = single();
        // A pointer pushed against the edge can report slightly past it.
        assert_eq!(to_absolute(-0.4, -0.4, output, desktop), (0, 0));
        assert_eq!(to_absolute(1.9, 1.9, output, desktop), (65535, 65535));
    }

    #[test]
    fn a_degenerate_desktop_does_not_divide_by_zero() {
        let tiny = Rect::new(0, 0, 1, 1);
        let (x, y) = to_absolute(0.5, 0.5, tiny, tiny);
        assert!((0..=65535).contains(&x) && (0..=65535).contains(&y));
    }
}
