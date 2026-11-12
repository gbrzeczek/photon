import Foundation
internal import GRDB

extension LibraryStore {
    /// The folders open in the sidebar's tree.
    public func expandedFolders() async throws -> Set<BrowseScope> {
        try await pool.read { db in
            Set(
                try Row.fetchAll(db, sql: "SELECT volume_id, relative_path FROM expanded_folders").map { row in
                    BrowseScope(volume: VolumeID(rawValue: row["volume_id"]), path: row["relative_path"])
                })
        }
    }

    /// Opens or closes a folder in the tree. A volume that has gone since leaves nothing to save.
    public func setFolder(_ scope: BrowseScope, expanded: Bool) async throws {
        try await pool.write { db in
            if expanded {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO expanded_folders (volume_id, relative_path)
                        SELECT id, ? FROM volumes WHERE id = ?
                        """,
                    arguments: [scope.path, scope.volume.rawValue])
            } else {
                try db.execute(
                    sql: "DELETE FROM expanded_folders WHERE volume_id = ? AND relative_path = ?",
                    arguments: [scope.volume.rawValue, scope.path])
            }
        }
    }
}
