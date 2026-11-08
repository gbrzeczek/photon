CREATE TABLE album_assets (
    album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    added_at REAL NOT NULL,
    PRIMARY KEY (album_id, asset_id)
) WITHOUT ROWID;

CREATE TABLE albums (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    -- Non-null for smart albums, which are saved queries.
    smart_query TEXT,
    created_at REAL NOT NULL
);

CREATE TABLE asset_tags (
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (asset_id, tag_id)
) WITHOUT ROWID;

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
, thumbnail_state INTEGER NOT NULL DEFAULT 0);

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

CREATE TABLE library_roots (
    id INTEGER PRIMARY KEY,
    volume_id INTEGER NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL,
    added_at REAL NOT NULL,
    last_scan_completed_at REAL,
    UNIQUE (volume_id, relative_path)
);

CREATE TABLE "sessions" (
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

CREATE TABLE stack_members (
    stack_id INTEGER NOT NULL REFERENCES stacks(id) ON DELETE CASCADE,
    asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (stack_id, asset_id)
) WITHOUT ROWID;

CREATE TABLE stacks (
    id INTEGER PRIMARY KEY,
    kind INTEGER NOT NULL,
    cover_asset_id INTEGER REFERENCES assets(id) ON DELETE SET NULL,
    created_at REAL NOT NULL
);

CREATE TABLE tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE
);

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

CREATE TABLE volumes (
    id INTEGER PRIMARY KEY,
    uuid TEXT NOT NULL,
    name TEXT NOT NULL,
    capacity INTEGER,
    filesystem TEXT,
    first_seen_at REAL NOT NULL,
    last_seen_at REAL NOT NULL
);

CREATE INDEX album_assets_asset ON album_assets(asset_id);

CREATE INDEX albums_name ON albums(name COLLATE NOCASE);

CREATE INDEX asset_tags_tag ON asset_tags(tag_id);

CREATE INDEX assets_capture_date ON assets(capture_date_ms);

CREATE UNIQUE INDEX assets_content_hash ON assets(content_hash) WHERE content_hash IS NOT NULL;

CREATE INDEX assets_favorites ON assets(id) WHERE is_favorite = 1;

CREATE INDEX assets_thumbnail_pending ON assets(id) WHERE thumbnail_state < 2 AND kind = 1;

CREATE INDEX file_instances_asset ON file_instances(asset_id);

CREATE INDEX file_instances_pending ON file_instances(volume_id, id) WHERE index_state = 0;

CREATE UNIQUE INDEX sessions_album ON sessions(album_id) WHERE album_id IS NOT NULL;

CREATE INDEX sessions_anchor ON sessions(anchor_asset_id);

CREATE INDEX sessions_current ON sessions(current_asset_id);

CREATE UNIQUE INDEX sessions_folder ON sessions(volume_id, relative_path) WHERE volume_id IS NOT NULL;

CREATE UNIQUE INDEX sessions_library ON sessions(library_source) WHERE library_source IS NOT NULL;

CREATE UNIQUE INDEX sessions_tag ON sessions(tag_id) WHERE tag_id IS NOT NULL;

CREATE INDEX stack_members_asset ON stack_members(asset_id);

CREATE INDEX stacks_cover ON stacks(cover_asset_id);

CREATE INDEX thumbnails_pack ON thumbnails(pack_id);

CREATE INDEX volumes_uuid ON volumes(uuid);
