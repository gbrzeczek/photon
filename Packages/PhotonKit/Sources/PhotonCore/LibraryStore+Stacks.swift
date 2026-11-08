import Foundation
internal import GRDB

/// What pairing changed.
public struct PairingReport: Hashable, Sendable {
    public var added = 0
    public var removed = 0
    public init() {}
}

extension LibraryStore {
    /// The pairing stage: RAW+JPEG and Live Photo stacks, found by name alone, so no file is read. It
    /// writes only what differs from the stacks stored, so an unchanged rescan writes nothing.
    @discardableResult
    public func pairStacks(volume: VolumeID, now: Date = Date()) async throws -> PairingReport {
        try await pool.write { db in
            let files = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.asset_id, f.directory, f.name, a.kind, a.duration_seconds
                    FROM file_instances f JOIN assets a ON a.id = f.asset_id WHERE f.volume_id = ?
                    """,
                arguments: [volume.rawValue]
            ).map { row in
                StackPairing.File(
                    asset: row[0], directory: row[1], name: row[2], kind: MediaKind(rawValue: row[3]) ?? .photo,
                    duration: row[4])
            }
            let wanted = StackPairing.stacks(in: files)

            // Stored automatic stacks with a member on this volume.
            var stored: [StackPairing.Stack: Int64] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id, s.kind, s.cover_asset_id, m.asset_id FROM stacks s
                    JOIN stack_members m ON m.stack_id = s.id
                    WHERE s.kind IN (1, 2) AND s.id IN (
                        SELECT m2.stack_id FROM stack_members m2 JOIN file_instances f ON f.asset_id = m2.asset_id
                        WHERE f.volume_id = ?)
                    ORDER BY s.id, m.position
                    """,
                arguments: [volume.rawValue])
            var grouped: [Int64: (kind: Int, cover: Int64?, members: [Int64])] = [:]
            for row in rows {
                let id: Int64 = row[0]
                grouped[id, default: (row[1], row[2], [])].members.append(row[3])
            }
            var report = PairingReport()
            var outdated: [Int64] = []
            for (id, stack) in grouped.sorted(by: { $0.key < $1.key }) {
                guard let kind = StackKind(rawValue: stack.kind), let cover = stack.cover else {
                    outdated.append(id)
                    continue
                }
                let key = StackPairing.Stack(kind: kind, members: [cover] + stack.members.filter { $0 != cover })
                if !wanted.contains(key) || stored[key] != nil {
                    outdated.append(id)
                } else {
                    stored[key] = id
                }
            }
            for id in outdated {
                try db.execute(sql: "DELETE FROM stacks WHERE id = ?", arguments: [id])
                report.removed += 1
            }
            for stack in wanted where stored[stack] == nil {
                // An asset is in at most one stack. Anything else holding these is out of date.
                let marks = databaseQuestionMarks(count: stack.members.count)
                try db.execute(
                    sql: "DELETE FROM stacks WHERE id IN (SELECT stack_id FROM stack_members WHERE asset_id IN (\(marks)))",
                    arguments: StatementArguments(stack.members))
                report.removed += db.changesCount
                try db.execute(
                    sql: "INSERT INTO stacks (kind, cover_asset_id, created_at) VALUES (?, ?, ?)",
                    arguments: [stack.kind.rawValue, stack.members[0], now.timeIntervalSince1970])
                let id = db.lastInsertedRowID
                for (position, member) in stack.members.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO stack_members (stack_id, asset_id, position) VALUES (?, ?, ?)",
                        arguments: [id, member, position])
                }
                report.added += 1
            }
            return report
        }
    }
}

/// The pairing rules, from docs/PLAN.md, apart from the database so they can be tested on their own.
enum StackPairing {
    struct File {
        var asset: Int64
        var directory: String
        var name: String
        var kind: MediaKind
        var duration: Double?
    }

    struct Stack: Hashable {
        var kind: StackKind
        /// The cover first.
        var members: [Int64]
    }

    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f",
        "3fr", "erf", "kdc", "mrw", "raw", "rwl", "iiq",
    ]
    static let stillExtensions: Set<String> = ["jpg", "jpeg", "jpe", "heic", "heif", "hif"]
    static let motionExtensions: Set<String> = ["mov", "mp4"]
    /// A Live Photo's movie is about 3 seconds.
    static let maximumMotionSeconds = 4.0

    static func stacks(in files: [File]) -> Set<Stack> {
        struct Key: Hashable {
            var directory: String
            var base: String
        }
        var groups: [Key: [(file: File, ext: String)]] = [:]
        for file in files {
            let path = RelativePath(directory: file.directory, name: file.name)
            let ext = path.fileExtension.lowercased()
            guard !ext.isEmpty else { continue }
            let base = String(file.name.dropLast(ext.count + 1)).lowercased()
            groups[Key(directory: file.directory, base: base), default: []].append((file, ext))
        }
        var used = Set<Int64>()
        var stacks = Set<Stack>()
        // In a stable order, so that a conflict always resolves the same way.
        for key in groups.keys.sorted(by: { ($0.directory, $0.base) < ($1.directory, $1.base) }) {
            let group = groups[key]!
            guard group.count >= 2 else { continue }
            let still = group.first { $0.file.kind == .photo && stillExtensions.contains($0.ext) }?.file
            let raw = group.first { $0.file.kind == .photo && rawExtensions.contains($0.ext) }?.file
            let motion = group.first {
                $0.file.kind == .video && motionExtensions.contains($0.ext)
                    && ($0.file.duration.map { $0 <= maximumMotionSeconds } ?? false)
            }?.file
            guard let still else { continue }
            let stack: Stack
            if let raw {
                stack = Stack(kind: .rawAndJPEG, members: [still.asset, raw.asset])
            } else if let motion {
                stack = Stack(kind: .livePhoto, members: [still.asset, motion.asset])
            } else {
                continue
            }
            // Two copies of one content, or an asset already stacked elsewhere, make no stack.
            guard Set(stack.members).count == stack.members.count, used.isDisjoint(with: stack.members) else {
                continue
            }
            used.formUnion(stack.members)
            stacks.insert(stack)
        }
        return stacks
    }
}
