//! Runs the Task 8.1 sender so a scripted WebSocket client can be pointed at it.
//!
//! Defaults to the synthetic source: desktop duplication needs an interactive
//! session with a GPU, which a hosted CI runner does not reliably have, and a
//! test that quietly skips proves nothing. Pass `desktop` to capture the real
//! screen on real hardware.
//!
//!   cargo run --example serve_selftest -- [port] [desktop|synthetic]

fn main() {
    #[cfg(not(target_os = "windows"))]
    {
        eprintln!("the sender is Windows-only");
        std::process::exit(2);
    }

    #[cfg(target_os = "windows")]
    {
        use display_share_receiver_lib::sender;

        let mut args = std::env::args().skip(1);
        let port: u16 = args.next().and_then(|s| s.parse().ok()).unwrap_or(7879);
        let source = match args.next().as_deref() {
            Some("desktop") => sender::Source::Desktop { output: 0 },
            _ => sender::Source::Synthetic { width: 640, height: 360 },
        };

        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async move {
            match sender::serve(port, source, 30, 2_000_000).await {
                Ok(_handle) => {
                    // Printed before blocking so a test harness can wait for
                    // this line instead of sleeping and hoping.
                    println!("listening on ws://127.0.0.1:{port}");
                    use std::io::Write;
                    let _ = std::io::stdout().flush();
                    std::future::pending::<()>().await;
                }
                Err(e) => {
                    eprintln!("FAIL: {e}");
                    std::process::exit(1);
                }
            }
        });
    }
}
