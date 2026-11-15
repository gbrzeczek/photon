internal import GRDB

/// Schema migrations. Migrations that have shipped are immutable, because user libraries must survive
/// upgrades: to change the schema, add a new one. `SchemaSnapshotTests` fails if an old one is edited.
enum LibraryMigrations {
    static let current = "v6"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in try db.execute(sql: v1) }
        migrator.registerMigration("v2") { db in try db.execute(sql: v2) }
        migrator.registerMigration("v3") { db in try db.execute(sql: v3) }
        migrator.registerMigration("v4") { db in try db.execute(sql: v4) }
        migrator.registerMigration("v5") { db in try db.execute(sql: v5) }
        migrator.registerMigration("v6") { db in try db.execute(sql: v6) }
        return migrator
    }

    private static let v1 = """
        CREATE TABLE volumes (
            id INTEGER PRIMARY KEY,
            uuid TEXT NOT NULL,
            name TEXT NOT NULL,
            capacity INTEGER,
            filesystem TEXT,
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL
        );
        -- Not unique: clones share a UUID, and a reused drive gets a new row.
        CREATE INDEX volumes_uuid ON volumes(uuid);

        CREATE TABLE library_roots (
            id INTEGER PRIMARY KEY,
            volume_id INTEGER NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            added_at REAL NOT NULL,
            last_scan_completed_at REAL,
            UNIQUE (volume_id, relative_path)
        );

        CREATE TABLE assets (
            id INTEGER PRIMARY KEY,
            content_hash BLOB CHECK (content_hash IS NULL OR length(content_hash) = 32),
            kind INTEGER NOT NULL,
            width INTEGER,
            height INTEGER,
            orientation INTEGER,
            capture_date_ms INTEGER,
            capture_utc_offset_min INTEGER,
            duration_seconds REAL,
            dominant_color INTEGER,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            rotation INTEGER NOT NULL DEFAULT 0 CHECK (rotation BETWEEN 0 AND 3),
            created_at REAL NOT NULL
        );
        -- Partial, because provisional assets have no hash yet.
        CREATE UNIQUE INDEX assets_content_hash ON assets(content_hash) WHERE content_hash IS NOT NULL;
        CREATE INDEX assets_capture_date ON assets(capture_date_ms);
        CREATE INDEX assets_favorites ON assets(id) WHERE is_favorite = 1;

        CREATE TABLE file_instances (
            id INTEGER PRIMARY KEY,
            asset_id INTEGER NOT NULL REFERENCES assets(id),
            volume_id INTEGER NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
            directory TEXT NOT NULL,
            name TEXT NOT NULL,
            size INTEGER NOT NULL,
            modified_ns INTEGER NOT NULL,
            index_state INTEGER NOT NULL DEFAULT 0,
            index_attempts INTEGER NOT NULL DEFAULT 0,
            index_error TEXT,
            UNIQUE (volume_id, directory, name)
        );
        CREATE INDEX file_instances_asset ON file_instances(asset_id);
        CREATE INDEX file_instances_pending ON file_instances(volume_id, id) WHERE index_state = 0;

        CREATE TABLE stacks (
            id INTEGER PRIMARY KEY,
            kind INTEGER NOT NULL,
            cover_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE stack_members (
            stack_id INTEGER NOT NULL REFERENCES stacks(id) ON DELETE CASCADE,
            asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            position INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (stack_id, asset_id)
        ) WITHOUT ROWID;
        CREATE INDEX stack_members_asset ON stack_members(asset_id);

        CREATE TABLE albums (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            -- Non-null for smart albums, which are saved queries.
            smart_query TEXT,
            created_at REAL NOT NULL
        );
        CREATE TABLE album_assets (
            album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
            asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            position INTEGER NOT NULL DEFAULT 0,
            added_at REAL NOT NULL,
            PRIMARY KEY (album_id, asset_id)
        ) WITHOUT ROWID;
        CREATE INDEX album_assets_asset ON album_assets(asset_id);

        CREATE TABLE tags (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE
        );
        CREATE TABLE asset_tags (
            asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (asset_id, tag_id)
        ) WITHOUT ROWID;
        CREATE INDEX asset_tags_tag ON asset_tags(tag_id);

        -- Per-location view state: a folder on a volume, or an album.
        -- Anchored to an asset, never to a pixel offset.
        CREATE TABLE sessions (
            id INTEGER PRIMARY KEY,
            volume_id INTEGER REFERENCES volumes(id) ON DELETE CASCADE,
            relative_path TEXT,
            album_id INTEGER REFERENCES albums(id) ON DELETE CASCADE,
            sort_key TEXT NOT NULL,
            sort_ascending INTEGER NOT NULL DEFAULT 1,
            view_mode INTEGER NOT NULL DEFAULT 0,
            tile_size REAL,
            anchor_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL,
            updated_at REAL NOT NULL,
            CHECK ((volume_id IS NOT NULL AND relative_path IS NOT NULL) OR album_id IS NOT NULL)
        );
        CREATE UNIQUE INDEX sessions_folder ON sessions(volume_id, relative_path) WHERE volume_id IS NOT NULL;
        CREATE UNIQUE INDEX sessions_album ON sessions(album_id) WHERE album_id IS NOT NULL;
        CREATE INDEX sessions_anchor ON sessions(anchor_asset_id);
        """

    /// Thumbnails: pack files on the internal disk, with offsets here. Keyed by asset, because
    /// thumbnails describe content, and removed along with it.
    private static let v2 = """
        -- 0 = none, 1 = embedded preview only, 2 = complete, 3 = failed until the file changes.
        ALTER TABLE assets ADD COLUMN thumbnail_state INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX assets_thumbnail_pending ON assets(id) WHERE thumbnail_state < 2 AND kind = 1;

        CREATE TABLE thumbnail_packs (
            id INTEGER PRIMARY KEY,
            tier INTEGER NOT NULL,
            byte_count INTEGER NOT NULL DEFAULT 0,
            last_used_at REAL NOT NULL
        );
        CREATE TABLE thumbnails (
            asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
            -- 0 = embedded preview, 1 = small, 2 = large.
            tier INTEGER NOT NULL,
            pack_id INTEGER NOT NULL REFERENCES thumbnail_packs(id) ON DELETE CASCADE,
            byte_offset INTEGER NOT NULL,
            byte_count INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            PRIMARY KEY (asset_id, tier)
        ) WITHOUT ROWID;
        CREATE INDEX thumbnails_pack ON thumbnails(pack_id);
        """

    /// Session restore: the current item can be somewhere other than what's on screen, and the viewer
    /// may have been open. `anchor_asset_id` stays what the view keeps on screen.
    private static let v3 = """
        ALTER TABLE sessions ADD COLUMN current_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL;
        -- How far down the viewport the anchor was, from 0 to 1, so that it doesn't depend on window size.
        ALTER TABLE sessions ADD COLUMN anchor_position REAL;
        ALTER TABLE sessions ADD COLUMN viewer_open INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX sessions_current ON sessions(current_asset_id);
        -- The anchor was the current item when there was one, and nothing here says which it was.
        UPDATE sessions SET current_asset_id = anchor_asset_id;
        """

    /// Organization: a session for every source, not only folders and albums, and stacks found by cover.
    /// SQLite can't change a CHECK constraint, so `sessions` is rebuilt.
    private static let v4 = """
        CREATE TABLE sessions_v4 (
            id INTEGER PRIMARY KEY,
            volume_id INTEGER REFERENCES volumes(id) ON DELETE CASCADE,
            relative_path TEXT,
            album_id INTEGER REFERENCES albums(id) ON DELETE CASCADE,
            tag_id INTEGER REFERENCES tags(id) ON DELETE CASCADE,
            -- 1 = All Items, 2 = Favorites.
            library_source INTEGER,
            sort_key TEXT NOT NULL,
            sort_ascending INTEGER NOT NULL DEFAULT 1,
            view_mode INTEGER NOT NULL DEFAULT 0,
            tile_size REAL,
            anchor_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL,
            updated_at REAL NOT NULL,
            current_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL,
            anchor_position REAL,
            viewer_open INTEGER NOT NULL DEFAULT 0,
            CHECK ((volume_id IS NOT NULL AND relative_path IS NOT NULL) OR album_id IS NOT NULL
                OR tag_id IS NOT NULL OR library_source IS NOT NULL)
        );
        INSERT INTO sessions_v4 (id, volume_id, relative_path, album_id, sort_key, sort_ascending, view_mode,
            tile_size, anchor_asset_id, updated_at, current_asset_id, anchor_position, viewer_open)
        SELECT id, volume_id, relative_path, album_id, sort_key, sort_ascending, view_mode,
            tile_size, anchor_asset_id, updated_at, current_asset_id, anchor_position, viewer_open
        FROM sessions;
        DROP TABLE sessions;
        ALTER TABLE sessions_v4 RENAME TO sessions;
        CREATE UNIQUE INDEX sessions_folder ON sessions(volume_id, relative_path) WHERE volume_id IS NOT NULL;
        CREATE UNIQUE INDEX sessions_album ON sessions(album_id) WHERE album_id IS NOT NULL;
        CREATE UNIQUE INDEX sessions_tag ON sessions(tag_id) WHERE tag_id IS NOT NULL;
        CREATE UNIQUE INDEX sessions_library ON sessions(library_source) WHERE library_source IS NOT NULL;
        CREATE INDEX sessions_anchor ON sessions(anchor_asset_id);
        CREATE INDEX sessions_current ON sessions(current_asset_id);

        CREATE INDEX stacks_cover ON stacks(cover_asset_id);
        CREATE INDEX albums_name ON albums(name COLLATE NOCASE);
        """

    /// Which folders are open in the sidebar's tree, so it comes back as it was left.
    private static let v5 = """
        CREATE TABLE expanded_folders (
            volume_id INTEGER NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            PRIMARY KEY (volume_id, relative_path)
        ) WITHOUT ROWID;
        """

    /// The libmpv fallback arrived, so videos that no engine could decode get another try. Changes data
    /// only, not the schema.
    ///
    /// - Thumbnails: a format with no engine was marked failed without a read, and so was a file
    ///   AVFoundation opened but couldn't decode, which mpv may. Every failed video goes back to waiting.
    ///   One that still fails is marked again after one more read.
    /// - Metadata: MKV, AVI and the other containers had none, because nothing read them. Their files go
    ///   back to pending, and indexing reads them again. The content is the same, so each keeps its asset
    ///   and gains what was missing.
    private static let v6 = """
        UPDATE assets SET thumbnail_state = 0 WHERE kind = 2 AND thumbnail_state = 3;
        UPDATE file_instances SET index_state = 0, index_attempts = 0, index_error = NULL
        WHERE index_state != 0 AND asset_id IN (
            SELECT id FROM assets WHERE kind = 2 AND width IS NULL AND duration_seconds IS NULL
        );
        """
}
