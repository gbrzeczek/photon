# Milestone 0 spikes

Throwaway measurement code, kept apart from the planned `Packages/PhotonKit` layout. Results and decisions live in [docs/PLAN.md](../docs/PLAN.md). Nothing here is application code.

| Directory | Spike | Run |
|---|---|---|
| `Grid/` | 1. Grid zoom and navigation | `swift build -c release`, then `./run-matrix.sh <output-prefix>` |
| `VolumeProbe/` | 3. Volume identity | `./run-image-tests.sh <scratch>`, `./run-removal-tests.sh <scratch>`, `./real-media.sh` |
| `Throughput/` | 4. External drive throughput | `./run-image-bench.sh <scratch>`, then `throughput bench` and `throughput device` on real media |
| `Mpv/` | 2. libmpv embedding | `swift build -c release`, then the steps in `RESULTS.md` |
| `Signing/` | 5. Self-signed permission persistence | `./verify-persistence.sh <mount of a real removable volume>` |

Disk image scripts create their own images in the scratch directory you pass. Tools that take a real volume are read-only, and `throughput bench` refuses a writable external mount. Physical pulls are no longer part of testing, so `real-media.sh pull` is gone. See [Removable media checks](../docs/PLAN.md#removable-media-checks).
