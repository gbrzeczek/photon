# Photon

A fast, native macOS browser for photos and videos in your own folders and on removable drives.

> **Status: planning.** There's no app to download yet. This README describes what Photon is being built to do. Follow progress in the [implementation plan](docs/PLAN.md).

## Why Photon

Apple's Photos app is polished, but it wants to own your library. Finder sees your folders, but it isn't built for browsing thousands of photos. Photon aims for the look and feel of Photos, working directly on the files you already have, wherever they are.

Your files stay where they are. Photon doesn't import them, and it doesn't write its own files to your drives.

## Planned features

- **Recursive browsing:** see a folder's photos together with everything in its subfolders.
- **Full view that keeps your place:** open a photo, arrow through more, and return to the same spot in the list.
- **Easy copying:** Cmd-C or the context menu, in tile, list and full view. Paste into Finder or straight into other apps.
- **Flexible viewing:** list and tile views, with smooth tile resizing.
- **Keyboard navigation:** move through the grid, list and full view with the arrow keys, with shortcuts for common actions.
- **Organization:** favorites, albums, smart albums and tags.
- **Sorting:** by date, name, size, type and duration.
- **Removable media support:** unplug a drive and still browse its thumbnails, favorites and albums. Reconnect it and carry on where you left off, even if it mounts under a different name.
- **Wide video support:** common formats through AVFoundation, and formats like MKV and WebM through a bundled fallback player.
- **Performance:** built to stay smooth on large libraries, including on an external drive.

### Later

- Grouping duplicates and similar scenes into one browsable tile
- Cloud backup of favorites
- On-device face recognition

## How it works

Favorites, albums and tags are attached to a file's content rather than its path. They survive renames, moves, and even copying a library to a new drive.

The library database and thumbnails live on your Mac, which is why a disconnected drive stays browsable. See the [architecture notes](docs/PLAN.md#architecture) for details.

**Built with:** Swift 6, SwiftUI, AppKit, AVFoundation, Vision, and SQLite through GRDB.

## Roadmap

1. Technical spikes for grid zooming, video, and volume identity
2. Indexing foundation
3. Grid and list views
4. Full view and copying
5. Removable media
6. Favorites, albums and tags
7. Video
8. Polish and first release

See [milestones](docs/PLAN.md#milestones) for the full list.

## Installation

There's no release yet. The plan is to publish DMGs on GitHub Releases, for macOS 26 or later.

These builds will be self-signed, not notarized by Apple, so macOS will block the first launch. To open one, try launching Photon, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Contributing

[AGENTS.md](AGENTS.md) describes the project's rules and conventions, for both people and AI agents.

## License

To be decided.
