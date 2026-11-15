#!/bin/bash
# Writes the fallback's format test set: short synthetic clips in the containers and codecs only mpv
# plays, for the tests and for `photon-index videos`.
#
#   scripts/mpv/make-test-clips.sh [output-dir]
#
# The clips are committed, because CI has no FFmpeg to make them, and they're small: FFmpeg's moving
# test pattern, mostly at 320x240 for two seconds. Nothing in them comes from a camera. Any FFmpeg with
# these encoders works, such as Homebrew's. It's only a tool here, and nothing of it ships.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/Packages/PhotonKit/Sources/PhotonTestSupport/FallbackClips}"
mkdir -p "$OUT"

command -v ffmpeg >/dev/null || { echo "error: ffmpeg is missing. brew install ffmpeg" >&2; exit 1; }

video="testsrc2=size=320x240:rate=25:duration=2"
audio="sine=frequency=440:sample_rate=48000:duration=2"

clip() {
    local name="$1"
    shift
    echo "$name"
    ffmpeg -hide_banner -loglevel error -y "$@" -fflags +bitexact -flags:v +bitexact -map_metadata -1 "$OUT/$name"
}

clip h264.mkv -f lavfi -i "$video" -f lavfi -i "$audio" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -g 25 -c:a libopus -b:a 32k -metadata creation_time=2024-05-01T12:30:00Z
clip vp9.webm -f lavfi -i "$video" -f lavfi -i "$audio" -c:v libvpx-vp9 -b:v 200k -g 25 -c:a libopus -b:a 32k
# VP9 in MP4, which AVFoundation opens as one of its own formats and can't decode, so mpv takes it.
clip vp9.mp4 -f lavfi -i "$video" -c:v libvpx-vp9 -b:v 200k -g 25
clip vp8.webm -f lavfi -i "$video" -c:v libvpx -b:v 200k -g 25
clip av1.mkv -f lavfi -i "$video" -c:v libaom-av1 -cpu-used 8 -b:v 200k -g 25
clip mpeg4.avi -f lavfi -i "$video" -f lavfi -i "$audio" -c:v mpeg4 -q:v 5 -g 25 -c:a libmp3lame -b:a 64k
clip divx3.avi -f lavfi -i "$video" -c:v msmpeg4 -q:v 5 -g 25
clip wmv2.wmv -f lavfi -i "$video" -f lavfi -i "$audio" -c:v wmv2 -q:v 5 -g 25 -c:a wmav2 -b:a 64k
clip flv1.flv -f lavfi -i "$video" -c:v flv -q:v 5 -g 25
clip mpeg2.mpg -f lavfi -i "$video" -f lavfi -i "$audio" -c:v mpeg2video -q:v 5 -g 12 -c:a mp2 -b:a 64k
clip h264.mts -f lavfi -i "$video" -f lavfi -i "$audio" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -g 25 -c:a aac -b:a 64k -f mpegts
clip theora.ogv -f lavfi -i "$video" -c:v libtheora -q:v 5 -g 25
# DV is NTSC's 720x480 with 4:3 pixels that aren't square, so it also checks the display aspect. Its
# bitrate is fixed and high, so this clip is short.
clip ntsc.dv -f lavfi -i "testsrc2=size=720x480:rate=30000/1001:duration=0.5" -c:v dvvideo -pix_fmt yuv411p \
    -aspect 4:3 -f dv
# DNxHR in MXF, as editing software writes it.
clip dnxhr.mxf -f lavfi -i "testsrc2=size=640x360:rate=25:duration=1" -c:v dnxhd -profile:v dnxhr_lb \
    -pix_fmt yuv422p -f mxf
# A Matroska file with sound and no picture. mpv plays the sound and raises no error, so the
# fallback has to call it unsupported itself.
clip audio-only.mkv -f lavfi -i "$audio" -c:a libopus -b:a 32k

ls -l "$OUT"
