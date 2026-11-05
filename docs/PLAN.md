# Photon implementation plan

Photon is a native macOS browser for photos and videos stored in local folders and on removable media. This document records the product scope, architecture, milestones and open risks.

**Status:** planning. No application code exists yet. Milestone 0 is next.

## Product scope

### Priorities

1. Browse a folder recursively, including the contents of its subfolders.
2. View a photo in full without losing your place in the list.
3. Copy with Cmd-C or the context menu, in tile, list and full view.
4. Switch between list and tile views, with fluid tile sizing.
5. Organize with favorites, albums and tags.
6. Sort by date, name, size, type and duration.
7. Keep favorites and sessions across removable media disconnects.
8. Play a wide range of video formats and codecs.
9. Stay smooth on large libraries, including on a slow hard drive.
10. Navigate well from the keyboard when browsing, viewing, selecting and copying.

### Target hardware and media

- **Primary library:** a 2 TB external hard drive.
- **Also common:** 128–256 GB SD cards.
- **Development machine:** Apple silicon, M4 Max.
- **Minimum OS:** macOS 26, for the Liquid Glass system appearance.

Network storage is not a target for the first release. Remote changes may not produce file events, so it would need its own rescan strategy.

### Out of scope for the first release

- Permanent deletion and destructive rotation. Both may come later, so the design must keep them possible.
- Larger offline previews or offline originals of favorites.
- Anything that writes Photon's own files to the user's drives.

