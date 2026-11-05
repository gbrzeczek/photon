import CryptoKit
import Foundation
import PhotonCore
import Testing

@testable import PhotonIndex

@Suite("Sampled content hash")
struct ContentHasherTests {
    private let chunk = ContentHasher.chunkSize

    private func hash(_ data: Data) throws -> ContentHash {
        try ContentHasher.hash(DataByteSource(data))
    }

    @Test("Hashes are stable: changing this one changes every asset's identity")
    func goldenValues() throws {
        #expect(try hash(Data()).hex == "af5570f5a1810b7af78caf4bc70a660f0df51e42baf91d4de5b2328de0e83dfc")
        #expect(try hash(Data("photon".utf8)).hex == sha256(sizePrefix: 6, Data("photon".utf8)))
    }

    private func sha256(sizePrefix: UInt64, _ data: Data) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: sizePrefix.littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    @Test("Up to three chunks, the whole file is hashed")
    func smallFiles() throws {
        let data = randomData(chunk * 3)
        #expect(try hash(data).hex == sha256(sizePrefix: UInt64(data.count), data))
    }

    @Test("One byte over, it switches to head, middle and tail")
    func samplingBoundary() throws {
        let size = chunk * 3 + 1
        let data = randomData(size)
        let source = CountingSource(data)
        let result = try ContentHasher.hash(source)
        #expect(source.bytesRead == chunk * 3)
        #expect(source.reads.map(\.offset) == [0, Int64(size / 2 - chunk / 2), Int64(size - chunk)])

        let expected =
            data.subdata(in: 0..<chunk)
            + data.subdata(in: (size / 2 - chunk / 2)..<(size / 2 - chunk / 2 + chunk))
            + data.subdata(in: (size - chunk)..<size)
        #expect(result.hex == sha256(sizePrefix: UInt64(size), expected))
    }

    @Test("A large file costs three small reads")
    func largeFileReadsLittle() throws {
        let source = CountingSource(randomData(5 << 20))
        _ = try ContentHasher.hash(source)
        #expect(source.reads.count == 3)
        #expect(source.bytesRead == chunk * 3)
    }

    @Test("A change to a sampled region changes the hash", arguments: [0, 2 << 20, (4 << 20) - 1])
    func sampledChange(offset: Int) throws {
        var data = randomData(4 << 20)
        let original = try hash(data)
        data[offset] ^= 0xFF
        #expect(try hash(data) != original)
    }

    @Test("A different size changes the hash, even with the same samples")
    func sizeIsHashed() throws {
        let data = randomData(1 << 20)
        var longer = data
        longer.insert(contentsOf: Data(count: 1), at: 200_000)
        #expect(try hash(data) != hash(data.prefix(data.count - 1)))
        #expect(data.count != longer.count)
        #expect(try hash(longer) != hash(data))
    }

    @Test("A change between samples goes unseen, which is why a sampled hash can't justify a destructive action")
    func unsampledChangeIsInvisible() throws {
        var data = randomData(4 << 20)
        let original = try hash(data)
        data[1 << 20] ^= 0xFF
        #expect(try hash(data) == original)
    }

    @Test("A file that shrinks while being hashed fails, and never yields a hash of nothing")
    func shortReadThrows() throws {
        let source = CountingSource(randomData(1 << 20))
        source.shortReadAfter = 1
        #expect(throws: IndexingError.fileChanged) { try ContentHasher.hash(source) }
    }

    @Test("Metadata and hashing share the first read")
    func prefixIsReused() throws {
        let data = randomData(1 << 20)
        let base = CountingSource(data)
        let cached = PrefixCachingSource(base)
        _ = try cached.read(offset: 0, length: 256 * 1024)
        let direct = try ContentHasher.hash(cached)

        #expect(direct == (try hash(data)))
        // The head chunk came from the cached prefix, so only the middle and tail reached the source.
        #expect(base.reads.count == 3)
        #expect(base.reads[0].length == 256 * 1024)
        #expect(base.reads[1].offset != 0)
    }

    @Test("A cached prefix also serves reads inside it, and past-the-end reads still work")
    func cachedReadsAreCorrect() throws {
        let data = randomData(1000)
        let cached = PrefixCachingSource(CountingSource(data))
        _ = try cached.read(offset: 0, length: 1000)
        #expect(try cached.read(offset: 10, length: 20) == data.subdata(in: 10..<30))
        #expect(try cached.read(offset: 990, length: 50) == data.subdata(in: 990..<1000))
        #expect(try cached.read(offset: 2000, length: 50).isEmpty)
    }
}
