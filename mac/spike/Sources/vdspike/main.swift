import CoreGraphics
import Foundation

// Display Share — Phase 0 feasibility spike.
//
//   vdspike create   Task 0.1 — prove CGVirtualDisplay works on this hardware
//   vdspike capture  Task 0.2 — prove ScreenCaptureKit can capture it
//   vdspike bench    Task 0.3 — measure baseline capture cost
//
// Throwaway by design. Product code lives in mac/DisplayShare*.

struct Args {
    private var flags: [String: String] = [:]
    let subcommand: String

    init(_ argv: [String]) {
        var argv = argv
        argv.removeFirst()  // binary path
        subcommand = argv.first.map { $0.hasPrefix("--") ? "" : $0 } ?? ""
        if !subcommand.isEmpty { argv.removeFirst() }

        var i = 0
        while i < argv.count {
            let token = argv[i]
            guard token.hasPrefix("--") else { i += 1; continue }
            let key = String(token.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                flags[key] = argv[i + 1]
                i += 2
            } else {
                flags[key] = "true"
                i += 1
            }
        }
    }

    func int(_ key: String, _ fallback: Int) -> Int { flags[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { flags[key].flatMap(Double.init) ?? fallback }
    func string(_ key: String, _ fallback: String) -> String { flags[key] ?? fallback }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard let v = flags[key] else { return fallback }
        return v == "true" || v == "1" || v == "yes"
    }
}

func hostInfo() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [UInt8](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    let modelName = String(decoding: model.prefix(while: { $0 != 0 }), as: UTF8.self)
    let build =
        (try? String(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist", encoding: .utf8))
        .flatMap { text -> String? in
            guard let r = text.range(of: "ProductBuildVersion</key>") else { return nil }
            let tail = text[r.upperBound...]
            guard let s = tail.range(of: "<string>"), let e = tail.range(of: "</string>") else { return nil }
            return String(tail[s.upperBound..<e.lowerBound])
        } ?? "?"
    return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(build)) on \(modelName)"
}

let args = Args(CommandLine.arguments)

switch args.subcommand {
case "create":
    runCreate(args)
case "probe":
    runProbe(args)
case "list":
    runList(args)
case "capture":
    runCapture(args)
case "bench":
    runBench(args)
default:
    print("""
        vdspike — Display Share Phase 0 spike

        USAGE
          vdspike create  [--width 1920] [--height 1080] [--fps 60] [--hidpi true]
                          [--diagonal 15.6] [--duration 0]
          vdspike capture [--width ...] [--frames 100] [--fps 60] [--out ./spike-frames]
          vdspike bench   [--width ...] [--fps 30|60] [--seconds 10]

        --duration 0 holds the display until Ctrl-C.
        """)
    exit(2)
}
