import AVFoundation
import Foundation
import PhotonCore
import PhotonIndex
import PhotonMedia
import Synchronization
import UniformTypeIdentifiers

/// Serves AVFoundation's reads of one file through the volume's I/O scheduler.
///
/// AVFoundation would otherwise open the file itself, which bypasses the scheduler: its reads couldn't be
/// cancelled on `willUnmount`, would hold a handle that blocks an eject, and might memory-map a file on
/// removable media. With a URL of our own scheme, every byte comes through `resourceLoader(_:shouldWaitFor...)`
/// instead, in jobs of at most `responseLimit`, each of which opens the file, checks it's the indexed one,
/// reads and closes it again.
final class ScheduledResourceLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let scheme = "photon-video"
    /// The most one loading request is answered with. AVFoundation asks again for the rest, so a request
    /// to the end of a large file never pulls all of it into memory, and no job holds the volume for long.
    static let responseLimit = 4 << 20

    let source: VideoSource
    let priority: IOPriority
    let queue = DispatchQueue(label: "app.photon.video.loader", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        /// The first read that failed for a reason that isn't the file's: a volume gone or failing.
        var readError: (any Error)?
    }

    init(source: VideoSource, priority: IOPriority) {
        self.source = source
        self.priority = priority
    }

    /// Why reading stopped, if it did. A playback or frame that fails after this failed because of the
    /// drive, not the file.
    var readError: (any Error)? { state.withLock { $0.readError } }

    /// A URL that means nothing outside this loader. The name keeps the extension, which AVFoundation
    /// looks at before it has the content type.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "file"
        components.path = "/" + source.path.name
        return components.url ?? URL(string: "\(Self.scheme)://file/video.\(source.fileExtension)")!
    }

    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Cancels every read under way. The loading requests fail, and nothing more is read until asked.
    func cancelAll() {
        let tasks = state.withLock { state in
            defer { state.tasks.removeAll() }
            return Array(state.tasks.values)
        }
        for task in tasks { task.cancel() }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard request.request.url?.scheme == Self.scheme else { return false }
        if let information = request.contentInformationRequest {
            information.contentType = Self.contentType(fileExtension: source.fileExtension)
            information.contentLength = source.size
            information.isByteRangeAccessSupported = true
            information.isEntireLengthAvailableOnDemand = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let start = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
        let wanted = data.requestsAllDataToEndOfResource ? source.size - start : Int64(data.requestedLength)
        let length = Int(max(0, min(wanted, Int64(Self.responseLimit), source.size - start)))
        let id = ObjectIdentifier(request)
        let box = UncheckedRequest(request: request)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(box, offset: start, length: length)
            self.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
        }
        state.withLock { $0.tasks[id] = task }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        let task = state.withLock { $0.tasks.removeValue(forKey: ObjectIdentifier(request)) }
        task?.cancel()
    }

    // MARK: Reading

    private func serve(_ box: UncheckedRequest, offset: Int64, length: Int) async {
        let request = box.request
        let source = source
        do {
            if length > 0 {
                try await source.scheduler.withFile(source.path, priority: priority) { file in
                    guard file.size == source.size, file.modifiedTime == source.modifiedTime else {
                        throw VideoReadError.fileChanged
                    }
                    // In pieces, so that AVFoundation can start on the first before the last arrives.
                    var position = offset
                    let end = offset + Int64(length)
                    while position < end {
                        let piece = try file.read(offset: position, length: Int(min(end - position, 1 << 20)))
                        guard !piece.isEmpty else { break }
                        box.request.dataRequest?.respond(with: piece)
                        position += Int64(piece.count)
                    }
                    guard try file.isUnchanged() else { throw VideoReadError.fileChanged }
                }
            }
            try Task.checkCancellation()
            request.finishLoading()
        } catch is CancellationError {
            // AVFoundation cancelled it, or `cancelAll` did. Either way it isn't waiting for an answer
            // it can use, but a request left open would never be released.
            if !request.isCancelled { request.finishLoading(with: CancellationError()) }
        } catch {
            if Self.isAboutTheDrive(error) {
                state.withLock { if $0.readError == nil { $0.readError = error } }
            }
            request.finishLoading(with: error)
        }
    }

    /// Anything but a bad file. A changed file counts, because it isn't the one that was indexed.
    private static func isAboutTheDrive(_ error: any Error) -> Bool {
        if error is VolumeIOError { return true }
        return error as? VideoReadError == .fileChanged
    }

    static func contentType(fileExtension: String) -> String {
        switch fileExtension {
        case "mov": return AVFileType.mov.rawValue
        case "mp4": return AVFileType.mp4.rawValue
        case "m4v": return AVFileType.m4v.rawValue
        case "3gp": return AVFileType.mobile3GPP.rawValue
        case "3g2": return AVFileType.mobile3GPP2.rawValue
        default: return UTType(filenameExtension: fileExtension)?.identifier ?? UTType.movie.identifier
        }
    }
}

/// AVFoundation's loading requests may be answered from any thread, but aren't marked as such.
private struct UncheckedRequest: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
}
