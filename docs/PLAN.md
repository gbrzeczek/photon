# Photon implementation plan

Photon is a native macOS browser for photos and videos stored in local folders and on removable media. This document records the product scope, architecture, milestones and open risks.

**Status:** Milestone 2 is built and measured on a real screen, on a seeded 100k library on the internal disk and on the T7 Touch's real library of 27,235 photos. The drive doesn't hold 100k files, so those two together stand in for a 100k library on the drive. See [Milestone 2 results](#milestone-2-results). Spike code lives in [`Spikes/`](../Spikes/README.md), and results are under [Milestone 0 spikes](#milestone-0-spikes) and [Milestone 1 results](#milestone-1-results).

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
9. Stay smooth on large libraries, including on an external drive.
10. Navigate well from the keyboard when browsing, viewing, selecting and copying.

### Target hardware and media

- **Primary library:** a 2 TB external USB SSD (Samsung T7 Touch, exFAT).
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
| Grid | Recycled `CALayer` grid in a viewport-fixed host view, inside `NSScrollView` | Spike 1: it held 120 fps through continuous zoom, and `NSCollectionView` fell to 32–94 fps even with no decoding |
| Database | SQLite through GRDB, in WAL mode, with a single writer | Needs control over queries, indexes and migrations |
| Asset identity | Content hash, not path | Favorites survive renames, moves, remounts and drive changes |
| Library location | Internal disk, in Application Support | Disconnected drives stay browsable, and nothing is written to them |
| Drive writes | None of Photon's own files. Only user-initiated rename and Move to Trash | User preference |
| Originals | Read-only. Rotation is non-destructive and stored in the database | User preference. Also keeps content hashes stable |
| Offline favorites | Standard thumbnails only | Can be extended later without a schema redesign |
| Thumbnail sizes | 320 and 800 px on the long edge, JPEG at quality 0.75 | Tiles run from 64 to 400 pt. At 2x, 320 px covers the default 160 pt tile and 800 px covers the largest |
| Browse rows | One row per asset. Exact duplicates show as one tile, the first in path order | The current item and selection are assets, so two rows for one asset would be ambiguous |
| Sorting | Rows are sorted in process on integers or byte keys, not by `ORDER BY` | A natural name sort with `localizedStandardCompare` costs seconds at 100k rows. The byte keys are close to Finder's order for camera names, but aren't identical |
| Video | AVFoundation first, with a libmpv fallback, behind one interface. libmpv draws through its render API into a `CAOpenGLLayer`, from our own LGPL build | Spike 2: every test format played with no dropped frames on both embedding paths, and this one needs no patched mpv |
| Distribution | No sandbox, no App Store. Self-signed DMGs built by GitHub Actions | Personal and portfolio project, no paid program needed |

## Architecture

### Data model

Organization data attaches to content, and files are only locations of that content.

| Table | Purpose |
|---|---|
| `volumes` | Photon's volume ID, volume UUID, name, capacity, last seen time |
| `library_roots` | Folders chosen for indexing: volume ID, relative path, last completed scan |
| `assets` | One piece of content: content hash, kind, dimensions, capture date, duration, dominant color, favorite flag, non-destructive rotation |
| `file_instances` | One copy on disk: `asset_id`, `volume_id`, relative path, size, modified time |
| `stacks`, `stack_members` | Grouped assets: RAW+JPEG pairs, Live Photos, later similar scenes |
| `albums`, `album_assets` | Manual albums. Smart albums are saved queries |
| `tags`, `asset_tags` | Tags |
| `sessions` | Per-location view state: sort, zoom, view mode, anchor asset |
| `thumbnail_packs`, `thumbnails` | Pack files on the internal disk, and each asset's offsets in them, by size |

Exact duplicates are several `file_instances` pointing at one asset, so they need no separate mechanism.

### Asset identity

- The content hash is SHA-256 (CryptoKit) over the file size and sampled head, middle and tail chunks.
- New files get a provisional asset with no hash, so they can be shown before hashing finishes.
- When a hash matches an existing asset, the provisional row merges into it in one transaction, keeping organization data.
- Favoriting or tagging an unhashed file hashes it immediately.
- If a file changes on disk at the same path with the same capture date and dimensions, it stays the same asset and takes the new hash. Width and height may be swapped, to allow for rotation. A missing date or dimension never counts as a match, because attaching a favorite to the wrong picture is worse than leaving it on the old content.
- If other copies of the asset still hold the old content, the edited file gets a new asset with a copy of the organization data, and the old asset keeps its hash.
- An asset with no files survives if it has any organization data, so that it can reattach by hash. Otherwise it's deleted with its last file.
- When Photon itself modifies a file in a future release, it updates the hash directly.
- A sampled hash is good enough for identity but is not proof that two files are identical. Any destructive action must first compare the full contents.

### Volumes and removable media

On mount:

1. Read the volume UUID from DiskArbitration and look for a matching `volumes` row.
2. Check a sample of 64 indexed files by relative path, size and modified time. This catches a drive that was reused, or a clone that has since diverged.
3. If at least half the sample matches, bring the volume online and restore its sessions. It's a majority rather than every file, because files on a drive do change between sessions.
4. If it doesn't, treat it as a new volume. Assets reattach as files are hashed.
5. Rescan incrementally, skipping files whose path, size and modified time are unchanged.

Rules that follow from this:

- Paths are stored relative to the volume root, because mount paths change (`/Volumes/Foo 1`).
- Bookmarks and file IDs are not used for identity. Bookmarks have been reported to break on exFAT. exFAT and FAT32 file IDs survive remounts, renames and moves on disk images, but they are reused for unrelated files after a delete, and exFAT IDs behaved like start clusters.
- A byte-for-byte clone is indistinguishable from its original: same UUID, file IDs, sizes and dates. It's harmless when mounted alone, because it is the same content. When two volumes with one UUID are mounted together, Photon must keep them apart by BSD name for the session, and must not bring a second copy online as the same `volumes` row. For now the second one simply isn't indexed for that session. Milestone 4 decides what the UI shows.
- Don't use `isRemovable` or `isEjectable` to recognize external media. The T7 Touch reports both as false, and it reports no persistent ID support.
- Don't use `URLResourceKey.volumeUUIDStringKey` for identity. On FAT32 it returned a different UUID for a second mount of a clone, while DiskArbitration stayed stable.
- On `willUnmount`, cancel all work and close every file handle so that ejecting succeeds. An open handle does block the unmount. `willUnmount` also fires before an unmount that then fails, so if no `didUnmount` follows, the volume is still mounted and work must resume. Photon waits 5 seconds to find out.
- A gone mount makes every path look deleted. Any error, or empty listing, is checked against the mount before it's believed, so a failing drive never looks like an empty one. A scan only forgets a folder when the volume is still mounted and the scan confirmed it's gone. Folders that couldn't be listed keep their files.
- Reads on removable media must not be memory-mapped, because pulling the drive during a mapped read crashes the process (SIGBUS confirmed on a disk image). Ordinary reads return `EIO` immediately. Load bytes with ordinary reads and hand them to `CGImageSource`.
- Read-only volumes are normal: NTFS drives, and volumes mounted read-only. Rename and Move to Trash are disabled there.
- A sleeping drive can take a moment to wake, so the UI needs a calm waiting state.

### Indexing

Indexing runs in stages, and each stage is resumable:

1. **Enumerate:** `getattrlistbulk` streams paths, sizes and dates. Tiles appear immediately.
2. **Metadata:** capture date, dimensions, orientation, duration.
3. **Thumbnails:** embedded previews first where available.
4. **Hashing:** sampled content hash.
5. **Pairing:** RAW+JPEG and Live Photo stacks.

Enumeration writes rows only for what differs, one directory at a time, so an unchanged rescan writes nothing and opens no files. Everything left to do is stored as pending rows, so a run can stop at any point and the next one carries on. Milestone 1 covers stages 1, 2 and 4, and Milestone 2 stage 3. Pairing arrives with the stacks feature in Milestone 5.

Thumbnails run after hashing rather than in the same read, in two passes: embedded previews for every photo, then full reads. A tile on screen doesn't wait: it runs both for its own asset at visible priority. Waiting for the hash means an exact duplicate is never decoded twice.

Metadata and hashing share one job per file, and one read: the first 256 KB gives both the metadata and the hash's head chunk. They'll need separating only if a hash has to jump ahead of metadata for a favorited file.

Each volume has its own I/O scheduler, with these priorities:

1. Visible tiles
2. Tiles ahead of the scroll direction
3. User-requested hashes
4. Background metadata
5. Background thumbnails and hashing

The primary drive is an SSD, so each volume starts at a concurrency of 4. Throughput stopped growing there on metadata, and read order made little difference (about 5%). Background reads don't need special ordering.

First-time indexing takes about 30 minutes per 100k photos at full speed, and about an hour at a single job, which suits background work. These figures come from [Spike 4](#spike-4-external-drive-throughput) on the T7 Touch, scaled from a sample of files averaging 3.9 MB. The app must stay fully usable throughout.

- A full read is the expensive step, so a photo should need only one. For now only HEIC, which already gets a full read for metadata, reads twice. The other formats read 256 KB for metadata and the hash, then the whole file once for thumbnails.
- Enumeration is not the bottleneck, at about 1 second per 100k files from cold.
- Embedded previews are mostly 160 px, too small for standard thumbnails. They are 12 times faster, so they fill tiles first, and a full decode then replaces them.
- HEIC metadata can't be read from a partial file through ImageIO, so HEIC and AVIF files get a full read for now. A parser of our own could avoid that later.
- Other photos try a 256 KB prefix, then 4 MB, then the whole file up to 512 MB, for formats such as some RAW files that keep metadata later on.
- Video metadata comes from a small parser of QuickTime and MP4 boxes, which reads only box headers and the `moov` box, through the scheduler. AVFoundation isn't used here because it opens files itself. MKV, WebM, AVI and other containers have no metadata until FFmpeg's libraries arrive in Milestone 6.
- Video thumbnails haven't been measured.

### Thumbnails and memory

- Two stored sizes, 320 and 800 px, in append-only pack files on the internal disk with offsets in the database. Bytes are written before their rows, so a crash can only leave unused bytes.
- An embedded preview is a temporary third tier. It's deleted once the full read has made the stored sizes, so previews don't double the cache.
- Every tile shows the nearest available size at once, then upgrades.
- Decoding happens off the main thread. The main thread only assigns decoded images.
- Decoded thumbnails are IOSurfaces assigned to `CALayer.contents`. Assigning a `CGImage` cost the main thread up to about 0.7 ms per thumbnail during commit, and tagging it sRGB didn't help. IOSurfaces cut main-thread p95 during scrolling from 5.7 ms to 1.5 ms.
- The main thread takes a bounded batch of decoded thumbnails per frame, so that a backlog can't flood it.
- During fast scrolling, tiles show the stored dominant color and skip decoding.
- The rough cost is 2–5 GB per 100k photos, so a large drive could use 25 GB or more.
- The cache has a size limit, 20 GB for now. Small thumbnails are kept for every asset, and large packs are evicted whole, least recently used first, with favorites last. Replaced thumbnails leave unused bytes in their pack until it goes, since nothing compacts packs yet.
- **Video tiles until Milestone 6** show a film symbol and the duration, read from the database. They never read the file: AVFoundation would open it itself, which bypasses the I/O scheduler.
- **Offline**, stored thumbnails show as usual. Anything missing keeps its dominant color, or a neutral fill, and nothing fails.

### Grid and list

- Grid and list share one data source and selection model.
- A query result is a compact array of row IDs, and rows load in pages as they're needed.
- Square tiles always fill the width at rest, as in Photos on iOS, with no side margins. The size chosen only sets the column count, and the tile is whatever fits that many columns. A pinch follows the fingers exactly, with margins while it lasts, and eases to fill the width when it ends. The slider and Cmd-plus or Cmd-minus ease from one column count to the next, and a shortcut always changes the count unless the size limit stops it. Window resizing stays filled throughout. Reduce Motion turns the easing off. Aspect-ratio rows already fill the width, and their size stays continuous.
- The tile under the cursor stays anchored vertically, to within half a device pixel, because the clip view snaps to pixels.
- **Sideways jumps:** when the column count changes, rows break so that the anchor stays in its column, which adds blank cells before the first item (`phase`). Each tile then slides from its old position with an additive animation, so the frames of a continuing pinch carry on underneath. Reduce Motion turns the slide off. The blank cells clear, with the same slide, once the top of the library is on screen.
- Layouts are square and aspect-ratio. During a zoom, aspect-ratio rows are built outward from the anchor, only as far as they're looked at, and heights come from an estimate. The full pass runs off the main thread afterward and breaks rows at the same place, so nothing visibly moves when it lands.
- Tile layers use coordinates relative to a coarsely moving base, and never document coordinates, which reach tens of millions of points.
- Accessibility, hit testing, selection, drag source, context menus and focus rings are hand-built, since `CALayer` provides none of them.
- If capture dates arrive during a sort, the list re-sorts around the anchor so that the view doesn't jump. While indexing, the query runs at most every 2 seconds, and everything proportional to the library happens off the main thread: the query, the layout pass, and the map from old rows to new ones.
- Selection is ranges of rows, so selecting 100k items costs one range. The map above carries it across a change of order.
- **Rubber band.** Tiles nearly fill the view, so a band can start on any tile that isn't selected, and on the gaps. A selected tile is kept for dragging files out in Milestone 3, so a plain click on one narrows the selection only when the button comes up. Command or Shift keeps what was already selected. Holding the pointer past the top or bottom scrolls, faster the further past. Tiles on screen check the rectangle directly, and the rows are worked out once, off the main thread, when the button comes up, so a band over the whole library costs only what's visible on each frame. The status bar's count catches up then too.
- **The list stays alive but idle while hidden.** A hidden `NSTableView` still lays out rows and makes cells, and that cost the grid hitches of up to 46 ms. It takes the result and the selection when it next shows.

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

**Shortcuts.** Rows marked later have no effect yet: the viewer and copy are Milestone 3, favorites, search and the inspector are Milestone 5, and rename and trash need the file operations layer. The checks against Photos and Finder, and on non-US layouts, haven't been done.

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

libmpv uses `vo=libmpv` and the OpenGL render API, drawn into a `CAOpenGLLayer` tagged sRGB. OpenGL is deprecated, so the Vulkan path through MoltenVK stays as the exit. It needs a patched mpv to handle window resizes, which our own build would make possible.

Apple's MediaExtension framework stays an option, but each user would have to enable the extension in System Settings. Use LGPL builds of FFmpeg and mpv unless the project adopts a GPL-compatible license.

Photon needs its own build of mpv and FFmpeg, shipped as signed dylibs or frameworks. MPVKit was fine for the spike, but it can't ship: its static linking doesn't obviously meet the LGPL, it leaves out decoders the fallback exists for (such as DivX 3, DV, DNxHD and Theora), and its README says not to rely on it.

`VideoEngine` must also:

- Report a file as failed when `video-codec` is empty. With a missing decoder and an audio track, mpv plays audio only and raises no error.
- Set `ao=avfoundation`, because CoreAudio output failed on planar audio.
- Keep every mpv call off the main thread, and never wait on a draw, because Core Animation stops drawing while the display sleeps.
- Release the GL context in the layer's `deinit`, after `mpv_render_context_free` and `mpv_terminate_destroy`. Core Animation can still display the layer after mpv is gone.
- Decide how mpv's reads fit the disk rules. mpv opens files itself, which bypasses the per-volume I/O scheduler and its cancellation. `stream_cb.h` may solve this, and it's untested.

### Repository layout

```text
App/                 Thin macOS app target
Photon.xcodeproj/    App project, which uses PhotonKit as a local package
Spikes/              Milestone 0 measurement code, not part of the app
Packages/PhotonKit/
  PhotonCore         Schema, models, database, migrations
  PhotonIndex        Scanning, hashing, volumes, I/O scheduling
  PhotonMedia        Metadata, decoding, thumbnails, pasteboard
  PhotonVideo        VideoEngine and its implementations
  PhotonUI           Grid, list, viewer, sidebar
  PhotonTestSupport  Synthetic media and disk images, for tests and tools only
  photon-index       Development tool for measuring indexing
docs/                Project documentation
```

## Performance budgets

These are targets for an M4 Max. The figures below are from a release build on a seeded library of 100k items on the internal disk, at 120 Hz, with the window filling the display. Spike 1's own figures, from its 200k library, are under [Spike 1](#spike-1-grid-zoom-and-navigation).

| Measure | Target | Measured |
|---|---|---|
| Launch to usable window with last session | About 350 ms | 320–345 ms to the result, 355–425 ms to the frame after it. The earlier target of 300 ms was arbitrary, so it was relaxed rather than replacing the SwiftUI shell |
| Open an indexed 100k folder | Under 200 ms | 60–85 ms |
| Scrolling and zooming | Steady 120 fps | 117.9–120 fps in the grid, which is at most 2 missed frames in a scenario. Instruments found 8–22 single-frame hitches in about 36 seconds in the larger window |
| Main thread time per frame | Under 8 ms, so that a frame is never at risk | Worst p99 3.6 ms. Worst single frame 4.7 ms in the grid and 12.1 ms in the list |
| Render server time per frame | Under 8 ms | p99 3.6–5.9 ms, worst 14.8 ms. 9 of 7,418 and 11 of 5,049 frames over budget |
| Holding an arrow key in grid, list or viewer | Keeps up with key repeat, with no dropped frames | Grid and list keep up at 30 and 240 key events per second, and with Shift at 30. Viewer not yet |
| App memory in normal use | Under 1.5 GB | About 460–600 MB after all the scenarios |

The spike's in-app timers reported no missed frames in the same scenarios where Instruments found these hitches. Don't rely on the in-app numbers alone.

Budgets are tracked with `os_signpost` and automated performance tests on a synthetic library, starting in Milestone 1.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | **Spikes** (below) | Grid approach and video engine chosen on measured results |
| 1 | **Foundation:** packages, CI, schema, scanner, metadata | A real drive indexes in the background, and rescans touch only changed files |
| 2 | **Grid:** thumbnails, fluid tile size, list view, sorting, selection, keyboard navigation | Budgets met on a 100k library, on the external drive, and arrow-key navigation and selection work in grid and list |
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

| # | Spike | State |
|---|---|---|
| 1 | Grid zoom and navigation | Decided: `CALayer` grid. Real trackpad and VoiceOver checks remain |
| 2 | libmpv embedding | Decided: render API in a `CAOpenGLLayer`. On-screen pacing and our own build remain |
| 3 | Volume identity | Done on the T7 Touch and disk images, except a physical pull |
| 4 | External drive throughput | Done on the T7 Touch, except video thumbnails |
| 5 | Signing | Done: the grant persisted across rebuilds on the T7 Touch |

Scripts and raw results are in [`Spikes/`](../Spikes/README.md). They ran on macOS 27.0.1 on an M4 Max.

#### Spike 1: Grid zoom and navigation

Two backends shared one layout engine, one off-main thumbnail pipeline and the same scripted scenarios. Each scenario in this table ran twice on the 200k library, in a 1500×950 pt window with a 120 Hz display, on battery power. Tiles ranged from 64 to 400 pt.

| Scenario | `NSCollectionView` | `CALayer` grid |
|---|---|---|
| Zoom, 64–400 pt | 83–92 fps, up to 93 missed frames | 120 fps, none missed |
| Zoom, 64–128 pt | 27–33 fps, up to 159 missed frames | 120 fps, none missed |
| Zoom main thread p99 | 47–118 ms | 3.5–5.5 ms |
| Scroll, 4,000 pt/s main thread p95 | 4.0 ms | 1.4 ms |
| Fast scroll, 120,000 pt/s | 120 fps, p95 4.7 ms | 120 fps, p95 1.7 ms |
| Arrow keys, 30 per second | 120 fps, p95 8.3 ms | 120 fps, p95 2.0 ms |
| Instruments, scroll and zoom | 222 hitches, 79 of them multi-frame, up to 67 ms | 21 hitches, all single-frame |

Both Instruments figures leave out one startup hitch of about 100 ms that each backend has.

- `NSCollectionView` was tested at its best: no decoding and items limited to the visible rect. It still only reached 56–94 fps, so its layout pass is the limit. It is fine for scrolling, but continuous zoom is a stated priority. Its memory use also reached 4.3 GB during zoom with thumbnails on, because it requested far more tiles than it showed.
- The `CALayer` grid's cost doesn't grow with the library. With 1M items it stayed at 120 fps, with main thread p99 at 4.4 ms in zoom.
- **The cost of the choice:** selection, hit testing, drag source, context menus, focus rings and accessibility are all hand-built. Keyboard handling is not an extra cost, because custom navigation rules were needed for either backend. A minimal list role with one element per visible tile took about 20 lines and returned in under 1 ms.
- **Not verified:** real trackpad pinch and scroll, because the spike scripts per-frame changes. VoiceOver itself, because accessibility was checked only from inside the process. External displays. Plugged-in performance. Instruments ran only the square layout.

#### Spike 2: libmpv embedding

libmpv embedding works, so VLCKit isn't needed. Full results are in `Spikes/Mpv/RESULTS.md`. Measured with mpv 0.41.0 and FFmpeg n8.1.2 from MPVKit 1.0.0's LGPL product, on nine synthetic clips of H.264, 4K HEVC 10-bit, AV1, VP9, ProRes, MPEG-2, MPEG-4, WMV2 and FLV1.

| | Path A: render API, `CAOpenGLLayer` | Path B: `wid`, `CAMetalLayer`, MoltenVK |
|---|---|---|
| All nine clips played, resized and seeked | Yes, with no drops | Yes, with no drops |
| Pixels confirmed on screen | Yes | Yes |
| Live resize | Correct | Cropped, unless mpv is patched or a transform is used |
| Depends on | mpv's public API, deprecated OpenGL | An MPVKit-only mpv patch, MoltenVK, shaderc |
| Vsync feedback | None, so display-sync isn't usable | Yes |
| Memory | About 105 MB less on average | |
| 75 load and rebuild cycles | No failures or crashes | No failures or crashes |

- Hardware decoding worked for H.264, HEVC, AV1, VP9 and ProRes. MPEG-2, MPEG-4, WMV2 and FLV1 decoded in software, as expected. AV1 and VP9 hardware decoding depend on the Mac.
- `CAOpenGLLayer` needs its colorspace set to sRGB, or colors are oversaturated on P3 displays.
- If hardened runtime is adopted, mpv's built-in Lua scripts must be turned off, or a JIT-style entitlement added, or the app is killed at launch.
- **Not verified:** on-screen frame pacing on either path, because mpv's counters only describe its own view. Also real mouse-drag resize, fullscreen, HDR, subtitles, audible output, real camera files, removable media and macOS 26. Building mpv and FFmpeg ourselves hasn't been attempted, and the LGPL position needs a proper review.

#### Spike 3: Volume identity

Run on the real T7 Touch, read-only, and on disk images. Disk images use the same FSKit exFAT driver as the drive. `hdiutil detach -force` stands in for a pulled cable, so it shows what a process sees, not the delays of a real USB failure.

| T7 Touch, 30,524 files in `Photos` and `GoPro` | Result |
|---|---|
| Volume UUID across repeated remounts | Same |
| Volume UUID across a physical reconnect, USB 2 to USB 3 link | Same |
| File ID, size and modified time across a remount | Same for all 30,524 files |
| `isRemovable`, `isEjectable`, `supportsPersistentIDs` | All false |
| Medium type | "Solid State" at USB 3, not reported at USB 2 |


| Behavior | exFAT | FAT32 | HFS+ | APFS |
|---|---|---|---|---|
| Volume UUID stable across remount | Yes | Yes | Yes | Yes |
| Reformat changes the UUID | Yes | Yes | Yes | Not tested |
| Clone has the same UUID | Yes | Yes, in DiskArbitration | Yes | Yes |
| File ID survives remount, rename, move | Yes | Yes | Yes | Yes |
| File ID changes on atomic replace | Yes | Yes | Yes | Yes |
| File ID reused by unrelated content | Yes | Yes | Not seen | Not seen |
| Read-only mount rejects writes | Yes | Yes | Yes | Not tested |

| Removal test on exFAT | Result |
|---|---|
| `read()` during force detach | `EIO` at once, no hang |
| Memory-mapped read | Process killed by SIGBUS |
| `CGImageSource` from a URL | Survived, including a 38 MB JPEG 3 times out of 3. Too small a sample to relax the rule |
| Unmount with a handle closed on `willUnmount` | Succeeded about 220 ms later |
| Unmount with a handle held open | Refused, and `willUnmount` had already fired |

**Not tested:** a physical pull of the drive, which was left out to protect the data on it, and is a Milestone 4 test on a drive holding nothing important. File IDs across a physical reconnect were not compared, only across remounts. Whether modified times shift on exFAT when the time zone changes is also untested, and that would affect the file sample in step 2.

#### Spike 4: External drive throughput

Measured on the 2 TB Samsung T7 Touch at a 5 Gb/s USB link, read-only, reading a sample of `Photos`. All reads were uncached, and most runs started from a fresh mount. The Spike 2 session may have been running at the same time.

| Device | Result |
|---|---|
| Sequential read | 359 MB/s |
| Random 4 KB read | 2,645 IOPS, median 0.37 ms, p99 0.96 ms |

| Stage | Data per file | 1 job, files/s | 4 jobs, files/s | 8 jobs, files/s | Hours per 100k at 4 jobs |
|---|---|---|---|---|---|
| Sampled hash | 191 KB | 369 | 1,180 | Not run | 0.02 |
| Metadata from a prefix | 255 KB | 465 | 1,626 | 1,654 | 0.02 |
| Embedded preview from a prefix | 505 KB | 268 | 770 | 839 | 0.04 |
| Full read and decode to 512 px | 3.9 MB | 26 | 61 | 74 | 0.46 |

| Enumeration, cold | Time |
|---|---|
| `getattrlistbulk`, `Photos` | 1.1 s per 100k files |
| `FileManager`, `Photos` | 8.0 s per 100k files |

- **Read order:** directory, file ID and random order gave 371, 375 and 354 files/s when hashing, so ordering isn't worth building for this drive.
- **Embedded previews:** median 160 px, and at least 10% are 512 px or larger. 137 of 3,000 files gave no preview from the prefix, nearly all HEIC.
- **HEIC:** all 126 metadata failures out of 3,000 were HEIC. A 4 MB prefix still failed for 48 files.
- **Not measured:** video thumbnails, which matter for `GoPro`, and any file outside `Photos`. Hashing video was not measured separately.

The tool was first validated on an exFAT disk image, and those numbers are in `Spikes/Throughput/results/image-bench.txt`.

#### Spike 5: Signing

- **Confirmed on real media:** a removable-volume grant survives rebuilds with a self-signed certificate. On the T7 Touch, the first build waited 25 seconds on the Allow prompt, and two rebuilds with different binaries then read the drive in 11–30 ms with no prompt. As a control, ad-hoc builds blocked again on each build, for 2.5 and 1.1 seconds. Prompts were inferred from that blocking time.
- **Why it works:** a self-signed certificate gives a designated requirement of bundle identifier plus certificate, which stayed identical across rebuilds. Ad-hoc signing gives a `cdhash` requirement, which changes on every build.
- **Also confirmed:** `codesign` works with an untrusted certificate when given its SHA-1 hash and keychain, so CI doesn't need to trust it. Local builds ran, even though `spctl` rejects them.
- **Testing note:** disk images aren't gated by TCC at all, so this check always needs a real drive.

### Milestone 2 results

These are from a release build on a seeded library of 100,000 items on the internal disk, on AC power, with thumbnails from shared templates and the window filling the display: a 1x external display at 1680×973 pt and the Retina built-in display at 1272×872 pt, both at 120 Hz.

| Scenario, 1x and Retina | fps | Main thread p99 | Main thread worst |
|---|---|---|---|
| Scroll, 4,000 pt/s | 119.7, 117.9 | 2.1, 1.8 ms | 2.7, 2.4 ms |
| Fast scroll, 120,000 pt/s | 120, 120 | 3.6, 2.8 ms | 4.3, 4.4 ms |
| Zoom, 64–400 pt | 120, 120 | 1.8, 1.3 ms | 2.1, 2.1 ms |
| Zoom, 64–128 pt | 120, 120 | 1.9, 1.2 ms | 3.2, 2.0 ms |
| Grid arrow keys, 30 and 240 per second | 120, 120 | 2.8, 2.1 ms | 4.7, 4.1 ms |
| Grid Shift-arrow, 30 per second | 119.3, 119.3 | 3.1, 2.2 ms | 4.2, 3.5 ms |
| Switch to the list, once | 106, 107 | 6.1, 3.1 ms | 6.1, 3.1 ms |
| List scroll, 4,000 pt/s | 119, 119.3 | 1.2, 0.9 ms | 12.1, 11.0 ms |
| List arrow keys, 30 and 240 per second | 119.3–120 | Under 0.1 ms | 1.5 ms |
| List Shift-arrow, 30 per second | 120, 120 | Under 0.1 ms | 0.2 ms |

Those main-thread figures leave out Core Animation's commit, so they go with Instruments, which sees the whole frame:

| Animation Hitches, all scenarios | Hitches after launch | Render server p50, p99, worst | Frames over 8 ms |
|---|---|---|---|
| Retina, before clipping tiles to the viewport | 1, single frame | 1.3, 3.6, 14.1 ms | 9 of 7,418 |
| 1x, final code | 8, all single frames | 1.9, 5.9, 14.8 ms | 11 of 5,049 |

Render frames over 8 ms recur about every 5 seconds, at the same points in the second, in both traces, and whatever Photon is doing. They look like something else on the system, but that isn't confirmed. The in-app timers reported up to 4 missed frames in list scrolling on traces where Instruments reported fewer, so the two still don't agree. Treat neither alone as the answer.

**Launch was accepted at about 350 ms.** Warm launches take 320–345 ms to install the result, and 355–425 ms to the frame after it. About 120 ms passes before the root view exists, and about 170 ms goes on SwiftUI building the split view and toolbar on the main thread. Photon's own main-thread work is under 40 ms, and the query now runs alongside the window rather than after it, which took about 90 ms off. Getting under 300 ms would have meant replacing the SwiftUI toolbar and split view, for a target that was arbitrary. Cold launches, after a restart, aren't measured.

What running on a real screen found, and fixed:

- A hidden `NSTableView` still lays out rows and makes cells, which cost the grid hitches of up to 46 ms. The list now catches up when it shows.
- Every launch ran the full query again 2 seconds in, because `refreshVolumes` reported a change even with none.
- Reading the status and the slider value in `BrowserShell`'s body rebuilt the toolbar on every change, including each step of a pinch.
- Tiles drew past the top of the viewport, behind the toolbar and title, because nothing clipped them. They didn't show this in `CARenderer`.
- A change made in the last second before quitting was lost, so the app could reopen in the wrong view. The session is now saved on quit.
- A plain press on one of several selected tiles collapsed the selection straight away, which would have ruled out dragging them.
- The sidebar's folder tree was quadratic in the folders, on the main thread.

Tested on a real screen:

- XCUITests, through the running app with real events: arrow keys, Shift-arrow, Select All and None, keeping the current item across list and tiles, Tab into the sidebar and back, and dragging a rubber band. On the Mac a test must drag with `click(forDuration:thenDragTo:)`. `press` compiles, but no event reaches the app.
- Light and dark, in the grid and the list, with the context menu and a rubber band in progress. Selection, focus and the video placeholder all read clearly.

Tested with no display:

- Real key events reach the grid and the list in a window that isn't shown, covering every implemented row of the shortcut table.
- Add Folder runs end to end on a read-only exFAT image: indexing, browsing, thumbnails, and nothing written to the image. Only the open panel itself is left out.
- After an unmount, browsing continues from stored thumbnails.
- `CARenderer` drew the real layer tree in both appearances and both layouts. Thumbnails keep the right way up in flipped and unflipped layers, and P3 surfaces match the same image drawn directly.

#### On the T7 Touch

Measured on a release build, with the drive mounted read-only and the library in the scratchpad, never on the drive. `Photos` holds 29,052 files, which is 27,235 assets, and `GoPro` adds 1,450 files, all videos.

| T7 Touch | Result |
|---|---|
| Index, `Photos` | 80 s at 368 files/s, reading 24.4 GB |
| All thumbnails, 23,604 photos | 7 min 15 s, about 31 minutes per 100k. 3.8 GB, about 160 KB per photo, and 3 files failed |
| Launch with this library, to the result | 350–365 ms |
| Open `Photos` | 22–24 ms |
| Grid scenarios, both displays | 120 fps, with main thread p99 under 2 ms and a worst frame of 2.9 ms |
| List scroll and arrow keys, both displays | 119–120 fps, with main thread p99 about 1 ms |
| Memory after all the scenarios | About 390 MB |
| Animation Hitches, 1x window | 1 hitch of 50 ms at launch, then 22 single-frame hitches in about 37 s. Render server p50 2.0 ms, p99 4.6 ms, worst 14.2 ms, and 10 of 6,428 frames over 8 ms |

**With thumbnails generating from the drive.** Starting with none, the app read the drive throughout the scenarios. In about 45 seconds it tried an embedded preview for 15,774 photos, which found 10,006, and finished 681 with full thumbnails, while tiles showed their stored colors and filled in. Grid scenarios held 119.5–120 fps and main thread p99 stayed under 1 ms. The list lost 4–5 frames of 479 in two scenarios, and its worst frame was 10.2 ms.

- Switching to the list loses 1–4 frames while it builds its rows, the first time. Timed together with the first scroll, that frame took 22–35 ms on the real library. It's a one-time cost, so it's left as it is for now.
- `PHOTON_PERF_SCENARIOS` now always starts from the grid. Quit saves the session, so a run that ended in the list would otherwise open there next time and drive a hidden grid, which looks excellent and means nothing. The seeded figures above were measured after this fix.

**Not verified:** a true 100k library on the drive, because it holds about 30,000 files and nothing may be written to it. Video tile layout with real durations, because `GoPro` isn't browsed with thumbnails until Milestone 6. The slide when columns change, and the new easing to fill the width, watched rather than measured. VoiceOver itself, and real trackpad pinch. Non-US keyboard layouts, and the shortcut table against Photos and Finder.

**Not built:** a compaction pass for packs. The status bar's count also doesn't follow a rubber band until the button comes up.

### Milestone 1 results

Measured with a release build at 4 jobs, on the real T7 Touch mounted read-only, over all of `Photos`. The drive wasn't remounted first, so the enumeration time may include cached directory data.

| T7 Touch, `Photos` | Enumerate | Read | Files opened | Bytes read |
|---|---|---|---|---|
| First index, 29,052 files | 0.52 s | 78.3 s, 371 files/s | 29,052 | 24.4 GB |
| Rescan, nothing changed | 0.15 s | None | 0 | 0 |

That's about 4.5 minutes per 100k files for this mix of files, for metadata and hashing together. It doesn't include thumbnails, which Spike 4 suggests will be the slow stage.

- There were no failures, and every file was hashed. Exact duplicates merged as designed: 1,817 files joined existing assets, leaving 27,235.
- The library file took 9.6 MB, about 330 bytes per file.
- Metadata coverage, with the full read for HEIC working as planned:

| Type | Files | Missing dimensions | Missing capture date |
|---|---|---|---|
| JPEG | 24,214 | 3 | 826 |
| MP4 | 3,693 | 0 | 127 |
| HEIC | 1,044 | 0 | 0 |
| MOV | 94 | 0 | 0 |
| PNG | 7 | 0 | 7 |

The run found one bug that synthetic files missed. Two videos declared a creation time of zero in Unix time, which read as 1970. Such dates now count as missing, and that fix came after this run.

As a second measure of what the pipeline itself costs, a release build read a 14 GB exFAT disk image on the internal SSD, mounted read-only, holding 20,000 synthetic files totaling 10 GB. The first index took 0.47 s to enumerate and 11.15 s to read (1,794 files/s), and a rescan took 0.10 s with no files opened.

- A `diskutil unmount` from outside the process succeeded during a run on that image. The run ended as `volumeOffline` with no failures.
- Tests on exFAT images cover changed-file rescans, read-only mounts staying byte-identical, remounts at a new path, clones, a forced detach, a normal eject and a refused unmount.

**Not verified:** a rescan of real changes on the T7 Touch, because it stayed read-only, so that's shown on disk images only. Also a remount of the T7 Touch, a refusal of the drive when it's really mounted writable, which is covered by a unit test only, and a physical pull, which is a Milestone 4 test. In the app, the window was checked in light and dark mode, but adding a folder through it hasn't been tried, and ad-hoc debug builds will ask again for removable volume access.

For now `LibraryIndexer` refuses any writable external volume, in the app too, so that a bug can't damage a drive before writes have been ruled out on real media. Milestone 4 should lift this, because a normal external drive is mounted writable.

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
| Hand-built grid costs more than expected | `CALayer` grid chosen knowingly. Selection, drag and accessibility are built with the grid, not added later |
| OpenGL is removed from macOS | Vulkan through MoltenVK works, but needs a patched mpv. Our own build makes that possible |
| Our own mpv and FFmpeg build is harder than expected | Not attempted yet, and needed before Milestone 6 |
| mpv's file access bypasses the I/O scheduler | Test `stream_cb.h` in Milestone 6 |
| Volume UUIDs change or collide without a marker file | File sampling on mount, hash-based reattachment, and separate handling of two mounted volumes with one UUID |
| First-time indexing takes tens of minutes | Priority scheduling, resumable stages, visible tiles first, one read per file |
| A slower link caps throughput | The T7 Touch linked at USB 2 speed on one connection. Worth showing in the UI if indexing is slow |
| Thumbnail cache grows too large | Size limit, with two-tier eviction |
| Drive removed during a read | No mapped reads, cancellation, physical drive-pull tests |
