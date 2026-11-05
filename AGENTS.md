# AGENTS.md

Guidance for AI agents and contributors working on Photon, a native macOS browser for local photos and videos.

The project is in planning, and no application code exists yet. [docs/PLAN.md](docs/PLAN.md) holds the architecture, milestones and decisions. Read it before making design changes, and update it when a decision changes.

## Toolchain

- Full Xcode is required for app builds and Instruments. Command Line Tools alone aren't enough.
- Swift 6 with strict concurrency.
- Minimum deployment target: macOS 26.

Build and test commands will be added here once Milestone 1 creates the project. Most logic belongs in `Packages/PhotonKit`, so it can be tested with `swift test` without launching the app.

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