Cloud backup, duplicate detection and face recognition are future features (see [Milestones](#milestones)).

## Decisions

| Area | Decision | Why |
|---|---|---|
| UI stack | Swift 6. SwiftUI for the shell, AppKit for grid, list and viewer | The system look comes from SwiftUI. Large grids need AppKit-level control |
| Grid | Start with `NSCollectionView` and a custom layout. Fall back to a recycled `CALayer` grid | Decided by Spike 1 |
| Database | SQLite through GRDB, in WAL mode, with a single writer | Needs control over queries, indexes and migrations |
| Asset identity | Content hash, not path | Favorites survive renames, moves, remounts and drive changes |
| Library location | Internal disk, in Application Support | Disconnected drives stay browsable, and nothing is written to them |
| Drive writes | None of Photon's own files. Only user-initiated rename and Move to Trash | User preference |
| Originals | Read-only. Rotation is non-destructive and stored in the database | User preference. Also keeps content hashes stable |
| Offline favorites | Standard thumbnails only | Can be extended later without a schema redesign |
| Video | AVFoundation first, with a libmpv fallback, behind one interface | Best native playback, plus wide format coverage |
| Distribution | No sandbox, no App Store. Self-signed DMGs built by GitHub Actions | Personal and portfolio project, no paid program needed |

## Architecture

### Data model

Organization data attaches to content, and files are only locations of that content.

| Table | Purpose |
|---|---|
| `volumes` | Photon's volume ID, volume UUID, name, capacity, last seen time |
| `assets` | One piece of content: content hash, kind, dimensions, capture date, duration, dominant color, favorite flag, non-destructive rotation |
| `file_instances` | One copy on disk: `asset_id`, `volume_id`, relative path, size, modified time |
| `stacks`, `stack_members` | Grouped assets: RAW+JPEG pairs, Live Photos, later similar scenes |
| `albums`, `album_assets` | Manual albums. Smart albums are saved queries |
| `tags`, `asset_tags` | Tags |
| `sessions` | Per-location view state: sort, zoom, view mode, anchor asset |

Exact duplicates are several `file_instances` pointing at one asset, so they need no separate mechanism.

### Asset identity

- The content hash is SHA-256 (CryptoKit) over the file size and sampled head, middle and tail chunks.
- New files get a provisional asset with no hash, so they can be shown before hashing finishes.
- When a hash matches an existing asset, the provisional row merges into it in one transaction, keeping organization data.
- Favoriting or tagging an unhashed file hashes it immediately.
- If a file changes on disk at the same path with the same capture date and dimensions, it stays the same asset and takes the new hash. Width and height may be swapped, to allow for rotation.
- When Photon itself modifies a file in a future release, it updates the hash directly.
- A sampled hash is good enough for identity but is not proof that two files are identical. Any destructive action must first compare the full contents.

### Volumes and removable media

On mount:

1. Read the volume UUID and look for a matching `volumes` row.
2. Check a sample of indexed files by relative path, size and modified time. This catches cloned cards with the same UUID.
3. If the sample matches, bring the volume online and restore its sessions.
4. If it doesn't, treat it as a new volume. Assets reattach as files are hashed.
5. Rescan incrementally, skipping files whose path, size and modified time are unchanged.

Rules that follow from this:

- Paths are stored relative to the volume root, because mount paths change (`/Volumes/Foo 1`).
- Bookmarks and file IDs are not used for identity. Bookmarks have been reported to break on exFAT, and exFAT file ID persistence is unverified.
- On `willUnmount`, cancel all work and close every file handle so that ejecting succeeds.
- Reads on removable media must not be memory-mapped, because pulling the drive during a mapped read can crash the process. Load bytes with ordinary reads and hand them to `CGImageSource`.
- Read-only volumes are normal: locked SD cards and NTFS drives. Rename and Move to Trash are disabled there.
- A sleeping hard drive can take seconds to spin up, so the UI needs a calm waiting state.

### Indexing

Indexing runs in stages, and each stage is resumable:

1. **Enumerate:** `getattrlistbulk` streams paths, sizes and dates. Tiles appear immediately.
2. **Metadata:** capture date, dimensions, orientation, duration.
3. **Thumbnails:** embedded previews first where available.
4. **Hashing:** sampled content hash.
5. **Pairing:** RAW+JPEG and Live Photo stacks.

Each volume has its own I/O scheduler, with these priorities:

1. Visible tiles
2. Tiles ahead of the scroll direction
3. User-requested hashes
4. Background metadata
5. Background thumbnails and hashing

Hard drives get a concurrency of 1–2, and background reads run in directory order to reduce seeking. Faster media gets higher concurrency.

A hard drive manages around 100 random reads per second, so first-time indexing could take 1–2 hours per 100k photos. This is an estimate to replace with measurements from Spike 4. The app must stay fully usable throughout.

### Thumbnails and memory

- Two stored sizes, set during Milestone 2, in pack files on the internal disk with offsets in the database.
- Every tile shows the nearest available size at once, then upgrades.
- Decoding happens off the main thread. The main thread only assigns decoded images.
- During fast scrolling, tiles show the stored dominant color and skip decoding.
- The rough cost is 2–5 GB per 100k photos, so a large drive could use 25 GB or more.
- The cache has a size limit. Small thumbnails are kept for every asset, and large ones are evicted first, with favorites last.

### Grid and list

- Grid and list share one data source and selection model.
- A query result is a compact array of row IDs, and rows load in pages as they're needed.
- Tile size is continuous, through a slider, pinch and Cmd-plus or Cmd-minus. The tile under the cursor stays anchored.
- Layouts are square and aspect-ratio.
- If capture dates arrive during a sort, the list re-sorts around the anchor so that the view doesn't jump.

### Viewer

- The viewer is an overlay in the same window. The grid is never torn down.
- A zoom transition runs from the tile to full view and back. If you arrowed to another photo, the grid moves to it on exit.
- Images load progressively: thumbnail, preview, full resolution.
- Neighboring photos are preloaded.
- HDR content uses extended dynamic range.

### Copy and drag

One shared command serves grid, list and viewer. The pasteboard carries file URLs and lazily generated image data, so paste works in Finder and in apps like Messages and Figma. Large selections stay instant. Videos carry file URLs only.

### Keyboard navigation

Keyboard navigation is built alongside the grid, list and viewer, not added during polish. It covers everyday browsing, and other tasks may need the mouse.

**Behavior:**

- Grid, list and viewer share one current item, held as an asset rather than an index, so it survives re-sorts and view changes.
- Closing the viewer selects the photo you ended on.
- Left and Right follow reading order and wrap across rows. Up and Down keep the column, and in aspect-ratio layouts they pick the tile closest horizontally.
- The current item always stays on screen, with a system-style focus indicator.
- Holding an arrow key must feel smooth. Repeats are coalesced, skipped items cancel their decoding, and tiles show the nearest thumbnail at once.
- Offline items can be navigated like any other, and show their thumbnail in the viewer.
- Tab and Shift-Tab move focus between the sidebar, content and inspector.
- Common actions appear in the menu bar with their shortcuts, so that they're discoverable.
- Shortcuts are tested on non-US keyboard layouts.

**Starting shortcuts**, to be checked against Photos and Finder during Milestone 2:

| Context | Key | Action |
|---|---|---|
| Grid and list | Arrow keys | Move the current item |
| Grid and list | Shift-arrow keys | Extend the selection |
| Grid and list | Home, End | Go to the first or last item |
| Grid and list | Page Up, Page Down | Move by one screen |
| Grid and list | Cmd-A, Cmd-Shift-A | Select all, select none |
| Grid and list | Space, Return, Cmd-Down | Open in the viewer |
| Grid and list | Cmd-Up | Go to the parent folder |
| Grid and list | Type a name | Jump to a matching filename, in list view |
| Grid | Cmd-Equals, Cmd-Minus | Change tile size |
| Everywhere | Cmd-1, Cmd-2 | Tile view, list view |
| Everywhere | Cmd-C | Copy |
| Everywhere | Period | Toggle favorite |
| Everywhere | Cmd-I | Show or hide the inspector |
| Everywhere | Cmd-F | Search |
| Everywhere | Cmd-R, Cmd-Option-R | Rotate right, rotate left (non-destructive) |
| Everywhere | Cmd-Shift-R | Rename |
| Everywhere | Cmd-Delete | Move to Trash |
| Everywhere | Ctrl-Cmd-S | Show or hide the sidebar |
| Everywhere | Ctrl-Cmd-F | Enter or leave full screen |
| Viewer | Left, Right | Previous or next item, or pan when zoomed in |
| Viewer | Up, Down | Pan when zoomed in |
| Viewer | Escape | Close the viewer |
| Viewer | Cmd-Equals, Cmd-Minus, Cmd-0 | Zoom in, zoom out, fit to window |
| Video | Space | Play or pause |
| Video | J, K, L | Reverse, pause, play forward |
| Video | Shift-Left, Shift-Right | Seek 5 seconds |
| Video | Option-Left, Option-Right | Step one frame |
| Video | M | Mute |

Space closes a photo in the viewer, so it works as a quick look toggle. For videos it plays and pauses, and Escape closes.

### Video

`VideoEngine` hides two implementations:

- **AVFoundation:** MOV and MP4 with H.264, HEVC, ProRes, and AV1 on Macs with a hardware decoder (M3 and later).
- **libmpv fallback:** MKV, WebM, AVI, WMV and similar. Thumbnails for these formats use FFmpeg's libraries, so both share one dependency stack.

VLCKit is the backup if libmpv embedding fails. Apple's MediaExtension framework stays an option, but each user would have to enable the extension in System Settings. Use LGPL builds of FFmpeg and mpv unless the project adopts a GPL-compatible license.

### Repository layout (planned)

```text
App/                 Thin macOS app target
Packages/PhotonKit/
  PhotonCore         Schema, models, database, migrations
  PhotonIndex        Scanning, hashing, volumes, I/O scheduling
  PhotonMedia        Decoding, thumbnails, pasteboard
  PhotonVideo        VideoEngine and its implementations
  PhotonUI           Grid, list, viewer, sidebar
docs/                Project documentation
```

## Performance budgets

These are starting targets for an M4 Max, to be tuned in Milestone 0.

| Measure | Target |
|---|---|
| Launch to usable window with last session | Under 300 ms |
| Open an indexed 100k folder | Under 200 ms |
| Scrolling and zooming | Steady 120 fps |
| Holding an arrow key in grid, list or viewer | Keeps up with key repeat, with no dropped frames |
| App memory in normal use | Under 1.5 GB |

Budgets are tracked with `os_signpost` and automated performance tests on a synthetic library, starting in Milestone 1.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | **Spikes** (below) | Grid approach and video engine chosen on measured results |
| 1 | **Foundation:** packages, CI, schema, scanner, metadata | A real drive indexes in the background, and rescans touch only changed files |
| 2 | **Grid:** thumbnails, fluid tile size, list view, sorting, selection, keyboard navigation | Budgets met on a 100k library, on the hard drive, and arrow-key navigation and selection work in grid and list |
| 3 | **Viewer:** progressive loading, zoom, HDR, transitions, copy and drag, keyboard control | Your place is always kept, copy works in every mode, and the viewer can be navigated from the keyboard |
| 4 | **Removable media:** mount handling, offline mode, session restore, eject | Passes the drive-pull and reconnect tests |
| 5 | **Organization:** favorites, albums, tags, smart albums, search, stacks | Favorites survive moving a library to a new drive |
| 6 | **Video:** AVPlayer, fallback engine, thumbnails, scrub previews | A format test set plays and shows thumbnails |
| 7 | **Polish and release:** accessibility, Settings, onboarding, signed DMG workflow, screenshots | Ready for daily use, with a tagged release on GitHub |
| 8 | **Duplicates:** near-duplicate detection, similar-scene stacks | Similar scenes collapse into one browsable tile |
| 9 | **Cloud backup:** JSON export keyed by hash, then encrypted backup of originals | Favorites can be restored after losing a drive |
| 10 | **Faces:** detection, bundled embedding model, clustering, correction UI | People can be browsed and corrected |

The schema work in Milestone 1 includes the identity model and stacks, even though their features arrive later.

### Milestone 0 spikes

1. **Grid zoom and navigation:** 200k synthetic items, continuous zoom, anchored scrolling and held arrow keys, measured in Instruments. A `CALayer` grid would need keyboard handling and accessibility built by hand, so count that cost when choosing.
2. **libmpv embedding:** a working video surface in an AppKit view. mpv's Vulkan path on macOS was marked experimental in 2023, and MPVKit reports Metal support as unofficial.
3. **Volume identity:** UUID stability, file ID behavior and surprise removal on the real hard drive and SD cards.
4. **Hard drive throughput:** real timing for enumeration, hashing and thumbnails.
5. **Signing:** confirm that a self-signed certificate keeps removable-volume permission across rebuilds.

## Distribution

Releases are DMGs built by GitHub Actions on a version tag.

1. Create a self-signed code-signing certificate with a long expiry, and keep using the same one.
2. Store it as a base64-encoded GitHub secret.
3. The workflow builds, signs, creates the DMG and attaches it to a GitHub Release.

Ad-hoc signing isn't used, because permissions can be lost on each rebuild. Downloaded builds aren't notarized, so people have to approve them under System Settings → Privacy & Security → Open Anyway.

Developer ID and notarization can be added later ($99/year). That also needs the hardened runtime, with bundled libraries signed to match.

## Future feature notes

### Duplicates and similar scenes

- Exact matches come from content identity.
- Similar scenes combine Vision's `GenerateImageFeaturePrintRequest` with capture time.
- Vision's aesthetics and face quality scores can choose the cover photo.
- Results use the existing `stacks` tables.

### Cloud backup

Content hashes make this straightforward. Start with a JSON export of favorites, albums and tags, then back up originals to a chosen folder or S3-compatible storage, with client-side encryption.

### Face recognition

The SDK's Vision framework offers face detection, landmarks and capture quality, but no public face embedding API was found, so a model has to be bundled. Results should be close to Apple's on clear, front-facing adult faces. Expect them to be weaker on turned-away or hidden faces, where Apple also uses upper-body matching, and on small faces and children growing up. A good correction UI closes much of that gap.

Check model licenses before distributing. InsightFace's pretrained models are non-commercial research only. AdaFace weights are reported as MIT, but their training data may have stricter terms.

## Risks

| Risk | Mitigation |
|---|---|
| `NSCollectionView` can't zoom smoothly | Spike 1, with a `CALayer` grid as fallback |
| libmpv embedding is unstable | Spike 2, with VLCKit as backup |
| Volume UUIDs change or collide without a marker file | File sampling on mount, and hash-based reattachment |
| First-time indexing is slow on the hard drive | Priority scheduling, resumable stages, visible tiles first |
| Thumbnail cache grows too large | Size limit, with two-tier eviction |
| Drive removed during a read | No mapped reads, cancellation, physical drive-pull tests |
