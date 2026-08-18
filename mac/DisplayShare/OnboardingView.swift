import DisplayShareCore
import SwiftUI

/// First-run flow.
///
/// The bar the task sets is that someone who has never seen the app reaches a
/// working second display without reading documentation. So the design rules are:
///
/// * one screen, no wizard paging — the whole path is visible at once
/// * each permission says WHY in the user's terms, not the API's
/// * status updates itself; nothing says "restart the app and try again" unless
///   macOS genuinely leaves no alternative
/// * Accessibility is optional and clearly marked, because a second screen works
///   without it — only remote control needs it
struct OnboardingView: View {
    @ObservedObject var monitor: PermissionMonitor
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                PermissionRow(
                    index: 1,
                    title: "Screen Recording",
                    required: true,
                    why:
                        "Display Share captures the extra display it creates so it can send it to your other laptop. It only ever captures its own virtual display — never your real screen.",
                    state: monitor.screenRecording,
                    actionTitle: "Open Screen Recording Settings",
                    action: { monitor.requestScreenRecording() },
                    relaunch: { monitor.relaunch() })

                PermissionRow(
                    index: 2,
                    title: "Accessibility",
                    required: false,
                    why:
                        "Optional. Only needed if you want to use the other laptop's mouse and keyboard to control your Mac. A second screen works fine without it.",
                    state: monitor.accessibility,
                    actionTitle: "Open Accessibility Settings",
                    action: { monitor.requestAccessibility() },
                    relaunch: nil)
            }
            .padding(22)

            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear { monitor.startMonitoring() }
        .onDisappear { monitor.stopMonitoring() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Display Share").font(.title2.weight(.semibold))
            Text(
                "Turn your Windows laptop into a second display for this Mac. "
                    + "macOS needs one permission before it can start."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
    }

    private var footer: some View {
        HStack {
            // Honest about what happens next, rather than a bare "Done".
            Text(
                monitor.screenRecordingGranted
                    ? "You're ready. Display Share lives in the menu bar."
                    : "Grant Screen Recording above to continue."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Button(monitor.screenRecordingGranted ? "Start Display Share" : "Skip for now") {
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
            // Never trap the user: skipping is allowed, the menu bar explains
            // what is missing.
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
    }
}

private struct PermissionRow: View {
    let index: Int
    let title: String
    let required: Bool
    let why: String
    let state: PermissionMonitor.State
    let actionTitle: String
    let action: () -> Void
    let relaunch: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(required ? "Required" : "Optional")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(required ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.18))
                        .clipShape(Capsule())
                    Spacer()
                    statusLabel
                }

                Text(why)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch state {
                case .granted:
                    EmptyView()
                case .grantedNeedsRestart:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Permission is granted, but macOS won't let this copy start capturing until it restarts."
                        )
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        if let relaunch {
                            Button("Restart Display Share", action: relaunch)
                        }
                    }
                case .denied, .unknown:
                    HStack(spacing: 10) {
                        Button(actionTitle, action: action)
                        Text("Then switch back — this updates on its own.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var badge: some View {
        ZStack {
            Circle()
                .fill(state == .granted ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 26, height: 26)
            if state == .granted {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
            } else {
                Text("\(index)").font(.caption.weight(.semibold))
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch state {
        case .granted:
            Text("Granted").font(.caption).foregroundStyle(.green)
        case .grantedNeedsRestart:
            Text("Granted — restart").font(.caption).foregroundStyle(.orange)
        case .denied:
            Text("Not granted").font(.caption).foregroundStyle(.secondary)
        case .unknown:
            Text("Checking…").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
