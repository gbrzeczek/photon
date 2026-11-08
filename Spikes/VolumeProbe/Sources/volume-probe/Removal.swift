import AppKit
import DiskArbitration
import Foundation
import ImageIO

/// How a child process reads a file while its volume disappears underneath it.
enum ReadMode: String { case read, mapped, imagesource }

func log(_ message: String) {
    let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
    FileHandle.standardOutput.write(Data("\(stamp) \(message)\n".utf8))
}

/// Opens `path`, prints READY, waits for a line on stdin (the parent removes the volume first),
/// then keeps reading. If the process dies with SIGBUS, the parent sees that as the result.
func readAcrossRemoval(path: String, mode: ReadMode) throws {
    switch mode {
    case .read:
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw posix("open") }
        _ = fcntl(fd, F_NOCACHE, 1)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        _ = pread(fd, &buffer, buffer.count, 0)
        log("READY")
        _ = readLine()
        var offset: off_t = 1 << 20
        let start = Date()
        var worst = 0.0
        for _ in 0..<512 {
            let t = Date()
            let n = pread(fd, &buffer, buffer.count, offset)
            worst = max(worst, Date().timeIntervalSince(t))
            if n < 0 {
                log("read error after removal: errno \(errno) \(String(cString: strerror(errno))), slowest call \(worst)s, total \(Date().timeIntervalSince(start))s")
                close(fd)
                log("close returned")
                return
            }
            if n == 0 { break }
            offset += off_t(n)
        }
        log("read loop ended with no error, slowest call \(worst)s")

    case .mapped:
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        // Touch only the first page, so the rest has to fault in after the volume goes away.
        var sum = Int(data[0])
        log("READY")
        _ = readLine()
        for offset in stride(from: 1 << 20, to: data.count, by: 4096) { sum &+= Int(data[offset]) }
        log("mapped read survived, sum \(sum)")

    case .imagesource:
        // The shape AGENTS.md forbids on removable media: a URL handed straight to ImageIO.
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { throw posix("CGImageSourceCreateWithURL") }
        let count = CGImageSourceGetCount(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        log("READY")
        log("image count \(count), width \(props?[kCGImagePropertyPixelWidth as String] ?? "nil")")
        _ = readLine()
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        log("imagesource decode after removal: \(image == nil ? "nil image, no crash" : "got image \(image!.width)x\(image!.height)")")
    }
}

/// Holds a file open on the volume. On willUnmount it closes the file if `closeOnWillUnmount`,
/// which is the behavior AGENTS.md requires, and logs how long each stage took.
func watchUnmount(path: String, closeOnWillUnmount: Bool) throws {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { throw posix("open") }
    nonisolated(unsafe) var openFD: Int32 = fd
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { note in
        log("willUnmount \(note.userInfo?["NSDevicePath"] ?? "?")")
        if closeOnWillUnmount, openFD >= 0 {
            close(openFD)
            openFD = -1
            log("closed handle")
        }
    }
    center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
        log("didUnmount \(note.userInfo?["NSDevicePath"] ?? "?")")
        exit(0)
    }
    log("READY")
    RunLoop.main.run(until: Date().addingTimeInterval(40))
    log("timed out with no didUnmount")
    exit(3)
}

/// Reads in a loop until the volume disappears and reports how long the failing call blocked. A
/// watchdog prints while a read is stuck. Use it on disk images only: a physical pull is no longer
/// part of testing. See docs/PLAN.md, Removable media checks.
func readUntilError(path: String) throws {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { throw posix("open") }
    _ = fcntl(fd, F_NOCACHE, 1)
    var size = stat()
    guard fstat(fd, &size) == 0 else { throw posix("fstat") }
    nonisolated(unsafe) var started = Date()
    Thread.detachNewThread {
        while true {
            sleep(1)
            let stuck = Date().timeIntervalSince(started)
            if stuck > 2 { log("read has been blocked for \(String(format: "%.1f", stuck))s") }
        }
    }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var offset: off_t = 0
    var worst = 0.0
    log("READY: detach the disk image now, Ctrl-C to stop")
    while true {
        started = Date()
        let n = pread(fd, &buffer, buffer.count, offset)
        let took = Date().timeIntervalSince(started)
        worst = max(worst, took)
        if n < 0 {
            log("error errno \(errno) \(String(cString: strerror(errno))), failing call blocked \(took)s, slowest good call \(worst)s")
            let closing = Date()
            close(fd)
            log("close took \(Date().timeIntervalSince(closing))s")
            return
        }
        offset = n == 0 ? 0 : (offset + off_t(n)) % max(size.st_size, 1)
    }
}
