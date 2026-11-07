# AGENTS.md

Guidance for AI agents and contributors working on Photon, a native macOS browser for local photos and videos.

[docs/PLAN.md](docs/PLAN.md) holds the architecture, milestones and decisions. Read it before making design changes, and update it when a decision changes.

## Toolchain

- Full Xcode is required for app builds and Instruments. Command Line Tools alone aren't enough.
- Swift 6 with strict concurrency.
- Minimum deployment target: macOS 26.

Most logic belongs in `Packages/PhotonKit`, so it can be tested without launching the app:

```bash
swift test --package-path Packages/PhotonKit
```

Build the app, the same way CI does:

```bash
xcodebuild build -project Photon.xcodeproj -scheme Photon -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

`photon-index` is a development tool for measuring indexing outside the app. It prints counts, never file names:

```bash
swift run --package-path Packages/PhotonKit -c release photon-index scan <folder> --database <file>
```

`photon-index thumbnails <folder> --database <file>` makes thumbnails for a scanned folder, and `photon-index seed --database <file> --count 100000` writes a library with no real files, for measuring the grid. Point the app at one with `PHOTON_LIBRARY=<file>`, so that nothing touches the real library. `PHOTON_PERF_OUT=<file>` runs the scripted scenarios and writes their timings. `PHOTON_WINDOW=main` or `builtin` fills that display first, because a small window hides most of the cost. Pair the timings with `xcrun xctrace record --template 'Animation Hitches'`, since in-app timers can't see the render server.

The UI tests need an unlocked screen, so they aren't in CI:

```bash
TEST_RUNNER_PHOTON_UITEST_LIBRARY=<file> xcodebuild test -project Photon.xcodeproj -scheme Photon -destination 'platform=macOS'
```

Start measurements from a shell, not with `open`: an unsigned build started by Launch Services can't read a removable drive, and it fails quietly. Check `backingScale` in the output, which says which display a run really used.

`PHOTON_VIEWER_ROW=<n>` opens the viewer on a row, for looking at it with `PHOTON_SNAPSHOT=<file>`. `FileTransferUITests` also needs `TEST_RUNNER_PHOTON_UITEST_FILES_LIBRARY` and `TEST_RUNNER_PHOTON_UITEST_DROP_FOLDER`, and its header explains them.

`scan` refuses an external volume unless it's mounted read-only, and `generate` only writes to the internal disk or a disk image. Keep libraries built from a real drive out of this repository, because they contain real file names.

The tests create and mount exFAT disk images with `hdiutil`, which works without a real drive.

## Rules that must not be broken

### Disk access

- Never touch the filesystem on the main thread. A sleeping drive would freeze the UI.
- Send all reads of user media through the per-volume I/O scheduler. Reads must be cancellable.
- Never memory-map files on removable media. This includes `.mappedIfSafe` and passing a URL to `CGImageSource`. Read the bytes normally, then create the source from them.
- On `willUnmount`, cancel all work and close every file handle for that volume.

### User data

- Never write Photon's own files to a user's drive: no markers, sidecars, caches or databases.
- Originals are read-only. The only changes allowed are user-initiated rename and Move to Trash, and they all go through one file operations layer.
- Never delete or modify a file based on a sampled hash. Compare full contents first.

### Identity

- Attach favorites, albums, tags and all other organization data to `Asset`, never to a path or `FileInstance`.
- Store paths as a volume ID plus a relative path, never as absolute paths.
- Don't use bookmarks or file IDs as identity.
- Anchor sessions and scroll positions to an asset, not a pixel offset.

### Offline and read-only states

- A disconnected volume is a normal state, not an error. Every feature must define what it does offline.
- Read-only volumes are also normal. Disable actions that need writing instead of letting them fail.
- I/O errors from a removed drive must never crash the app or block the UI.

### Performance

- Decode images off the main thread. The main thread only assigns decoded images.
- Grid and list code must not do work proportional to the size of the library on any frame.
- Tiles must show something immediately: the nearest thumbnail, or the stored dominant color.
- The database has a single writer. Don't run unbounded queries on the main thread.
- Keep to the budgets in [docs/PLAN.md](docs/PLAN.md#performance-budgets). A regression needs a fix or an explicit decision.
- Release large surfaces and buffers off the main thread. Freeing one can take milliseconds.
- Don't read values that change often in `BrowserShell`'s body. That rebuilds the toolbar, so give them a small view of their own, as `StatusBar` and `SizeControl` do.

## Architecture boundaries

Dependencies point downward. `PhotonUI` must not reach around these layers to access files or SQL.

| Layer | Responsibility |
|---|---|
| `App` | Thin app target: entry point, scenes, wiring |
| `PhotonUI` | SwiftUI shell, and AppKit grid, list and viewer |
| `PhotonVideo` | `VideoEngine`, AVFoundation and fallback implementations |
| `PhotonMedia` | Decoding, thumbnails, pasteboard |
| `PhotonIndex` | Scanning, hashing, volumes, I/O scheduling |
| `PhotonCore` | Schema, models, database, migrations |

Use SwiftUI for the app shell and AppKit where large-scale performance or precise control matters. Don't replace the grid with `LazyVGrid`.

## Conventions

- Follow Apple's Human Interface Guidelines. Prefer system controls, materials, colors and SF Symbols over custom ones.
- Support light and dark mode, VoiceOver and Reduce Motion.
- Browsing, viewing, selecting and copying should work well from the keyboard. Other tasks may need the mouse.
- Keep one current item across grid, list and viewer, held as an asset rather than an index.
- Holding an arrow key must stay smooth, so never block on decoding or disk access for a skipped item.
- Check new shortcuts against the table in [docs/PLAN.md](docs/PLAN.md#keyboard-navigation) and keep it up to date.
- Every schema change needs a migration, because user libraries must survive upgrades.
- Features should work the same way in grid, list and viewer. Copy, for example, is one shared command.
- Wrap third-party libraries behind Photon's own interfaces.
- A view that starts a drag must keep `isFlipped` `nonisolated`. AppKit calls it on worker threads for large drags, and a main-actor getter crashes.

## Testing

- Use Swift Testing for logic, and cover identity, merging, volume matching and migrations thoroughly.
- Use a synthetic library generator for performance tests, so that they don't depend on personal photos.
- Never commit personal photos or videos as fixtures.
- Removable media behavior needs a physical check on a real external drive, including pulling the drive during reads.
- For UI changes, run the app and check them in both light and dark mode.
- Automate UI tests for keyboard navigation in grid, list and viewer.

## Licensing

- Use LGPL builds of FFmpeg and mpv unless the project adopts a GPL-compatible license.
- Check the license of model weights and their training data before bundling them. InsightFace's pretrained models are non-commercial research only.
