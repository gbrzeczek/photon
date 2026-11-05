# Spike 2: libmpv embedding results

Measured on 2026-11-05. M4 Max, macOS 27.0.1, Xcode 27.2, built-in Retina display at 120 Hz. libmpv came from MPVKit 1.0.0's LGPL product: mpv 0.41.0 (with MPVKit's patches), FFmpeg n8.1.2, libplacebo 7.360.1, MoltenVK 1.4.2.

## Recommendation

**libmpv embedding works, so VLCKit isn't needed. Use Path A (render API with OpenGL in a `CAOpenGLLayer`) behind `VideoEngine`, and keep Path B as the exit if Apple removes OpenGL. Don't ship MPVKit's binaries. Plan on our own LGPL build of mpv and FFmpeg.**

- **Why Path A:** it uses mpv's public render API with no out-of-tree patch, and resizes correctly without workarounds. It also uses about 105 MB less memory on average and needs neither MoltenVK nor shaderc.
- **Why not Path B yet:** it relies on a `moltenvk` context that exists only as an MPVKit patch, and that context can't handle a window resize.
- **The price of Path A:** OpenGL is deprecated, and Path A gets no real vsync feedback (see [Frame timing](#frame-timing)). Fixing Path B's resize needs a patched mpv, which our own build would make possible.
- **Why not MPVKit:** three separate reasons, in [Shipping](#shipping).

## Matrix

Each clip played in one window at 1280×720 points (2560×1440 pixels): play 3 s, resize down and back, exact seek to 50%, seek back, pause, capture, then load the next file while the previous one was still playing. Path B used its `transform` resize mode. Audio was a real AVFoundation output at volume 0. All 18 runs succeeded.

| Clip | Codec | `hwdec-current` | `estimated-vf-fps` | Drops A / B | Load ms A / B | Exact seek ms A / B | Footprint MB A / B | Worst main stall ms A / B | SSIM true / wrong A | SSIM true / wrong B |
|---|---|---|---|---|---|---|---|---|---|---|
| av1-1080p30.webm | av1 | videotoolbox | 30.00 | 0 / 0 | 154 / 206 | 449 / 450 | 452 / 540 | 7.8 / 7.7 | 0.936 / 0.862 | 0.962 / 0.907 |
| flv1-640x360.flv | flv1 | no | 30.00 | 0 / 0 | 61 / 68 | 58 / 65 | 395 / 523 | 10.9 / 5.4 | 0.952 / 0.807 | 0.955 / 0.808 |
| h264-1080p30.mkv | h264 | videotoolbox | 30.00 | 0 / 0 | 114 / 107 | 1216 / 1157 | 567 / 636 | 5.1 / 6.1 | 0.922 / 0.734 | 0.923 / 0.734 |
| hevc10-4k60.mkv | hevc | videotoolbox | 60.00 | 0 / 0 | 98 / 103 | 174 / 175 | 774 / 815 | 7.7 / 5.1 | 0.950 / 0.912 | 0.947 / 0.910 |
| mpeg2-1080p30.ts | mpeg2video | no | 30.00 | 0 / 0 | 75 / 71 | 61 / 68 | 662 / 780 | 6.9 / 5.4 | 0.927 / 0.743 | 0.927 / 0.743 |
| mpeg4-720p30.avi | mpeg4 | no | 29.67 | 0 / 0 | 61 / 65 | 63 / 72 | 651 / 783 | 5.4 / 5.9 | 0.924 / 0.744 | 0.926 / 0.747 |
| prores-1080p30.mov | prores | videotoolbox | 30.00 | 0 / 0 | 155 / 156 | 58 / 64 | 872 / 1000 | 8.8 / 5.5 | 0.928 / 0.747 | 0.929 / 0.747 |
| vp9-1080p30.webm | vp9 | videotoolbox | 30.00 | 0 / 0 | 105 / 100 | 126 / 145 | 884 / 1007 | 5.9 / 6.0 | 0.963 / 0.912 | 0.962 / 0.912 |
| wmv2-720p30.wmv | wmv2 | no | 30.00 | 0 / 0 | 61 / 60 | 95 / 89 | 692 / 827 | 5.6 / 5.7 | 0.931 / 0.775 | 0.932 / 0.774 |

How to read it:

- **Drops** adds `frame-drop-count`, `decoder-frame-drop-count` and `vo-delayed-frame-count`. Seeking resets these counters, so the total covers play plus resize, then the time after the seek, as two samples.
- **`mistimed-frame-count`** isn't in this table because mpv only reports it in display-sync mode. It's covered under Frame timing.
- **Load** is the time from `loadfile` to the first `playback-restart`.
- **Exact seek** is long for H.264 and AV1 because these clips have one keyframe in about 8 s. Expect shorter seeks on real camera files.
- **Footprint** is `phys_footprint` after the seek. It depends on clip order, because earlier clips' buffers stay allocated. Compare the two paths, not the rows. mpv's demuxer cache limits were left at their defaults.
- **Software decode** (`no`) is expected for MPEG-2, MPEG-4, WMV2 and FLV1. Their `hwdec-current` matched on both paths. AV1 and VP9 hardware decode are specific to this M4 Max, and older Macs may fall back to software.
- **Clips:** all nine requested clips were generated. There were none I couldn't make.

## Pixels on screen

Pixels really do reach the screen on both paths.

- **Path A:** `glReadPixels` from the layer's framebuffer, plus a `screencapture -l` window capture.
- **Path B:** window capture only. There is no readback on this path.
- **Check:** each capture, taken while paused, was compared with a frame decoded independently by Homebrew ffmpeg. All 18 scored higher against the true frame than against one a second away. The margin is narrow on the low-noise VP9 and 4K HEVC clips (about 0.04–0.05), which makes those two the weakest evidence.
- **Offset:** AVI, FLV and ASF clips matched one frame before `time-pos × fps`, identically on both paths. That points at timestamp mapping in those containers, not at either renderer. I didn't investigate it further.

SSIM measures structure. It wouldn't have caught the color problem below, which was found by looking at the captures and then sampling them.

## Path differences

### Resize

| Mode | Result at 1600×900 pixels |
|---|---|
| Path A | Correct. `osd-dimensions` follows the window |
| Path B, no workaround | **Cropped:** 3.75 of 6 test bars, and `osd-dimensions` stays 2560×1440 |
| Path B, `video-aspect-override` nudge | Partly cropped. Lags at 2026×1140 and changes the aspect ratio by 1 pixel, so rejected |
| Path B, Core Animation transform | Correct picture, with mpv still rendering 2560×1440 |

MPVKit's `context_moltenvk.m` patch only reads `drawableSize` in `reconfig`, and its `control` hook returns `VO_NOTIMPL`, so mpv never hears about a resize. MPVKit's macOS demo has no workaround. The `transform` mode wastes GPU work at small sizes, and as written it would stretch any window that isn't 16:9. A proper fix looks like a small patch to that context, but I didn't build or test one.

mpv's upstream `gpu-context=macvk` with `wid` set to an `NSView*` isn't an alternative. In this build it left our view empty and opened a second window.

Resizing here means `setFrame` steps at about 60 Hz, not a real mouse drag.

### Frame timing

With the default `video-sync=audio`, both paths reported zero drops, and Path A's draw count matched the clip (about 222 draws at 30 fps, 439 at 60 fps). Path B has no equivalent draw count. mpv's counters only describe mpv's own view, so **on-screen frame pacing is unverified on both paths.**

With `video-sync=display-resample` and `override-display-fps=120`, on three clips (H.264, HEVC 10-bit, MPEG-4), counters ranged as follows:

| Counter | Path A | Path B |
|---|---|---|
| `mistimed-frame-count` | 10–222 | 0–2 |
| `frame-drop-count` | 4–50 | 0–1 |
| `vo-delayed-frame-count` | 6–269 | 0–1 |
| `estimated-display-fps` | 198–757 | 119.5–120.0 |

Only Path B gets real vsync feedback. Path A's `draw` returns without blocking on a swap, so mpv can't see the display, and display-sync isn't usable there. Default audio sync doesn't need it. A display-link-driven Path A might do better, but I didn't try one.

### Color

Path A needs `colorspace = sRGB` on the layer. The red bar sampled from a capture on the P3 panel:

| Setup | RGB |
|---|---|
| Path A, tagged | `ea3a25` |
| Path A, untagged | `ff1803`, visibly oversaturated |
| Path B | `ea3a25` |

Path B's layer settled on pixel format 94 (BGR10A2). I read Path A back as 8-bit RGBA, so its framebuffer depth wasn't checked. HDR wasn't tested on either path.

### When the window can't be seen

The screen locked itself partway through testing, which gave an unplanned test. Core Animation stops calling `draw` on Path A while the display is asleep, so nothing may wait on a draw (my first readback hung forever for this reason). Path A then drew 16 times and mpv counted 72 drops, and playback carried on. Path B kept going, with 0–1 drops.

## Teardown

| Test | Path A | Path B |
|---|---|---|
| 45 loads, one core, with `stop` every fifth load | 0 failed, no crash | 0 failed, no crash |
| 30 full surface and core rebuilds, every third while the file is still loading | 0 failed, no crash | 0 failed, no crash |
| Footprint across rebuilds, first → last (peak) | 574 → 434 MB (823) | 811 → 356 MB (896) |
| Teardown after the matrix | 248 ms | 50 ms |

Neither path shows steady growth. The order is `mpv_render_context_free` with the GL context current, then `mpv_terminate_destroy`.

Two Path A bugs along the way were mine, and they're traps for the real engine. Not releasing the CGL context looked like a 35 MB leak per rebuild. Releasing it in `freeRender` then crashed in `CAOpenGLLayerDraw`, because Core Animation can still display the layer after mpv is gone. The context must be released in the layer's `deinit`.

## Shipping

### Why MPVKit's binaries can't ship

1. **LGPL isn't met as linked.** On macOS its xcframeworks are static `ar` archives, so mpv and FFmpeg are compiled into our executable (`mpv_render_context_create` is a symbol in it, and `otool -L` lists no libmpv). LGPL generally requires that users can relink against a modified library, which normally means dynamic linking or supplying object files. Photon has no LICENSE yet, and that choice affects how this applies. This needs a proper license review. I'm not claiming compliance.
2. **It misses formats the fallback exists for.** FFmpeg is built from an allow-list. Missing decoders: `msmpeg4v1/v2/v3` (DivX 3), `dvvideo`, `cinepak`, `dnxhd`, `theora`, `vp3`, `indeo3`, `indeo4`, `msvideo1`, `qtrle`, `svq1`. Missing demuxers: `mxf`, `nut`, `wtv`, `ivf`.
3. **Its README says not to rely on it:** "only suitable for learning `libmpv`", not maintained often.

What's confirmed about licensing: `avcodec_license()` returns `LGPL version 3 or later` (so LGPLv3, not 2.1), the configuration has `--enable-version3` with no `--enable-gpl` or `nonfree`, mpv was built with `-Dgpl=false`, and no x264, x265 or Samba symbols are in the binary. mpv reports `v0.41.0-dirty` and MPVKit patches it, so modified source would need to be offered. I didn't audit the license of every other bundled library.

### What our own build needs

- mpv and FFmpeg as signed dylibs or frameworks in `Contents/Frameworks`, built with the decoders above. MPVKit's build scripts are a possible starting point. Not attempted.
- Lua disabled, plus no network or TLS stack. All of these are linked now but unused by a local app: GnuTLS, LuaJIT, libbluray.
- MoltenVK and shaderc only if Path B ships. shaderc alone is a 34 MB archive.
- **Size today:** 32.8 MB stripped, 14.4 MB gzipped, for one arm64 executable with everything linked. A dylib layout and x86_64 weren't measured. The SwiftPM download is 1.7 GB, because it fetches every platform and the GPL variants.

### Signing

Plain ad-hoc signing without hardened runtime runs fine. That's the closest I tested to the self-signed plan. **If hardened runtime is adopted later for Developer ID,** mpv's default setup is killed at launch (`SIGKILL (Code Signature Invalid)`). Its built-in Lua scripts start even with `load-scripts=no`, and LuaJIT writes executable pages.

| Hardened runtime setup | Result |
|---|---|
| Default | Killed |
| `allow-jit` | Killed |
| `allow-unsigned-executable-memory` | Runs |
| `disable-executable-page-protection` | Runs |
| All built-in `load-*` scripts off, no entitlement | Runs on both paths |

The `allow-jit` and memory rows are startup probes with no playback. The last row played clips, but with the screen locked, so it shows the process survives, not that pixels reached the screen. All of this was ad-hoc signing, not a real certificate or notarization.

### Other things the engine must handle

- **Silent video failure.** With a missing decoder and an audio track, mpv plays audio only and raises no error. Only `video-codec` being empty shows it, so `VideoEngine` must check that and report the file as failed. A video-only file does end with an error. No crash in either case.
- **Audio output.** `ao=coreaudio` fails with -50 on planar `floatp` here, and mpv's default probing then falls back to AVFoundation. Set `ao=avfoundation` directly, or `audio-format=float` to keep CoreAudio. Actual sound wasn't checked, because all runs were at volume 0.
- **Rule conflict with AGENTS.md.** mpv opens and reads files itself, which bypasses the per-volume I/O scheduler and its cancellation. `stream_cb.h` is in the headers and may be the way to route reads, but I haven't tested it. Pulling a drive during playback is also untested.
- **Blocking calls.** Keep every mpv call off the main thread. The worst main-thread stall measured was 15 ms with those calls off it.
- **Noise.** Set `MVK_CONFIG_LOG_LEVEL`, or MoltenVK prints every extension to stdout.
- **No PNG encoder.** `screenshot-to-file` fails in MPVKit's FFmpeg. mpv screenshots can't be used for thumbnails without a custom build.

## Not verified

- On-screen frame pacing, on either path.
- Real mouse-drag live resize, fullscreen, and moving a window between displays. The matrix ran on the built-in display. One H.264 clip ran incidentally on the 1× external display.
- Non-16:9 video or windows.
- HDR, subtitles, audible output and long playback.
- Real camera files. All clips are synthetic, 10 s long, and noisy, so bitrates are unusually high and keyframes are far apart.
- Removable media, including pulling a drive during playback.
- Building mpv and FFmpeg ourselves, dylib linking, signing with a real certificate, and x86_64.
- Older Macs and macOS 26.

MPVKit has a newer tag, `1.1.0-n9.0.2`, which wasn't tested.

## Run it

```bash
swift build -c release
./make-clips.sh <scratch>/clips
MPV_SPIKE_AO=avfoundation LOCK=<lock-file> ./run-one.sh 220 matrix --path a --clips <scratch>/clips --out <scratch>/run/a
MPV_SPIKE_AO=avfoundation LOCK=<lock-file> ./run-one.sh 220 matrix --path b --resize transform --clips <scratch>/clips --out <scratch>/run/b
MPV_SPIKE_AO=avfoundation LOCK=<lock-file> ./run-one.sh 150 churn --path a --clips <scratch>/clips --out <scratch>/run/churn-a --loads 45 --rebuilds 30
./compare.sh <scratch>/clips <scratch>/run/a
```

`mpv-spike probe --path a` prints versions, the FFmpeg license and configuration, and missing decoders. `--path c` is the rejected `macvk` test. Runs use a floating window that doesn't take focus, and generated media stays out of the repo.
