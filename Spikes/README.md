# Milestone 0 spikes

Throwaway measurement code, kept apart from the planned `Packages/PhotonKit` layout. Results and decisions live in [docs/PLAN.md](../docs/PLAN.md). Nothing here is application code.

| Directory | Spike | Run |
|---|---|---|
| `Grid/` | 1. Grid zoom and navigation | `swift build -c release`, then `./run-matrix.sh <output-prefix>` |
| `VolumeProbe/` | 3. Volume identity | `./run-image-tests.sh <scratch>`, `./run-removal-tests.sh <scratch>`, `./real-media.sh` |
| `Throughput/` | 4. Hard drive throughput | `./run-image-bench.sh <scratch>`, then `throughput bench` and `throughput device` on real media |
| `Signing/` | 5. Self-signed permission persistence | `./verify-persistence.sh <mount of a real removable volume>` |

Disk image scripts create their own images in the scratch directory you pass. Tools that take a real volume are read-only, and `real-media.sh pull` and `throughput bench` refuse a writable external mount.
