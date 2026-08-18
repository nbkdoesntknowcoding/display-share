import DisplayShareCore
import SwiftUI

/// Shown when the user opens an already-running Display Share.
///
/// Exists because the app is LSUIElement — no Dock icon, no window — so
/// double-clicking it in Finder previously did nothing visible and looked
/// broken. This says where it lives and what it is doing.
struct RunningView: View {
    @ObservedObject var controller: DisplayShareController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Display Share is running").font(.headline)

            Label(
                "Look for the display icon in the menu bar, at the top-right of the screen. "
                    + "Everything is controlled from there — this app has no Dock icon by design.",
                systemImage: "menubar.arrow.up.rectangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            switch controller.state {
            case .active(let id):
                Label(
                    "Second display is live (0x\(String(id, radix: 16))).",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                if let url = controller.streamURL {
                    Text("Receiver address: \(url)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .starting:
                Label("Starting…", systemImage: "hourglass")
            case .idle:
                Label("Not started yet — use Start in the menu bar.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                if controller.state.isActive {
                    Button("Stop") { controller.stop() }
                } else {
                    Button("Start") { controller.start() }.keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button("Quit Display Share") {
                    controller.shutdownForQuit()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
