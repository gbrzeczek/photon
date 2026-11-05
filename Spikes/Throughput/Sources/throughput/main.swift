import Darwin
import Foundation

// throughput generate <scratch-root> <count>
// throughput device <file> [seconds]                           Raw sequential MB/s and random IOPS
// throughput bench <root> <stage> [--files N] [--order dir|fileid|random] [--jobs J] [--seconds S]
// Stages: enumerate, enumerate-fm, hash, metadata, thumb-embedded, thumb-full

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let imageTypes: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2"]

func refuseWritableExternal(_ root: String) {
    var st = statfs()
    guard statfs(root, &st) == 0 else { return }
    let mount = withUnsafeBytes(of: &st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    if st.f_flags & UInt32(MNT_RDONLY) == 0, mount.hasPrefix("/Volumes/"), args.contains("--allow-writable") == false {
        print("Refusing: \(mount) is writable. Mount it read-only, or pass --allow-writable for a scratch image.")
        exit(1)
    }
}

/// Picks `count` files evenly through the enumeration, so a sample spans the whole drive.
func sample(_ files: [Entry], count: Int) -> [Entry] {
    guard files.count > count else { return files }
    let step = Double(files.count) / Double(count)
    return (0..<count).map { files[Int(Double($0) * step)] }
}

func report(_ stage: String, order: String, jobs: Int, done: Int, seconds: Double, counters: Counters) {
    let rate = Double(done) / seconds
    let per100k = 100_000 / rate / 3600
    print(String(
        format: "%-16@ order=%-6@ jobs=%d files=%-6d %8.1f files/s  %7.2f h/100k  reads/file %.1f  KB/file %.0f  MB/s %.1f  failed %d",
        stage as NSString, order as NSString, jobs, done, rate, per100k,
        Double(counters.reads) / Double(max(done, 1)), Double(counters.bytes) / 1024 / Double(max(done, 1)),
        Double(counters.bytes) / 1e6 / seconds, counters.failures))
    if !counters.failedTypes.isEmpty { print("  failed by type: \(counters.failedTypes)") }
    let sizes = counters.sizes.sorted()
    if !sizes.isEmpty {
        print("  preview long edge: p10 \(sizes[sizes.count / 10]) px, median \(sizes[sizes.count / 2]) px, p90 \(sizes[sizes.count * 9 / 10]) px, of \(sizes.count) files")
    }
}

func measureDevice(path: String, seconds: Double) throws {
    let counters = Counters()
    guard let reader = Reader(path, counters: counters) else { print("cannot open"); exit(1) }
    defer { reader.finish() }
    print(String(format: "file size %.1f GB", Double(reader.size) / 1e9))

    var start = Date()
    var offset: Int64 = 0
    var bytes: Int64 = 0
    let block = 1 << 20
    while Date().timeIntervalSince(start) < seconds, offset + Int64(block) <= reader.size {
        guard let data = reader.read(offset: offset, length: block) else { break }
        offset += Int64(data.count)
        bytes += Int64(data.count)
    }
    print(String(format: "sequential: %.1f MB/s", Double(bytes) / 1e6 / Date().timeIntervalSince(start)))

    start = Date()
    var ops = 0
    var latencies: [Double] = []
    while Date().timeIntervalSince(start) < seconds {
        let t = Date()
        guard reader.read(offset: Int64.random(in: 0..<max(reader.size - 4096, 1)) & ~4095, length: 4096) != nil else { break }
        latencies.append(Date().timeIntervalSince(t))
        ops += 1
    }
    latencies.sort()
    print(String(format: "random 4K: %.0f IOPS, median %.2f ms, p99 %.2f ms", Double(ops) / Date().timeIntervalSince(start),
        latencies[latencies.count / 2] * 1000, latencies[latencies.count * 99 / 100] * 1000))
}

switch args.first {
case "generate":
    try generate(root: args[1], count: Int(args[2])!)

case "device":
    try measureDevice(path: args[1], seconds: args.count > 2 ? Double(args[2])! : 15)

case "bench":
    let root = args[1], stage = args[2]
    refuseWritableExternal(root)
    let wanted = Int(option("files", "1000"))!
    let order = option("order", "dir")
    let jobs = Int(option("jobs", "1"))!
    let limit = Double(option("seconds", "120"))!
    let counters = Counters()

    if stage == "enumerate" || stage == "enumerate-fm" {
        let t = Date()
        let count = stage == "enumerate" ? enumerateBulk(root).count : enumerateFileManager(root)
        let took = Date().timeIntervalSince(t)
        print(String(format: "%@: %d files in %.3f s, %.0f files/s, %.1f s per 100k", stage, count, took, Double(count) / took, 100_000 * took / Double(count)))
        break
    }

    var files = enumerateBulk(root)
    if stage != "hash" { files = files.filter { imageTypes.contains(($0.path as NSString).pathExtension.lowercased()) } }
    files = sample(files, count: wanted)
    switch order {
    case "fileid": files.sort { $0.fileID < $1.fileID }  // Start cluster on exFAT, so on-disk order.
    case "random": files.shuffle()
    default: break
    }

    let list = files
    let next = Counters2()
    let deadline = Date().addingTimeInterval(limit)
    let start = Date()
    let group = DispatchGroup()
    for _ in 0..<jobs {
        group.enter()
        Thread.detachNewThread {
            while Date() < deadline, let i = next.take(limit: list.count) {
                autoreleasepool {
                    guard let reader = Reader(list[i].path, counters: counters) else { counters.fail(); return }
                    defer { reader.finish() }
                    let ok: Bool
                    switch stage {
                    case "hash": ok = sampledHash(reader)
                    case "metadata": ok = metadata(reader, prefix: Int(option("prefix-kb", "256"))! * 1024)
                    case "thumb-embedded": ok = embeddedThumbnail(reader, prefix: Int(option("prefix-kb", "512"))! * 1024, maxPixels: 512)
                    case "thumb-full": ok = fullThumbnail(reader, maxPixels: 512)
                    default: fatalError("unknown stage")
                    }
                    if !ok { counters.fail(type: (list[i].path as NSString).pathExtension.lowercased()) }
                }
            }
            group.leave()
        }
    }
    group.wait()
    report(stage, order: order, jobs: jobs, done: min(next.taken, list.count), seconds: Date().timeIntervalSince(start), counters: counters)

default:
    print("usage: see Spikes/README.md")
    exit(2)
}

final class Counters2: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var taken = 0
    func take(limit: Int) -> Int? {
        lock.withLock {
            guard taken < limit else { return nil }
            taken += 1
            return taken - 1
        }
    }
}
