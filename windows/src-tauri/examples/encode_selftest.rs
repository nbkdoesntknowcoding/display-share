//! Task 8.1 acceptance check: prove the encoder emits a decodable, B-frame-free
//! Annex-B stream.
//!
//! Fed SYNTHETIC frames rather than the real desktop, on purpose. Desktop
//! duplication needs an interactive session that a CI runner may or may not
//! have, and a test that is skipped half the time proves nothing. This exercises
//! exactly the part of the path that a Mac cannot compile — colour conversion,
//! the MFT setup, and the Annex-B repair — and leaves DXGI to be proven on real
//! hardware by `capture_probe`.
//!
//! Writes an .h264 file for ffprobe to check.

fn main() {
    #[cfg(not(target_os = "windows"))]
    {
        eprintln!("encode self-test is Windows-only");
        std::process::exit(2);
    }

    #[cfg(target_os = "windows")]
    {
        use display_share_receiver_lib::{annexb, convert, encode};

        let (w, h, fps) = (640u32, 360u32, 30u32);
        let out_path = std::env::args().nth(1).unwrap_or_else(|| "selftest.h264".into());

        let mut encoder = match encode::H264Encoder::new(w, h, fps, 2_000_000) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("FAIL: could not create encoder: {e}");
                std::process::exit(1);
            }
        };

        let mut stream: Vec<u8> = Vec::new();
        let mut keyframes = 0usize;
        let mut emitted = 0usize;

        for i in 0..60u32 {
            // A moving block: a static image compresses to almost nothing and
            // would not exercise inter prediction at all.
            let mut bgra = vec![16u8; (w * h * 4) as usize];
            let x0 = (i * 7) % (w - 64);
            for y in 40..140u32 {
                for x in x0..x0 + 64 {
                    let o = ((y * w + x) * 4) as usize;
                    bgra[o] = 40;
                    bgra[o + 1] = 200;
                    bgra[o + 2] = 220;
                    bgra[o + 3] = 255;
                }
            }
            let nv12 = convert::bgra_to_nv12(&bgra, w, h);
            // Force an IDR on the first frame, exactly as a client connecting
            // mid-stream would.
            match encoder.encode(&nv12, i == 0) {
                Ok(frames) => {
                    for f in frames {
                        emitted += 1;
                        if f.keyframe {
                            keyframes += 1;
                            if !annexb::has_parameter_sets(&f.data) {
                                eprintln!("FAIL: keyframe {emitted} has no in-band SPS");
                                std::process::exit(1);
                            }
                        }
                        stream.extend_from_slice(&f.data);
                    }
                }
                Err(e) => {
                    eprintln!("FAIL: encode error on frame {i}: {e}");
                    std::process::exit(1);
                }
            }
        }

        if emitted == 0 || keyframes == 0 {
            eprintln!("FAIL: {emitted} access units, {keyframes} keyframes");
            std::process::exit(1);
        }
        if let Err(e) = std::fs::write(&out_path, &stream) {
            eprintln!("FAIL: could not write {out_path}: {e}");
            std::process::exit(1);
        }
        println!(
            "ok: {emitted} access units, {keyframes} keyframes, {} bytes -> {out_path}",
            stream.len()
        );
        println!("first access unit: {}", annexb::nal_summary(&stream[..stream.len().min(400)]));
    }
}
