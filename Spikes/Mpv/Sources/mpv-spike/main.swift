import AppKit
import Foundation
import Libmpv

// mpv-spike matrix|churn|probe --path a|b|c --clips DIR --out DIR [--lock FILE] [--clip NAME]... [--hwdec M]
//   [--log-level L] [--no-size-guard] [--resize none|nudge|transform] [--no-srgb-tag] [--screen builtin|external] [--play SECONDS] [--loads N] [--rebuilds N]

struct Config: Sendable {
    var mode = "matrix"
    var path = "a"
    var clips = ""
    var out = "."
    var lock: String?
    var only: [String] = []
    var hwdec = "auto-safe"
    var logLevel = "info"
    var sizeGuard = true
    var play = 3.0
    var loads = 30
    var rebuilds = 20
    var resizeMode = ResizeMode.none
    var tagSRGB = true
    var screen = "builtin"
}

var cfg = Config()
var args = Array(CommandLine.arguments.dropFirst())
if let first = args.first, !first.hasPrefix("--") { cfg.mode = args.removeFirst() }
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { args.isEmpty ? "" : args.removeFirst() }
    switch a {
    case "--path": cfg.path = next()
    case "--clips": cfg.clips = next()
    case "--out": cfg.out = next()
    case "--lock": cfg.lock = next()
    case "--clip": cfg.only.append(next())
    case "--hwdec": cfg.hwdec = next()
    case "--log-level": cfg.logLevel = next()
    case "--no-size-guard": cfg.sizeGuard = false
    case "--resize": cfg.resizeMode = ResizeMode(rawValue: next()) ?? .none
    case "--screen": cfg.screen = next()
    case "--no-srgb-tag": cfg.tagSRGB = false
    case "--play": cfg.play = Double(next()) ?? 3
    case "--loads": cfg.loads = Int(next()) ?? 30
    case "--rebuilds": cfg.rebuilds = Int(next()) ?? 20
    default: FileHandle.standardError.write(Data("unknown arg \(a)\n".utf8)); exit(2)
    }
}

// MoltenVK logs every extension to stdout at its default level.
setenv("MVK_CONFIG_LOG_LEVEL", "1", 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let config = cfg
Task { @MainActor in
    let runner = Runner(config)
    let code = await runner.run()
    exit(code)
}
app.run()
