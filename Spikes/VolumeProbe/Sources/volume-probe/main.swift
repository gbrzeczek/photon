import Foundation

// volume-probe snapshot <mount> <out.json> [sample]
// volume-probe compare <a.json> <b.json>
// volume-probe read-across-removal <file> read|mapped|imagesource
// volume-probe watch-unmount <file> close|hold
// volume-probe read-until-error <file>

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

do {
    switch args.dropFirst().first {
    case "snapshot":
        let snap = try takeSnapshot(mount: args[2], sample: args.count > 4 ? Int(args[4])! : 500)
        try encoder.encode(snap).write(to: URL(fileURLWithPath: args[3]))
        print("\(snap.volume.fsType) uuid=\(snap.volume.urlVolumeUUID ?? "nil") medium=\(snap.volume.mediumType ?? "unreported") protocol=\(snap.volume.deviceProtocol ?? "?") files=\(snap.fileCount)")
    case "compare":
        let a = try decoder.decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let b = try decoder.decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        compare(a, b)
    case "read-across-removal":
        try readAcrossRemoval(path: args[2], mode: ReadMode(rawValue: args[3])!)
    case "watch-unmount":
        try watchUnmount(path: args[2], closeOnWillUnmount: args[3] == "close")
    case "read-until-error":
        try readUntilError(path: args[2])
    default:
        print("usage: see Spikes/README.md")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
