# Photon implementation plan

Photon is a native macOS browser for photos and videos stored in local folders and on removable media. This document records the product scope, architecture, milestones and open risks.

**Status:** Milestone 6, video, is half built: AVFoundation plays, thumbnails and scrubs the format test set through the I/O scheduler, and the libmpv fallback isn't started. See [Milestone 6 results](#milestone-6-results). Milestone 5, organization, is built, and favorites survive moving a library to a new drive on disk images. See [Milestone 5 results](#milestone-5-results). Milestone 4 is built and checked on disk images, with no physical pull by the user's decision, and measured on a real screen on a seeded 100k library and on the T7 Touch's real library of 27,235 assets. See [Milestone 4 results](#milestone-4-results), [Milestone 3 results](#milestone-3-results) and [Milestone 2 results](#milestone-2-results). The drive doesn't hold 100k files, so those two libraries together stand in for a 100k library on the drive. Spike code lives in [`Spikes/`](../Spikes/README.md), and results are under [Milestone 0 spikes](#milestone-0-spikes) and [Milestone 1 results](#milestone-1-results).

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
| Video reads | AVFoundation reads through `AVAssetResourceLoader` on a private URL scheme, served by the volume's I/O scheduler | AVFoundation would otherwise open the file itself, past the scheduler, its cancellation and its handle count, and might memory-map it |
| Video | AVFoundation first, with a libmpv fallback, behind one interface. libmpv draws through its render API into a `CAOpenGLLayer`, from our own LGPL build | Spike 2: every test format played with no dropped frames on both embedding paths, and this one needs no patched mpv |
| Viewer | An overlay in the same window, one layer whose contents move from thumbnail to preview to full resolution. It covers the detail column, so the sidebar stays | The grid is never torn down, and a sharper image lands without anything moving |
| Previews | The size that fills the viewer for that photo, not the screen | A screen-sized preview would be scaled back down by the GPU, which costs sharpness as well as memory |
| Pasteboard writes | Off the main thread, after clearing the pasteboard at once | Writing costs about 150 µs per real file, and it must never stall a frame |
| Eject | Disk images only, unless the app is using its real library with no development setting. `VolumeEjector` reads the volume's location from the system again immediately before acting | The real drive must be out of reach of every test and tool, by construction rather than by care |
| Writable external drives | Read by the app, refused by `photon-index` | A normal external drive is mounted writable, and a test shows that indexing and thumbnails change no byte of a writable exFAT image. Tools stay strict, so a slip while measuring can't reach a writable drive |
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
| `sessions` | Per-location view state: sort, zoom, view mode, the asset on screen and how far down it was, the current item, and whether the viewer was open |
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
5. Rescan incrementally, skipping files whose path, size and modified time are unchanged. This runs in the background on every new connection, at launch too. An unchanged rescan lists directories and opens no files, and the rows only reload if something changed.

Rules that follow from this:

- Paths are stored relative to the volume root, because mount paths change (`/Volumes/Foo 1`).
- Bookmarks and file IDs are not used for identity. Bookmarks have been reported to break on exFAT. exFAT and FAT32 file IDs survive remounts, renames and moves on disk images, but they are reused for unrelated files after a delete, and exFAT IDs behaved like start clusters.
- A byte-for-byte clone is indistinguishable from its original: same UUID, file IDs, sizes and dates. It's harmless when mounted alone, because it is the same content. When two volumes with one UUID are mounted together, Photon must keep them apart by BSD name for the session, and must not bring a second copy online as the same `volumes` row. The second one isn't indexed for that session, and the status bar says "A copy of "Name" is connected. Photon is using the original." until it goes. exFAT's serial comes from the clock, so two images made in the same second share a UUID, and an unrelated volume could look like a clone in the same way.
- Don't use `isRemovable` or `isEjectable` to recognize external media. The T7 Touch reports both as false, and it reports no persistent ID support.
- Don't use `URLResourceKey.volumeUUIDStringKey` for identity. On FAT32 it returned a different UUID for a second mount of a clone, while DiskArbitration stayed stable.
- On `willUnmount`, cancel all work and close every file handle so that ejecting succeeds. An open handle does block the unmount. `willUnmount` also fires before an unmount that then fails, so if no `didUnmount` follows, the volume is still mounted and work must resume. Photon waits 5 seconds to find out. A suspended volume counts as offline in the meantime, and a volume that resumes picks up its thumbnails and sharpens what's on screen.
- `NSWorkspace` sends all three events for every local volume, including disk images attached with `-nobrowse`, and a forced detach sends both unmount events. A real failure may not, so a job that finds the mount gone also takes the volume offline, once.
- Renaming a volume moves its mount point with no unmount, so `didRenameVolume` ends the old session and reconnects.
- A dying drive can fail reads while its mount still looks healthy. `EIO` and its relatives are device failures, and a batch where every file fails asks the drive to list its root. If it can't, the run stops as `volumeFailing` and no file is blamed. If it can, the files really are bad. A batch with some successes counts its failures against the files, which at worst costs a file one of its three attempts.
- `getmntinfo` shares one buffer across threads, and two mount events at once corrupted the heap. Use `getmntinfo_r_np`.
- A gone mount makes every path look deleted. Any error, or empty listing, is checked against the mount before it's believed, so a failing drive never looks like an empty one. A scan only forgets a folder when the volume is still mounted and the scan confirmed it's gone. Folders that couldn't be listed keep their files.
- Reads on removable media must not be memory-mapped, because pulling the drive during a mapped read crashes the process (SIGBUS confirmed on a disk image). Ordinary reads return `EIO` immediately. Load bytes with ordinary reads and hand them to `CGImageSource`.
- Read-only volumes are normal: NTFS drives, and volumes mounted read-only. Rename and Move to Trash are disabled there.
- A sleeping drive can take a moment to wake. Nothing waits for it, and after a second the viewer's status bar says "Waiting for Name…". A stuck read can't be interrupted, so Eject waits 2 seconds for handles to close and then lets macOS answer.

**Offline.** A disconnected volume is a normal state. The status bar names it, and the sidebar shows its folders with a drive symbol. Everything that needs only the library keeps working:

| Feature | Offline |
|---|---|
| Sidebar, browsing, sorting, selection, list and tile views, keyboard | As usual, from the library |
| Tiles | Stored thumbnails, then the dominant color, then a neutral fill |
| Viewer | The stored thumbnail, and anything still in memory. Moving on works, and a read that was refused is retried when the volume returns |
| Copy | Up to 16 photos paste as their stored thumbnail. Past that they're left out. The status bar says so either way |
| Drag | Nothing to drag, and the status bar says why, once per selection |
| Show in Finder | Disabled |
| Add Folder | Works for other volumes. An offline folder can't be chosen |
| Thumbnails and indexing | Stop calmly, with nothing marked as failed, and carry on after a reconnect |
| Sessions | Saved and restored as usual |
| Eject | Not offered |
| Rename, Move to Trash | Not built. They must check `VolumeAccess.canModifyFiles` and disable themselves |

**Read-only volumes** behave as if online. The status bar says Read Only, and `VolumeAccess` is what future file operations must ask.

**Reconnecting** changes no rows unless the rescan found changes, so the place, selection and viewer stay put. What's on screen is asked for again, and the viewer tries again for anything sharper.

**Eject** is File → Eject, Command-E, the eject button on a root in the sidebar, or its context menu. It acts on the volume holding the folder showing, and ejects the whole disk, as Finder does. It stops all Photon's work on that disk first, and waits for handles to close, because an open handle blocks the unmount. If macOS refuses, usually because another app has a file open, nothing has changed, and the status bar says so.

**Session restore.** A session stores the asset on screen and how far down it was, and the current item separately, because they can be far apart. That's a fraction of the viewport, so it doesn't depend on window size. Launch also reopens the viewer if it was open, with `PHOTON_NO_VIEWER_RESTORE` turning that off for tests. A session for a folder that has left the library falls back to the first folder. An offline folder is still in the library, so it stays.

### Indexing

Indexing runs in stages, and each stage is resumable:

1. **Enumerate:** `getattrlistbulk` streams paths, sizes and dates. Tiles appear immediately.
2. **Metadata:** capture date, dimensions, orientation, duration.
3. **Thumbnails:** embedded previews first where available.
4. **Hashing:** sampled content hash.
5. **Pairing:** RAW+JPEG and Live Photo stacks.

Enumeration writes rows only for what differs, one directory at a time, so an unchanged rescan writes nothing and opens no files. Everything left to do is stored as pending rows, so a run can stop at any point and the next one carries on. Milestone 1 covers stages 1, 2 and 4, Milestone 2 stage 3, and Milestone 5 stage 5. Pairing runs at the end of every indexing run, from the database alone. See [Organization](#organization).

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
- Video thumbnails are one frame through AVFoundation, which reads only the index and a keyframe. They haven't been measured on the T7.

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
- **Video tiles** show a frame from about a second in, or halfway through a shorter clip, at the nearest keyframe, which decodes one frame. The first frame is often black. They keep the duration badge. A video gets no embedded preview stage, so the first pass reads nothing for it. A format no engine here decodes is marked failed without a read, and keeps the film symbol, so the fallback's arrival needs a migration that clears failed videos.
- **Offline**, stored thumbnails show as usual. Anything missing keeps its dominant color, or a neutral fill, and nothing fails.

### Grid and list

- Grid and list share one data source and selection model.
- A query result is a compact array of row IDs, and rows load in pages as they're needed.
- Square tiles always fill the width at rest, as in Photos on iOS, with no side margins. The size chosen only sets the column count, and the tile is whatever fits that many columns. A pinch follows the fingers exactly, with margins while it lasts, and eases to fill the width when it ends. A scroll with Command or Option held does the same around the pointer, easing toward where its notches add up to. A plain scroll only scrolls, so a mouse wheel needs the key here, unlike in the viewer. The slider and Cmd-plus or Cmd-minus ease from one column count to the next, and a shortcut always changes the count unless the size limit stops it. Window resizing stays filled throughout. Reduce Motion turns the easing off. Aspect-ratio rows already fill the width, and their size stays continuous.
- The tile under the cursor stays anchored vertically, to within half a device pixel, because the clip view snaps to pixels.
- **Sideways jumps:** when the column count changes, rows break so that the anchor stays in its column, which adds blank cells before the first item (`phase`). Each tile then slides from its old position with an additive animation, so the frames of a continuing pinch carry on underneath. Reduce Motion turns the slide off. The blank cells clear, with the same slide, once the top of the library is on screen.
- Layouts are square and aspect-ratio. During a zoom, aspect-ratio rows are built outward from the anchor, only as far as they're looked at, and heights come from an estimate. The full pass runs off the main thread afterward and breaks rows at the same place, so nothing visibly moves when it lands.
- Tile layers use coordinates relative to a coarsely moving base, and never document coordinates, which reach tens of millions of points.
- Accessibility, hit testing, selection, drag source, context menus and focus rings are hand-built, since `CALayer` provides none of them.
- If capture dates arrive during a sort, the list re-sorts around the anchor so that the view doesn't jump. While indexing, the query runs at most every 2 seconds, and everything proportional to the library happens off the main thread: the query, the layout pass, and the map from old rows to new ones.
- Selection is ranges of rows, so selecting 100k items costs one range. The map above carries it across a change of order.
- **Rubber band.** As in Finder and Photos, a plain drag on a tile drags the file, selecting the tile first if it wasn't, and a plain drag from a gap draws a band. Tiles nearly fill the view, so Shift or Command starts a band on any tile too, and keeps what was already selected. A plain click on one of several selected tiles narrows the selection only when the button comes up, because the press could still be a drag. Holding the pointer past the top or bottom scrolls, faster the further past. Tiles on screen check the rectangle directly, and the rows are worked out once, off the main thread, when the button comes up, so a band over the whole library costs only what's visible on each frame. The status bar's count catches up then too.
- **Hover previews.** A video plays in its tile once the pointer has rested on it for 0.6 seconds, muted and looping, as in Photos. Only one plays at a time. It starts from the poster frame, which the tile already shows, and its layer only appears once that frame is ready, so the tile never jumps. Scrolling, zooming, a press, a key, a rubber band or opening the viewer stops it, and nothing starts while the grid is moving. A reload, which indexing makes every couple of seconds, keeps it playing if its video is still on screen. Reduce Motion turns previews off, and Settings should get a switch for them in Milestone 7. An offline video, or a format no engine plays, gets none. The keyboard has no equivalent, by choice: playing the current tile would play while you browse the photos beside it. The list has none, because its thumbnails are too small to show motion.
- **The list stays alive but idle while hidden.** A hidden `NSTableView` still lays out rows and makes cells, and that cost the grid hitches of up to 46 ms. It takes the result and the selection when it next shows.

### Viewer

- The viewer is an overlay in the same window. The grid is never torn down.
- A zoom transition runs from the tile to full view and back. If you arrowed to another photo, the grid moves to it on exit.
- Images load progressively: thumbnail, preview, full resolution.
- Neighboring photos are preloaded.
- HDR content uses extended dynamic range.
- The viewer's background is the window background, so it follows light and dark mode.
- **Three steps.** The stored thumbnail shows at once. A preview comes next, then, after a photo has stayed for 300 ms or as soon as a zoom needs it, the original's own pixels. One read serves both decodes. Fit shows the preview, placed on whole device pixels, and full resolution is only used once a zoom needs more pixels than the preview has.
- **Preloading.** The next two photos in the direction of travel and one behind get previews, at the `ahead` priority. Seven photos stay decoded, and only the current one keeps full resolution. Their originals stay in memory up to 300 MB, so that going on to a neighbor doesn't read the file again.
- **A held key touches no disk.** A key repeat only shows what's in memory, and asks for the stored thumbnail, which is cancelled on moving on. Reads and the status bar wait until the key has rested for 120 ms. A single press starts at once.
- **The grid and list stay still while the viewer moves.** The selection model follows along, but neither is told until the viewer closes. A held key costs them nothing.
- **Closing** selects the photo you ended on only if you moved. Opening and closing in place keeps a multiple selection.
- **Zoom** is a multiple of fit, and the center is a point on the photo, so neither depends on which decoded size is showing. A step stops at actual size. Zoom goes up to 8× actual size, and returns to fit on moving to another photo.
- **Zoom controls.** A pinch, a double click, Command-Equals and Command-Minus, and two buttons in the toolbar where the tile size slider sits in the browser. A mouse wheel zooms around the pointer, because a mouse has no pinch, and so does any scroll with Command or Option held. A scroll's zoom eases toward where the notches add up to, frame by frame, finishing in about 180 ms, and Reduce Motion goes straight there. A pinch stays exact, since it follows the fingers. A trackpad's plain scroll still pans and swipes.
- **Title.** The window's title shows the file name, and its subtitle the capture date, the way Preview shows a document. It comes from the library, so it works offline, and it waits for a held key like the status bar does. It sets the title through a modifier, so that a new photo doesn't run `BrowserShell`'s body. The folder's name comes back on closing.
- **More Info** in the context menu shows the inspector, which follows the photo showing.
- **Limits.** Decoding stops at 16,384 px on the long edge, the texture limit, and at 120 MP. A larger photo shows smaller. That's 480 MB at 8 bits, and twice that for HDR.
- **HDR** decodes with `kCGImageSourceDecodeToHDR` into half-float pixels in extended linear P3. The surface is tagged with `kIOSurfaceContentHeadroom`, and the layer sets `preferredDynamicRange = .high`, so extended range is only used for photos that have it. Thumbnails stay SDR, so an HDR photo brightens when its preview lands.
- **Transitions** fly in Core Animation, from the tile's crop to the whole photo and back, so they don't depend on the main thread. Reduce Motion replaces them with a fade.
- **Offline**, or if the file changed, the thumbnail stays and nothing fails. Moving on works as usual.
- **Permission.** A build with no stable signature, started by Launch Services, may not get removable-volume access, and then reads fail with the same quiet result, so the viewer stays on thumbnails with no explanation. Milestone 7's signing should settle this. If it doesn't, this needs a message of its own.
- **Videos** fly in from their tile like photos, on their stored thumbnail, and the player's layer only appears over it once it has a frame, so nothing flashes black. A player opens once the viewer has settled, so a held key passes videos without opening any, and it starts playing at once. Moving on or closing stops it, and the flight back carries the thumbnail. Zoom is off for videos. See [Video](#video) for the controls.
- **Rotation isn't applied.** Nothing sets the stored rotation yet. When something does, the viewer has to use it too.

### Copy and drag

One shared command serves grid, list and viewer. The pasteboard carries file URLs and lazily generated image data, so paste works in Finder and in apps like Messages and Figma. Large selections stay instant. Videos carry file URLs only.

- **One command.** A responder sits in the chain behind the window, so Copy reaches the browser wherever focus is, and text fields can still handle it first. The context menu uses the same command. It acts on the photo showing in the viewer, or else the selection, or else the current item.
- **Instant means the main thread.** Command-C returns at once and clears the pasteboard, then the query and the write run elsewhere. All 27,235 real files take about 4 seconds to land, with no frame lost. A paste in that gap finds nothing, which beats pasting what was copied before, and the status bar says when a copy of 2,000 or more is on its way and done.
- **Image data** is PNG and TIFF, made only when an app asks, for selections of up to 16. It's upright, tone mapped to SDR, and at most 4096 px, so that encoding fits the wait below. Anything taking the file gets the original.
- **AppKit asks for promised data on the main thread** and waits there. So the read and encoding run elsewhere through the I/O scheduler, and the main thread waits for at most 4 seconds, which is enough for a sleeping drive to wake. The file URL stays either way.
- **Promises at quit.** AppKit fills every promise when the app quits, on the main thread. Photon drops them instead, so after quitting the pasteboard keeps the file URLs and loses the pixels.
- **Offline**, a photo has no URL, but up to 16 can still paste as their stored thumbnail. Past that they're left out. The status bar says so either way.

**Dragging** starts from a selected tile, a selected list row or the photo in the viewer at fit, and offers copying only, so a drop can never move or delete an original. The files' URLs are fetched when the button goes down, because a drag has to start at once. A drag has at most 16 dragging items. AppKit walks them on worker threads, which is why `isFlipped` on a drag source must stay `nonisolated`: a main-actor getter crashes there, and only on large selections. The other files go straight onto the drag's pasteboard, off the main thread, so a drop in the first moments of a very large drag may carry only some of them.

### Organization

Favorites, albums, tags and stacks attach to assets, and live in the library on the internal disk. None of them reads or writes a file, so all of them work the same on offline and read-only volumes. A file that's offline still shows in an album, from its stored thumbnail, and can be favorited and tagged.

**Sources.** What the browser shows is a source: a folder, All Items, Favorites, an album, a smart album or a tag. Grid, list and viewer don't know which, because each one is a query giving the same `BrowseResult`. A source other than a folder spans volumes, so each asset's row prefers a file on a volume that's online, and the status bar only names a volume for a folder.

**Sidebar**, from the top, as in Photos and Finder:

| Section | Rows | Actions |
|---|---|---|
| Library | All Items, Favorites | |
| Albums | Manual and smart albums, by name. A smart album has its own symbol | New Album, New Smart Album, Rename, Edit Smart Album, Delete Album, from the File menu and the context menu |
| Tags | Every tag, by name | Rename, Delete Tag, from the context menu |
| Folders | Library roots and their folders, as before | Eject |

Deleting an album or a tag never touches a file. It asks first, because the album can't come back.

**Favorites.** Period toggles the photo in the viewer, or else the selection, or else the current item, which is what Copy acts on. If any of them isn't a favorite, all of them become favorites. Otherwise, all of them stop being favorites, as in Photos. It's also in the Image menu, the context menu, the toolbar and the inspector. A favorite has a heart on its tile and in the list. Unfavoriting in Favorites removes the tile, and the current item moves to its neighbor.

**Albums** hold assets, never files. Add to Album, in the Image menu and the context menu, lists the albums and New Album. In a manual album, Remove from Album is in the same menus, and on Delete. An album sorts with the usual sort keys, and has no manual order yet.

**Tags** are names, unique ignoring case. The inspector adds one by typing, with completion from existing tags, and removes one from its token. The context menu's Tags submenu toggles any existing tag on the selection.

**Smart albums** are saved queries, stored as JSON in `albums.smart_query`. A query is "match all" or "match any" of a list of rules, as in Photos' and Finder's smart folders:

| Field | Operators |
|---|---|
| Favorite | is, is not |
| Kind | is photo, is video |
| Tag | is, is not |
| Album | is in, is not in, manual albums only |
| File name, folder | contains, doesn't contain |
| File type | is, the extension |
| Capture date | in the last N days, before, after, in year |
| Duration | longer than, shorter than, in seconds |

The editor is a sheet with the album's name, a Match All or Any pop-up, and a row of pop-ups and a value per rule, with add and remove buttons. Rules compile to SQL in `PhotonCore`, so the UI never sees SQL. A rule this version doesn't know makes the album show nothing, and the editor says it can't edit it, so that an older Photon never rewrites a newer query.

**Search.** Command-F goes to the search field in the toolbar, and typing filters what's showing, after a short pause. Escape clears it, and choosing another source clears it too. Search the whole library from All Items. Words are separated by spaces, and every word must match one of:

- the file name or folder path, anywhere in it, ignoring case
- the start of a tag's or a manual album's name
- photo, photos, video or videos
- a year of capture, such as 2024, or a month's name in English or the current language

It runs in the library, so it works offline. It isn't saved with the session.

**Stacks** come from pairing, the last stage of indexing, by name alone: two files in the same folder of one volume, with the same name before the extension, ignoring case.

| Pair | Stack | Cover |
|---|---|---|
| A RAW file and a JPEG or HEIC | RAW+JPEG | The JPEG or HEIC, because it's the camera's own rendering and it decodes everywhere |
| A JPEG or HEIC and a MOV or MP4 of at most 4 seconds | Live Photo | The photo |

An asset is in at most one stack. Pairing compares what it finds with what's stored and writes only the difference, so an unchanged rescan still writes nothing. It works from the database, so it never reads a file.

A stack shows as one tile, its cover, with a badge for its kind, in the grid, the list and the viewer. A member is only hidden when its cover is in the same result, so a favorite RAW whose JPEG isn't a favorite still shows in Favorites. View → Expand Stacks shows every member as its own tile, everywhere. The inspector lists the stack's members. Copy and drag act on the cover alone while a stack is collapsed. A Live Photo's motion isn't built yet.

**Inspector.** Command-I, View → Show Inspector, the toolbar's info button, or More Info in the context menu. It's a column at the trailing edge, beside grid, list and viewer, and it describes the photo in the viewer, or else the current item. It shows the name, kind and format, pixel dimensions, size, capture date, duration, favorite, tags, the albums holding it, its stack, and every file holding the content, by volume and path. A file on an offline volume says Offline, and a read-only one says Read Only. It reads only the library, and it waits for a held key like the status bar.

**Sessions** are saved for every source, not only folders, so the last album or tag reopens at launch. A deleted album or tag takes its session with it, and launch falls back to the first folder.

**Moving a library to a new drive** is tested on disk images: index an exFAT image, favorite, tag and add to an album, detach it, copy the same files to a second image with its own UUID under a different folder layout, some of them renamed, and index that. Every favorite, tag and album must follow the content to the new image, with rows on the new image's files, both with the old image gone and with it back.

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

**Shortcuts.** Some rows have no effect yet: rename and trash need the file operations layer. Rotation has no milestone yet. The checks against Photos and Finder, and on non-US layouts, haven't been done.

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
| Everywhere | Cmd-E | Eject the volume holding this folder |
| Grid, list and viewer | Period | Toggle favorite. Not a menu shortcut, so that a period in the search field stays text |
| Grid and list | Delete | Remove from album, in a manual album only. Not a menu shortcut, for the same reason |
| Everywhere | Cmd-I | Show or hide the inspector |
| Everywhere | Cmd-F | Search |
| Everywhere | Cmd-N, Cmd-Option-N | New album, new smart album |
| Everywhere | Cmd-R, Cmd-Option-R | Rotate right, rotate left (non-destructive) |
| Everywhere | Cmd-Shift-R | Rename |
| Everywhere | Cmd-Delete | Move to Trash |
| Everywhere | Ctrl-Cmd-S | Show or hide the sidebar |
| Everywhere | Ctrl-Cmd-F | Enter or leave full screen |
| Viewer | Left, Right | Previous or next item, or pan when zoomed in |
| Viewer | Up, Down | Pan when zoomed in |
| Viewer | Home, End | Go to the first or last item |
| Viewer | Escape, Space, Cmd-Up | Close the viewer |
| Viewer | Cmd-Equals, Cmd-Minus, Cmd-0 | Zoom in, zoom out, fit to window |
| Video | Space | Play or pause |
| Video | J, K, L | Reverse, pause, play forward |
| Video | Shift-Left, Shift-Right | Seek 5 seconds |
| Video | Option-Left, Option-Right | Step one frame |
| Video | M | Mute |

Space closes a photo in the viewer, so it works as a quick look toggle. For videos it plays and pauses, and Escape closes. J and L each double the speed in their direction up to 8×, as in editing apps, and J only plays backward where AVFoundation can. A click on a video plays or pauses it, as in QuickTime Player. Letters are matched by character, like Period.

The viewer also takes a pinch, a mouse wheel or a scroll with Command or Option held to zoom, the toolbar's zoom buttons, a double click or two-finger double tap to toggle actual size, dragging or a trackpad scroll to pan when zoomed in, and a two-finger swipe to the next photo at fit. Double-clicking a tile or row opens it. In the grid, a scroll with Command or Option held changes the tile size. These need the mouse or trackpad, and everything they do has a key.

### Video

`VideoEngine` hides two implementations:

- **AVFoundation:** MOV and MP4 with H.264, HEVC, ProRes, and AV1 on Macs with a hardware decoder (M3 and later).
- **libmpv fallback:** MKV, WebM, AVI, WMV and similar. Thumbnails for these formats use FFmpeg's libraries, so both share one dependency stack.

libmpv uses `vo=libmpv` and the OpenGL render API, drawn into a `CAOpenGLLayer` tagged sRGB. OpenGL is deprecated, so the Vulkan path through MoltenVK stays as the exit. It needs a patched mpv to handle window resizes, which our own build would make possible.

**Reads.** AVFoundation never gets a file URL. `ScheduledResourceLoader` gives it a URL on a private scheme and answers each loading request with one I/O job: open the file, check its size and modified time against the library, read in 1 MB pieces, check again, close. A request is answered with at most 4 MB, and AVFoundation asks again for the rest, so a request to the end of a large file never pulls all of it into memory, and no job holds the volume for long. Playback reads at `visible`, and background thumbnails at `backgroundWork`. No handle stays open between requests, so `willUnmount` finds nothing to close but what's mid-read. A read that fails for the drive's sake makes the playback `unavailable`, which retries from the same place once the volume is back, and a file AVFoundation can't decode is `unsupported`.

**Controls.** A transport bar on Liquid Glass at the bottom of the viewer: play and pause, elapsed and remaining time, a scrubber and mute. It appears when the video is ready and on any pointer movement, and goes 2.5 seconds after the last one while playing. It stays while paused or in use. None of its controls take focus, so the keys stay with the viewer. Mute carries from one video to the next.

**Scrub previews.** Hovering over the scrubber or dragging it shows a frame above the bar, with its time. Frames come from the playback's own asset, at the nearest keyframe within half a second, at 160 pt. One decodes at a time, and only the latest request waits behind it, so a fast drag never builds a queue. A drag also moves the video itself to keyframes as it goes, then to the exact frame when the button comes up, and playing resumes if it was playing.

**Format test set.** `SyntheticVideo` writes real clips with AVFoundation, with a color that changes per frame: H.264 in MP4, MOV and M4V, HEVC in MOV and MP4, ProRes 422 and Motion JPEG in MOV. `photon-index videos <folder>` writes the same set for looking at in the app. The fallback's formats need clips from FFmpeg, which CI doesn't have.

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
| Main thread time per frame | Under 8 ms, so that a frame is never at risk | Worst p99 3.6 ms. Worst single frame 4.7 ms in the grid and 12.1 ms in the list, measured at Milestone 2. Later runs reached 8.8 ms in the list and 7.0 ms in the viewer. The user accepted the list's 12.1 ms over budget by merging Milestone 2 |
| Render server time per frame | Under 8 ms | p99 3.6–5.9 ms, worst 14.8 ms. 9 of 7,418 and 11 of 5,049 frames over budget |
| Holding an arrow key in grid, list or viewer | Keeps up with key repeat, with no dropped frames | Grid, list and viewer keep up at 30 and 240 key events per second, and grid and list with Shift at 30. The viewer loses at most 1 frame in a scenario |
| App memory in normal use | Under 1.5 GB | About 460–600 MB after all the scenarios. 655 MB at most after viewer scenarios on real photos |
| Open or close the viewer | No dropped frames in the transition | One frame lost as each begins, then the flight runs clean. See [Milestone 3 results](#milestone-3-results) |
| Next photo sharp in the viewer | At once when preloaded | Under 0.3 ms preloaded. 95–145 ms typically and 254 ms at worst when not, from the T7 |

Milestone 4's figures, with the first-pass frames over budget, are in [Milestone 4 results](#milestone-4-results).

The spike's in-app timers reported no missed frames in the same scenarios where Instruments found these hitches, so the in-app numbers can miss a problem. They're still the routine check, because a full trace on every milestone cost more than it found.

Budgets are tracked with `os_signpost` and automated performance tests on a synthetic library, starting in Milestone 1.

### How milestones are measured

By the user's request from Milestone 5 on, to spend less time on measurement and more on features:

- **The budgets are targets.** An occasional single frame over the 8 ms main-thread budget, or a launch a little over target in one run, is acceptable without a fix or a recorded decision. Only a repeatable regression needs one: the same scenario over budget again on a second run.
- **One quick pass.** A milestone that touches the grid, list, viewer or launch gets one run of `PHOTON_PERF_OUT` on the seeded 100k library, on one display. A milestone that touches none of them needs no measurement.
- **No repeats by default.** A run is repeated only to check whether something over budget is repeatable.
- **Instruments only for a real problem.** An Animation Hitches trace is recorded only when the in-app timers show one.
- **The T7 Touch library is optional.** Measuring on the real drive is welcome, read-only as always, but no milestone needs it.

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | **Spikes** (below) | Grid approach and video engine chosen on measured results |
| 1 | **Foundation:** packages, CI, schema, scanner, metadata | A real drive indexes in the background, and rescans touch only changed files |
| 2 | **Grid:** thumbnails, fluid tile size, list view, sorting, selection, keyboard navigation | Budgets met on a 100k library, on the external drive, and arrow-key navigation and selection work in grid and list |
| 3 | **Viewer:** progressive loading, zoom, HDR, transitions, copy and drag, keyboard control | Your place is always kept, copy works in every mode, and the viewer can be navigated from the keyboard |
| 4 | **Removable media:** mount handling, offline mode, session restore, eject | Passes the [removable media checks](#removable-media-checks) on disk images: forced detach, injected failures, reconnect and eject |
| 5 | **Organization:** favorites, albums, tags, smart albums, search, stacks | Favorites survive moving a library to a new drive |
| 6 | **Video:** AVPlayer, fallback engine, thumbnails, scrub previews | A format test set plays and shows thumbnails |
| 7 | **Polish and release:** accessibility, Settings, onboarding, signed DMG workflow, screenshots | Ready for daily use, with a tagged release on GitHub |
| 8 | **Duplicates:** near-duplicate detection, similar-scene stacks | Similar scenes collapse into one browsable tile |
| 9 | **Cloud backup:** JSON export keyed by hash, then encrypted backup of originals | Favorites can be restored after losing a drive |
| 10 | **Faces:** detection, bundled embedding model, clustering, correction UI | People can be browsed and corrected |

The schema work in Milestone 1 includes the identity model and stacks, even though their features arrive later.

### Removable media checks

**The user's decision:** Photon's removable media behavior is checked without any physical pull, to protect the data on the real drive. The T7 Touch is never pulled, unmounted, ejected, remounted, written to or power-cycled for a test, by any means. It stays mounted read-only, and reading from it for measurements is fine. This replaces the physical drive-pull test that earlier versions of this plan asked for.

What stands in for a pull:

| Check | How |
|---|---|
| Drive removed | `hdiutil detach -force` on an exFAT disk image, which uses the same FSKit driver as the drive |
| Reconnect | Detaching and attaching the same image, which has the same UUID and files |
| Eject | The app's own Eject command, on disk images only |
| What an image can't produce | Injected I/O failures in `VolumeIOScheduler`: reads that fail while the mount still looks healthy, and reads that stall |

**What simulation can't show:**

- A real USB failure's timing. A forced detach fails reads at once, and a real cable may first stall them for seconds. Injected stalls cover the logic, not the true length or shape of a stall.
- What the USB stack, the drive's firmware and exFAT's on-disk state do when power goes during a read. Photon only reads, but the check says nothing about the drive's own behavior.
- Removable-volume permission, because disk images aren't gated by TCC.
- A drive that vanishes without any notification. A real failure's order of events may differ from a disk image's.

### Milestone 0 spikes

| # | Spike | State |
|---|---|---|
| 1 | Grid zoom and navigation | Decided: `CALayer` grid. Real trackpad and VoiceOver checks remain |
| 2 | libmpv embedding | Decided: render API in a `CAOpenGLLayer`. On-screen pacing and our own build remain |
| 3 | Volume identity | Done on the T7 Touch and disk images. A physical pull was dropped by the user's decision |
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

**Not tested:** a physical pull of the drive, which was left out to protect the data on it. It won't be tested, by the user's decision: see [Removable media checks](#removable-media-checks). File IDs across a physical reconnect were not compared, only across remounts. Whether modified times shift on exFAT when the time zone changes is also untested, and that would affect the file sample in step 2.

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

### Milestone 6 results

The AVFoundation half is built: video thumbnails, playback in the viewer, its controls, scrub previews and the video keys, all reading through the volume's I/O scheduler. `VideoEngine` hides it, so the fallback can join without the viewer changing. The libmpv fallback isn't started, because it needs our own LGPL build of mpv and FFmpeg first.

**Done when a format test set plays and shows thumbnails**, for AVFoundation's half. All 7 formats in the set got thumbnails through the scheduler, then played, seeked to an exact frame and gave a scrub preview, in `VideoFormatTests`. A clip written held upright has an upright thumbnail. The fallback's formats, MKV, WebM, AVI, WMV and the rest, show the film symbol and say "Can't play this format".

**Removable media**, on exFAT disk images, by the user's decision in [Removable media checks](#removable-media-checks):

| Check | Result |
|---|---|
| Thumbnails from a read-only image | H.264, HEVC and ProRes all made, and the image is byte for byte unchanged |
| `willUnmount` during playback | No handle stays open |
| Forced detach during playback | A new read says `unavailable`, not `unsupported`, and the app keeps running |
| Reattach | The same video plays again and seeks to an exact frame |
| Reads failing with `EIO` on a healthy mount | The thumbnail stays pending, not failed, and no handle is left open |
| A file changed since indexing | It isn't read as the old one |

**Tests:** 459 Swift Testing tests pass, up from 442. 8 are the format test set, 2 are video on disk images, and 7 drive the browser through real events in a window that isn't shown: video tiles get frames, Space plays and pauses, J, K, L, M and the modified arrows work, a held arrow key opens no player, a format with no engine says so, and hover previews start on resting, survive a reload, and stop for a move, a key, a scroll and the viewer.

**Real GoPro files**, two clips copied from the T7's `GoPro` folder to the internal disk, because the drive was mounted writable at the time and `photon-index scan` refuses that: 4K HEVC at 25 fps, with AAC sound and GoPro's timecode and telemetry tracks. Both got thumbnails in 0.14 seconds together, played in the viewer, stopped on their last frame at the end, and played as hover previews in their tiles, checked by pixel differences between window snapshots. `PHOTON_HOVER_ROW` rests the pointer on a tile, for looking at a preview without driving the app.

**Light and dark**, by window snapshot from the running app, on a library of the format test set at 1280×720 with synthetic photos: the grid with video frames and duration badges, the film symbol for videos with no frames, and the viewer playing HEVC with the transport bar. Both read clearly.

**Performance:** one pass with `PHOTON_PERF_OUT` on the seeded 100k library, on the Retina display, release build, then a repeat for launch. The grid scenarios ran at 119.6–120 fps with no more than 2 missed frames, a worst main-thread frame of 4.1 ms, and 401–608 MB. Opening a folder took 72–73 ms. Launch took 410–441 ms to the result and 482–522 ms to the frame after it, over the 350 ms target, so `main` was built and measured alongside it on the same machine: 407–409 ms and 480–490 ms. Linking AVFoundation costs nothing measurable, and both are slower than at Milestone 5 on the same seeded library, for a reason this pass didn't look into. The first launch of each new binary took about 1 second, on both. Only the grid scenarios ran, as in Milestone 5's pass, so the list and viewer scenarios still need a run.

What building it found, and fixed:

- **A reload stopped hover previews.** Every new result recycles the tiles, which stopped the preview, so in the real app a launch's rescan cut it off within 2 seconds while the tests passed. The preview now moves to its video's new tile, and stops only if the video has gone.
- **`AVAssetWriter` holds its file for a moment after it finishes**, so an image it wrote to couldn't be detached at once. The tests write clips on the internal disk and copy them over. A failing run had left two images attached, which were detached by image path.

**Not verified:**

- The transport bar's autohide, the scrub preview, the scrubber and hover previews by a real pointer. Hover previews are tested by calling the grid's pointer handler, and seen in the app through `PHOTON_HOVER_ROW`. They're built from AppKit's own slider and buttons, and only the keys are tested.
- Real camera files: phone HEVC with HDR, Dolby Vision, GoPro's files on the T7, and long files. HDR video should use extended range through `AVPlayerLayer`, but nothing has checked it.
- Sound, and AVFoundation's reads during long playback from a real drive.
- VoiceOver on the controls.

**Not built:**

- The libmpv fallback, its thumbnails through FFmpeg, and metadata for its containers. When it arrives, a migration must clear the failed state of videos it can decode.
- A Live Photo's motion. How it should work is in [Live Photo motion](#live-photo-motion).
- Play and pause in the menu bar. Space can't be a menu shortcut, because the menu would take it from the search field.

### Milestone 5 results

Organization is built as designed in [Organization](#organization): favorites, albums, tags, smart albums, search, stacks and the inspector, with sessions for every source. The schema moved to v4, which rebuilds `sessions` so that All Items, Favorites and tags can have one, with a migration test from v3.

**Done when favorites survive moving a library to a new drive.** `DriveMoveTests`, on two exFAT disk images: 40 files indexed on one, with 5 favorites, a tag on 5, a manual album of 4 and a smart album, then copied to a second image with its own UUID, into another folder layout with a third of them renamed. With the first image detached, all 40 merged into their assets, no asset was added, and every favorite, tag, album and smart album showed the same content, from the new image's files. With both attached, nothing changed, and the inspector listed both copies. The real drive was never involved.

**Tests:** 442 Swift Testing tests pass, up from 412: 19 new in `PhotonCore` for organization and the v4 migration, 9 through real key events in `PhotonUITests`, an offscreen render of the sidebar and inspector, and the drive move on disk images. `OrganizationUITests` adds XCUITests for Period in the grid and the viewer, Command-I, and Command-F with a period typed into the search field. They weren't run, because the screen was locked for the whole session.

**Light and dark**, rendered offscreen with the screen locked: the sidebar and the inspector through `NSHostingView`, and the grid's heart marks through `CARenderer`, in both appearances. A selected sidebar row draws black in an offscreen render, which is the render, not the app. Nothing was looked at on a real screen.

**Performance:** one pass with `PHOTON_PERF_OUT` on the seeded 100k library, on the Retina display, release build, with the screen locked. Launch to the result was 350 ms and opening a folder 77 ms. The grid scenarios ran at 119.1–120 fps with a worst main-thread frame of 2.9 ms and 426 MB. The list and viewer scenarios hadn't finished when the run was stopped at 4 minutes, and launch to the first frame isn't meaningful while the screen is locked, so this pass should be repeated on an unlocked screen. The grid adds only a small mark layer per tile, and a source's query is the same single pass as a folder's.

What building it found, and fixed:

- **A menu shortcut with no modifier takes the key from text fields.** Period and Delete as Image menu shortcuts would have favorited the selection, or removed it from an album, while typing in the search field. Grid, list and viewer handle them instead, and the context menu shows them.
- **A source spanning volumes picked a file at random** for each asset, which could be one on an offline drive while another copy was online. Rows now prefer an online volume's file, and reload when a volume comes or goes.
- **The toggle query's arguments were out of order**, so the first press did nothing. A test caught it.

**Not verified:**

- Anything on a real screen: the XCUITests, the search field's Command-F against the system's own Find item, the inspector's tag completion, the smart album sheet, and the new menus.
- The list and viewer performance scenarios, and launch to the first frame.
- Stacks from real camera files. Pairing was tested with synthetic files, a RAW copy made by renaming a JPEG.

**Not built:**

- Favoriting or tagging an unhashed file doesn't hash it at once yet. Merging keeps organization data from both sides, so nothing is lost when hashing reaches it, but a provisional asset whose only file goes before it's hashed loses its favorite.
- Albums have no manual order, and items can't be dragged onto an album in the sidebar.
- A Live Photo's motion, which needs Milestone 6.

### Milestone 4 results

Checked on disk images only, by the user's decision in [Removable media checks](#removable-media-checks). The T7 Touch was never pulled, unmounted, ejected, remounted or written to, and stayed mounted read-only at every check. It was only read, for measurements.

| Check | How | Result |
|---|---|---|
| Forced detach while browsing | `hdiutil detach -force`, in tests and in the real app | The grid, list and viewer keep their place and selection. The status bar names the volume, and nothing is marked as failed |
| Forced detach while making thumbnails | A read delay injected so the detach lands mid-run | The run stops calmly, and finishes after a reattach with 0 failures |
| Forced detach in the viewer | XCUITest, real app | The viewer stays open on the same photo, then sharpens after the reattach |
| Reconnect | Detaching and attaching the same image | Rows unchanged, place kept, thumbnails resume. A rescan runs on each connection |
| Eject | File → Eject and Command-E, XCUITest, real app | Unmounts the image, the folder goes offline, and the next attach brings it back |
| Eject refused | A handle held open by another process | Nothing changes, work resumes, and the status bar says so |
| Eject on a real drive | `EjectScope` | Refused under tests, tools and any `PHOTON_*` setting. Never run |
| Reads that fail on a healthy-looking mount | Injected `EIO` | The run stops as `volumeFailing`, and no file is blamed |
| Reads that stall | Injected stalls | The viewer says "Waiting for Name…" after a second, and nothing blocks the main thread |
| `willUnmount` with no `didUnmount` | Unmount refused | Work resumes after 5 seconds |
| Two mount events at once | Parallel image attaches | Crashed in `getmntinfo` until it became `getmntinfo_r_np` |
| A clone beside its original | Two images with one UUID | The second is kept out, and the status bar says so |
| Read-only volume | Image attached `-readonly` | Normal browsing, Read Only in the status bar |
| Writable exFAT image | Index and make thumbnails, then hash every byte | No byte changed compared with attaching alone, because FSKit mounts exFAT `noatime` |
| Session restore | Tests, and quitting in the viewer | The place, current item and open viewer come back. A v2 library migrates to v3 |

**Tests:** 412 Swift Testing tests pass, including 29 integration tests on disk images. XCUITests, through the real app with real events on a disk image: 16 of 16, which were 3 removable media tests and 13 keyboard tests. The Copy test was skipped, and `FileTransferUITests` wasn't rerun.

**Light and dark**, by screenshot: online, read-only, offline, and the offline viewer, each in both modes.

**Budgets**, from a release build with the window filling the display, on the external 1x display and the Retina built-in display at 120 Hz. AC power wasn't confirmed.

| Measure | Seeded 100k | T7 Touch, 27,235 assets |
|---|---|---|
| Launch to result | 309–365 ms, and 618 ms on the first launch after the v3 migration | 338–369 ms |
| Launch to the frame after it | 344–438 ms | |
| Open a folder | 72–85 ms | 23–34 ms |
| Grid | 119.3–120 fps, p99 3.0 ms, worst 4.4 ms | 118.1–120 fps, worst 2.9 ms |
| List scroll | 119–119.3 fps, worst 8.9–10.6 ms | Worst 11.0 and 12.8 ms in a first pass, 3.0–6.4 ms in 3 repeats |
| Viewer open and close | 97 fps, 10 missed | 98–99 fps, 10–12 missed |
| Viewer arrows | 116.6–118.4 fps, worst 7.7 ms | 116.4–117.5 fps, worst 8.3 ms once, 6.1–6.8 ms in 3 repeats |
| Memory after the scenarios | 466–505 MB | 439–634 MB |

The list's 12.8 ms and the viewer's 8.3 ms are over the 8 ms budget, once each, in a first pass, and neither came back in three repeats. The list's figure is within what was accepted at Milestone 2. Launch to the frame reached 438 ms once, over the 350 ms target.

**Detach under load:** a 3,000-file image library with thumbnails generating, forced detach and reattach twice during the grid, list and viewer scenarios. The grid held 120 fps with no missed frame and a worst frame of 2.2 ms, the list's worst was 8.3 ms, and memory was 248 MB. All 3,000 files stayed indexed, and 2,581 photos got thumbnails with none failed. Which scenarios the detaches landed in wasn't logged.

**Animation Hitches**, a 40-second recording of all processes, with the T7 library on the Retina display, final code, running scroll, viewer open and close, viewer arrows and list scroll. Launch had hitches of 92 and 33 ms in Photon, while the window moved to its display, and a 250 ms one in the Dock and WindowServer. After launch there were 5 more in about 25 seconds of scenarios. Two of them, of 8 ms, list Photon. Two of 17 ms, two frames each, list only the Dock and WindowServer, and one of those also had a single-frame hitch listing Photon. Photon's own timers in that run: scroll 119.4 fps with 2 missed, viewer open and close 100.5 fps with 11 missed, viewer arrows 117.1 fps with 1 missed, list scroll 118.4 fps with 2 missed, and a worst main-thread frame of 1.7 ms. Render-server times per frame weren't extracted this time.

What running it found, and fixed:

- **Two mount events at once crashed the process.** `getmntinfo` shares one buffer across threads, so a full test run corrupted the heap. It left three images attached, which were detached by image path.
- **A restored session selected the anchor without a current item**, because v2 sessions only stored the anchor. The migration copies the anchor to the current item.
- **Images made in the same second looked like clones**, because exFAT's serial comes from the clock. Another suite's image once made the clone test see two pairs, so it now looks for its own pair among those reported.
- **The XCUITest runner is sandboxed** and can't attach images, so `UITests/removable-media-helper.sh` does it for the runner, on one image path.
- **Restoring the viewer broke keyboard UI tests** that expect the grid, so `PHOTON_NO_VIEWER_RESTORE` starts from the grid.
- **The offline viewer said Offline twice**, in the status bar and over the photo.
- **An Instruments recording of all processes** writes about half a gigabyte a second to the temporary folder, and leaves it behind if the recording is killed or fails. Two attempts filled the disk, and a timeout around `xctrace` killed it while it was still processing.

**Writable external drives.** The app now reads a writable volume, because the indexing check above changed no byte. `photon-index scan` still refuses one, and the T7 stays read-only.

**Not verified:**

- Everything in [what simulation can't show](#removable-media-checks): a real USB failure's timing, the drive's own behavior when power goes, TCC for removable volumes, and a real failure's order of events.
- Eject on any real drive. It has never run on one, by rule, and in the user's real app the sidebar shows an eject button on the T7's folders.
- A real `didRenameVolume` reaching the app. Tests call the rename handler directly.
- A real drag while offline. Only the status message is tested.
- `FileTransferUITests`, and the Copy UI test, weren't rerun on the final code. The Copy test ran once by mistake while the zoom test was failing, and passed.
- Cold launch after a reboot, and plugged-in power.

**Not built:** Rename and Move to Trash, which must check `VolumeAccess.canModifyFiles`.

### Milestone 3 results

These are from a release build, on AC power, with the window filling the display, on both displays at 120 Hz: an external 1x display and the Retina built-in display. The T7 Touch library is 27,235 assets, read from the drive mounted read-only, and the seeded library is 100,000 items with no original files, so its viewer shows thumbnails only. Figures are 1x then Retina.

| Viewer scenario, T7 Touch | fps | Missed | Main thread p99 | Main thread worst |
|---|---|---|---|---|
| Open and close, 8 transitions | 101, 101 | 9, 10 | 0.8, 1.3 ms | 2.3, 2.1 ms |
| Arrow keys, 30 per second | 117.5, 117.1 | 1, 1 | 0.7, 0.6 ms | 5.4, 7.0 ms |
| Arrow keys, 240 per second | 118.1, 118.0 | 1, 1 | 0.2, 0.2 ms | 2.7, 2.2 ms |
| One step every half second | 119.4, 119.4 | 1, 1 | 0.5, 0.4 ms | 5.7, 5.3 ms |
| Jump of 50 every half second | 119.2, 119.2 | 3, 2 | 0.3, 0.3 ms | 1.5, 2.1 ms |
| Zoom and pan | 118.2, 118.1 | 1, 1 | 0.4, 0.4 ms | 3.2, 2.8 ms |
| Open and close from the list | 112.0, 114.0 | 4, 3 | 1.5, 1.2 ms | 2.6, 2.3 ms |

The seeded library matched these or did better, with a worst viewer frame of 4.8 ms. Grid and list scenarios stayed at their Milestone 2 figures after this work: 119.3–120 fps, with worst frames of 5.4 ms in the grid and 8.8 ms in the list.

| Time until a photo is sharp, from the T7 | Typical | Worst |
|---|---|---|
| Next photo, already preloaded | 0.05 ms | 0.24 ms |
| Jump to a photo that isn't loaded, 1x | 143 ms | 201 ms |
| Jump to a photo that isn't loaded, Retina | 95–116 ms | 254 ms |

**Animation Hitches**, viewer scenarios on the T7, Retina, final code: 9 hitches in about 60 seconds. One was 67 ms during launch, and the other 8 were single frames. Render server p50 1.6 ms, p99 4.0 ms, worst 14.7 ms, and 19 of 7,780 frames over 8 ms. An earlier trace with the same flights showed a single-frame hitch as each transition began, which is the commit of the viewer's first frame and SwiftUI's update together. The in-app count of about one missed frame per transition agrees with that. Single frames at the start of a transition were left as they are.

**Launch** is unchanged at 320–350 ms to the result and 355–390 ms to the frame after it, over 3 runs. One first run after a build took 469 ms. Opening a folder takes 24–87 ms.

**HDR**, checked on the Retina built-in display with a gain-map HEIC made for the purpose, because no gain map turned up in 450 files sampled from the T7. The display's `maximumExtendedDynamicRangeColorComponentValue` read 4.0 with the HDR photo showing and 1.0 with an SDR photo or the grid, so extended range engages only when it should. That value shows the display's state, not the picture's accuracy, and no screenshot can show extended range.

**Large selections**, all 27,235 real files: Command-C held 120 fps with no missed frame and a worst main-thread frame of 2.2 ms, and the files landed on the pasteboard in 4.0 seconds. A drag of all of them starts in 25 ms.

What running it for real found, and fixed:

- **The keyboard could be dead after launch**, until the first click. This was the cause of the `testArrowKeysMoveInTheGrid` failure seen once in Milestone 2. Focus was asked for once, a turn after the view was created, and that does nothing if the window isn't there yet. It reproduced in 2 of 12 runs, and in the same test in Shift-arrow form, and in 0 of 30 after moving it to when the view joins its window.
- **`PHOTON_WINDOW` had the same race**, so a run could silently measure the wrong window size or display. Some early runs in this milestone did, and were thrown away. The JSON's `backingScale` is worth checking on every run.
- **A drag of many files crashed.** AppKit walks large drags on worker threads, and Swift 6 traps a main-actor `isFlipped` there. No test with a small selection can see it.
- **Unsigned builds started with `open`** read nothing from the T7, with no error. Measurements must be started from a shell, which is how Milestone 2's were.
- Freeing large surfaces on the main thread cost frames of up to 10 ms. They're now released on the decoding queue.
- Reading `isViewerOpen` in `BrowserShell` rebuilt the toolbar at the start of each transition, so it moved into small views of its own.
- Screen-sized previews were scaled back down by the GPU, so they're now the size that fills the viewer.

Tested on a real screen:

- XCUITests, through the running app with real events, 14 of 14 before the zoom controls and title were added: opening with Space, Return and Command-Down, closing with Space, Escape and Command-Up, moving, zooming and panning from the keyboard, keeping the current item from grid and list, and Copy in tile, list and viewer. After those were added, the keyboard suite passed again without its Copy test, with a new test of the toolbar's zoom buttons and a Command-scroll. A plain drag of an unselected tile was then checked into a real Finder window, and one file landed. The Copy test and the drag of 24 selected files weren't rerun.
- Copy into another process: a file URL, then PNG and TIFF made on request.
- Dragging from the grid into Finder: 24 files, byte for byte, which covers the files past the 16 dragging items. `FileTransferUITests` needs a small library of real files, so it's set up by hand, and its header says how.
- Light and dark, by screenshot on the T7's real photos: fit, zoomed in, opened from the list, and a video's placeholder. The photo stays sharp at high zoom.

Tested with no display: 365 Swift Testing tests, including real key events in a window that isn't shown, progressive loading on a read-only exFAT image, and pulling that image while viewing. A pinch and a scroll are called on the viewer directly.

**Accepted:**

- The list's worst frame of 12.1 ms on the seeded 100k library, measured at Milestone 2 against the 8 ms budget. The user accepted this by merging Milestone 2, and it's recorded here because the budget rules ask for an explicit decision. It happens during list scrolling, and p99 is about 1 ms.
- Image data is limited to 4096 px, so a paste of pixels from a larger photo is smaller than the original. This limit was chosen without measuring encoding times, and may be too cautious. Finder and anything taking the file get the original.

A disk image detached while another test listed the mounts crashed the process once: a volume on its way out reported a block count too large for `Int64`. Capacity now treats an overflow as unknown, because a real drive being pulled could do the same.

**Not verified:** how the transitions look frame by frame, because window capture lags them. They're measured, and the flight has been watched only by the user, if at all. Reduce Motion's fades. Pasting into Messages and Figma themselves, as opposed to another process reading the same pasteboard. Dragging from the list or the viewer, which share the grid's code but only their preparation is tested. Real HDR photos from a camera or phone, PQ and HLG files, and HDR on an external display. RAW files. Panoramas past the size limits on a real screen. VoiceOver itself, a real trackpad swipe, and non-US keyboard layouts. How the eased scroll zoom feels on a real mouse wheel, and the direction a real wheel zooms. A real trackpad pinch works, as checked by the user. A disk image detached during a paste.

**Not built:** the viewer has no way to explain missing permission. Videos don't play until Milestone 6, and rotation isn't applied.

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

**Not verified:** a rescan of real changes on the T7 Touch, because it stayed read-only, so that's shown on disk images only. Also a remount of the T7 Touch, and a refusal of the drive when it's really mounted writable, which is covered by a unit test only. In the app, the window was checked in light and dark mode, but adding a folder through it hasn't been tried, and ad-hoc debug builds will ask again for removable volume access.

At this point `LibraryIndexer` refused any writable external volume, in the app too. Milestone 4 lifted that for the app only: see [Decisions](#decisions).

## Distribution

Releases are DMGs built by GitHub Actions on a version tag.

1. Create a self-signed code-signing certificate with a long expiry, and keep using the same one.
2. Store it as a base64-encoded GitHub secret.
3. The workflow builds, signs, creates the DMG and attaches it to a GitHub Release.

Ad-hoc signing isn't used, because permissions can be lost on each rebuild. Downloaded builds aren't notarized, so people have to approve them under System Settings → Privacy & Security → Open Anyway.

Developer ID and notarization can be added later ($99/year). That also needs the hardened runtime, with bundled libraries signed to match.

## Future feature notes

### Live Photo motion

A Live Photo is already a stack, from pairing: the photo is its cover, and its MOV of at most 4 seconds is a member. Its motion needs no new reading path, because the hover preview and the viewer already play a video through the scheduler. What's left is choosing when, and from which file:

- **In the grid**, resting on a Live Photo's tile plays its motion in the tile, through `TileVideoPreview`, with the same delay, the same stops, and Reduce Motion turning it off. It differs from a video's preview in three ways. It starts from the beginning, not the poster frame, because the motion leads up to the photo. It plays once and doesn't loop. At the end it fades back to the still, which is the photo itself and not a frame of the video, so the fade has to be real rather than a cut.
- **In the viewer**, the still shows as a photo does, at full resolution and with zoom. Motion plays once, with sound, when the viewer settles on it, as Photos does, and again on demand. That needs a key that doesn't clash: Space closes a photo, so a Live Photo needs its own, which the shortcut table must check against Photos. The player's layer sits above the picture only while the motion plays, and goes at the end, so zoom and the full-resolution still are untouched.
- **The badge** for a Live Photo stack is already on its tile. The viewer should show the same symbol, and one that plays the motion on a click.
- **Which file:** the stack member that's a video. It's in the same folder of the same volume, by the pairing rule, so it's online whenever the photo is. A Live Photo whose MOV has gone is no longer a stack after the next pairing, and shows as a plain photo.
- **Offline**, nothing plays, and the still stays, as for a video.
- **Expanded stacks** show the MOV as its own tile, which previews as a video, and the photo as a plain photo.
- **Not decided:** whether Live Photo motion has its own switch in Settings, apart from video previews. Photos has one switch for both.

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
| Our own mpv and FFmpeg build is harder than expected | Not attempted yet, and needed for the fallback, the other half of Milestone 6 |
| mpv's file access bypasses the I/O scheduler | Test `stream_cb.h` in Milestone 6. AVFoundation's is solved by `ScheduledResourceLoader` |
| Volume UUIDs change or collide without a marker file | File sampling on mount, hash-based reattachment, and separate handling of two mounted volumes with one UUID |
| First-time indexing takes tens of minutes | Priority scheduling, resumable stages, visible tiles first, one read per file |
| A slower link caps throughput | The T7 Touch linked at USB 2 speed on one connection. Worth showing in the UI if indexing is slow |
| Thumbnail cache grows too large | Size limit, with two-tier eviction |
| Drive removed during a read | No mapped reads, cancellation, forced detach of exFAT disk images and injected I/O failures. Real USB delays stay unmeasured, so errors and stalls must be handled by design |
