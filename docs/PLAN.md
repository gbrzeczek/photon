# Photon implementation plan

Photon is a native macOS browser for photos and videos stored in local folders and on removable media. This document records the product scope, architecture, milestones and open risks.

**Status:** Milestone 0 in progress. No application code exists yet. Spike code lives in [`Spikes/`](../Spikes/README.md), and results are under [Milestone 0 spikes](#milestone-0-spikes).

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
| Grid | Recycled `CALayer` grid in a viewport-fixed host view, inside `NSScrollView` | Spike 1: it held 120 fps through continuous zoom, and `NSCollectionView` fell to 32–94 fps even with no decoding |
| Database | SQLite through GRDB, in WAL mode, with a single writer | Needs control over queries, indexes and migrations |
| Asset identity | Content hash, not path | Favorites survive renames, moves, remounts and drive changes |
| Library location | Internal disk, in Application Support | Disconnected drives stay browsable, and nothing is written to them |
| Drive writes | None of Photon's own files. Only user-initiated rename and Move to Trash | User preference |
| Originals | Read-only. Rotation is non-destructive and stored in the database | User preference. Also keeps content hashes stable |
| Offline favorites | Standard thumbnails only | Can be extended later without a schema redesign |
| Video | AVFoundation first, with a libmpv fallback, behind one interface | Best native playback, plus wide format coverage. Spike 2 is still open |
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

1. Read the volume UUID from DiskArbitration and look for a matching `volumes` row.
2. Check a sample of indexed files by relative path, size and modified time. This catches a card that was reused, or a clone that has since diverged.
3. If the sample matches, bring the volume online and restore its sessions.
4. If it doesn't, treat it as a new volume. Assets reattach as files are hashed.
5. Rescan incrementally, skipping files whose path, size and modified time are unchanged.

Rules that follow from this:

- Paths are stored relative to the volume root, because mount paths change (`/Volumes/Foo 1`).
- Bookmarks and file IDs are not used for identity. Bookmarks have been reported to break on exFAT. exFAT and FAT32 file IDs survive remounts, renames and moves on disk images, but they are reused for unrelated files after a delete, and exFAT IDs behaved like start clusters.
- A byte-for-byte clone is indistinguishable from its original: same UUID, file IDs, sizes and dates. It's harmless when mounted alone, because it is the same content. When two volumes with one UUID are mounted together, Photon must keep them apart by BSD name for the session, and must not bring a second copy online as the same `volumes` row.
- Don't use `URLResourceKey.volumeUUIDStringKey` for identity. On FAT32 it returned a different UUID for a second mount of a clone, while DiskArbitration stayed stable.
- On `willUnmount`, cancel all work and close every file handle so that ejecting succeeds. An open handle does block the unmount. `willUnmount` also fires before an unmount that then fails, so if no `didUnmount` follows, the volume is still mounted and work must resume.
- Reads on removable media must not be memory-mapped, because pulling the drive during a mapped read crashes the process (SIGBUS confirmed on a disk image). Ordinary reads return `EIO` immediately. Load bytes with ordinary reads and hand them to `CGImageSource`.
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

First-time indexing should take around 1–2 hours per 100k photos on the hard drive. That is still a projection, because the real drive hasn't been measured (see [Spike 4](#spike-4-hard-drive-throughput)). The app must stay fully usable throughout.

Enumeration is not the bottleneck: `getattrlistbulk` was about 23 times faster than `FileManager`. Seeks are, so reads for one file should be combined where possible, and the hash's head chunk can come from the same read as metadata and the embedded preview.

### Thumbnails and memory

- Two stored sizes, set during Milestone 2, in pack files on the internal disk with offsets in the database.
- Every tile shows the nearest available size at once, then upgrades.
- Decoding happens off the main thread. The main thread only assigns decoded images.
- Decoded thumbnails are IOSurfaces assigned to `CALayer.contents`. Assigning a `CGImage` cost the main thread up to about 0.7 ms per thumbnail during commit, and tagging it sRGB didn't help. IOSurfaces cut main-thread p95 during scrolling from 5.7 ms to 1.5 ms.
- The main thread takes a bounded batch of decoded thumbnails per frame, so that a backlog can't flood it.
- During fast scrolling, tiles show the stored dominant color and skip decoding.
- The rough cost is 2–5 GB per 100k photos, so a large drive could use 25 GB or more.
- The cache has a size limit. Small thumbnails are kept for every asset, and large ones are evicted first, with favorites last.

### Grid and list

- Grid and list share one data source and selection model.
- A query result is a compact array of row IDs, and rows load in pages as they're needed.
- Tile size is continuous, through a slider, pinch and Cmd-plus or Cmd-minus. The tile under the cursor stays anchored vertically, to within 0.25 pt in Spike 1. When the column count changes it can jump sideways by most of the window width (up to about 780 pt), so Milestone 2 has to design that transition.
- Layouts are square and aspect-ratio. A full aspect-ratio pass over 200k items takes 0.5–1.5 ms. That fits the frame budget but breaks the rule against per-frame work proportional to the library, so during a zoom gesture Milestone 2 must lay out only around the anchor, and finish the full pass off the main thread.
- Tile layers use coordinates relative to a coarsely moving base, and never document coordinates, which reach tens of millions of points.
- Accessibility, hit testing, selection, drag source, context menus and focus rings are hand-built, since `CALayer` provides none of them.
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
Spikes/              Milestone 0 measurement code, not part of the app
Packages/PhotonKit/
  PhotonCore         Schema, models, database, migrations
  PhotonIndex        Scanning, hashing, volumes, I/O scheduling
  PhotonMedia        Decoding, thumbnails, pasteboard
  PhotonVideo        VideoEngine and its implementations
  PhotonUI           Grid, list, viewer, sidebar
docs/                Project documentation
```

## Performance budgets

These are targets for an M4 Max. Spike 1 measured the grid on a synthetic library of 200k items at 120 Hz, on battery power, with scripted input. The rest are unmeasured until Milestone 2.

| Measure | Target | Measured |
|---|---|---|
| Launch to usable window with last session | Under 300 ms | Not yet |
| Open an indexed 100k folder | Under 200 ms | Not yet |
| Scrolling and zooming | Steady 120 fps | 120 fps from the display link. Instruments reported 21 single-frame hitches in about 18 seconds (1% of frames) |
| Main thread time per frame | Under 8 ms, so that a frame is never at risk | Worst p99 5.5 ms, worst single frame 6.6 ms |
| Render server time per frame | Under 8 ms | p99 6.3 ms, 3 of 2,284 frames over budget |
| Holding an arrow key in grid, list or viewer | Keeps up with key repeat, with no dropped frames | Grid: no missed frames at 30 and at 240 key events per second. List and viewer not yet |
| App memory in normal use | Under 1.5 GB | About 240–420 MB, with up to 1,500 thumbnails cached |

The spike's in-app timers reported no missed frames in the same scenarios where Instruments found these hitches. Don't rely on the in-app numbers alone.

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

| # | Spike | State |
|---|---|---|
| 1 | Grid zoom and navigation | Decided: `CALayer` grid. Real trackpad and VoiceOver checks remain |
| 2 | libmpv embedding | Open, in progress |
| 3 | Volume identity | Disk images done. Real hard drive and SD cards not tested |
| 4 | Hard drive throughput | Tool done and validated. Real hard drive not tested |
| 5 | Signing | Mechanism confirmed. Permission prompt not tested, needs real media |

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

Open. A separate session is working on this. A MPVKit build was blocked by a permission check, so the choice of dependency is waiting on a decision. The AVFoundation and libmpv plan stands, and VLCKit remains the backup.

#### Spike 3: Volume identity

Run on disk images. `hdiutil detach -force` stands in for a pulled cable, so it shows what a process sees, not the delays of a real USB failure.

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

**Still needed on the real drive and SD cards:** UUID stability across reconnects and ports, whether the USB bridge reports the medium as rotational (needed to pick the hard drive I/O policy, and disk images report nothing), real pull behavior, and how long a failing read can block. FAT32 stores local time, so modified times could shift when the time zone changes. That would affect the file sample in step 2, and it hasn't been tested.

#### Spike 4: Hard drive throughput

The tool is built and validated, but **there are no hard drive numbers yet**. Measured on an exFAT disk image on the internal SSD, with 1,500 synthetic 17 MP JPEGs of about 7 MB and a 65,000-file tree. Because the host caches the image, these rates say nothing about a hard drive beyond CPU cost and read counts.

| Stage | Reads per file | Data per file | Measured here |
|---|---|---|---|
| Enumerate, `getattrlistbulk` | About one per directory | None | 0.9 s per 100k files |
| Enumerate, `FileManager` | | None | 20.8 s per 100k files |
| Sampled hash | 3 | 192 KB | CPU cost negligible |
| Metadata from a prefix | 1 | 256 KB | No failures |
| Embedded thumbnail from a prefix | 1 | 512 KB | No failures, but synthetic previews are small |
| Full decode to 512 px | 1 | 7.1 MB | 33 ms of CPU per file, 6.4 times faster on 8 threads |

**Projection, not a measurement.** Assuming 10 ms per seek and 120 MB/s:

| Stage | Hours per 100k photos |
|---|---|
| Metadata and embedded preview, one 512 KB read | About 0.4 |
| Sampled hash, 3 seeks | About 0.9 |
| Full decode, when no usable preview exists | About 2 |

If most files have no usable preview, hashing plus full decodes comes to about 3 hours, above the 1–2 hours from combining the first two rows. Camera previews need checking too: Photon needs two thumbnail sizes, and small EXIF thumbnails may not cover the larger one.

`throughput device` measures the drive's real sequential speed and seek rate. `throughput bench --order fileid` tests one idea that the disk image can't: on exFAT, sorting reads by file ID may follow on-disk order and cut seeks. That would be a read-order hint only, never identity.

#### Spike 5: Signing

- **Confirmed:** a self-signed certificate gives a designated requirement of bundle identifier plus certificate, which stayed identical across rebuilds with different binaries. Ad-hoc signing gives a `cdhash` requirement, which changed on every build. TCC should therefore keep a self-signed app's grant, and this explains the plan's reason for avoiding ad-hoc signing.
- **Confirmed:** `codesign` works with an untrusted certificate when given its SHA-1 hash and keychain, so CI doesn't need to trust it. Local builds ran, even though `spctl` rejects them.
- **Not confirmed:** that the removable-volume grant actually persists. Disk images aren't gated by TCC at all: a probe listed one with no prompt. This needs a real card or USB drive and one click on Allow, using `Spikes/Signing/verify-persistence.sh`.

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
| libmpv embedding is unstable | Spike 2, open, with VLCKit as backup |
| Volume UUIDs change or collide without a marker file | File sampling on mount, hash-based reattachment, and separate handling of two mounted volumes with one UUID |
| First-time indexing is slow on the hard drive | Priority scheduling, resumable stages, visible tiles first, combined reads. Spike 4 needs the real drive |
| Self-signed permission doesn't persist | Requirement is stable, but the prompt is untested. Check on real media before relying on it |
| Thumbnail cache grows too large | Size limit, with two-tier eviction |
| Drive removed during a read | No mapped reads, cancellation, physical drive-pull tests |
