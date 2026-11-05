import Foundation

// Tiny app for Spike 5. Launched through LaunchServices, so TCC treats it as its own client
// rather than as part of the shell that started it. It tries to list a directory, then logs
// the outcome. The first arguments are passed with `open --args`.
let args = CommandLine.arguments
let target = args.count > 1 ? args[1] : "/Volumes"
let logPath = args.count > 2 ? args[2] : NSTemporaryDirectory() + "signing-probe.log"
let build = (Bundle.main.infoDictionary?["SpikeBuild"] as? String) ?? "?"

func note(_ text: String) {
    let line = "\(Date()) build=\(build) \(text)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

let start = Date()
errno = 0
if let dir = opendir(target) {
    var names = 0
    while readdir(dir) != nil { names += 1 }
    closedir(dir)
    note("listed \(target): \(names) entries in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
} else {
    note("failed \(target): errno \(errno) \(String(cString: strerror(errno))) after \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
}
