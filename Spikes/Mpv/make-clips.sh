#!/bin/bash
# Generates the synthetic test set with ffmpeg. Never commit the output.
# Usage: make-clips.sh <output-dir> [seconds]
set -u
OUT="${1:?output dir}"; D="${2:-10}"
mkdir -p "$OUT"
have() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE " $1 "; }
src() { echo "testsrc2=s=$1:r=$2:d=$D,noise=alls=10:allf=t"; }
aud="sine=frequency=440:duration=$D:sample_rate=48000"
mk() {
  local name="$1" enc="$2"; shift 2
  if ! have "$enc"; then echo "SKIP $name: no encoder $enc"; return; fi
  if ffmpeg -hide_banner -loglevel error -y "$@" "$OUT/$name"; then
    echo "OK   $name $(stat -f %z "$OUT/$name") bytes"
  else
    echo "FAIL $name"; rm -f "$OUT/$name"
  fi
}
mk h264-1080p30.mkv libx264 -f lavfi -i "$(src 1920x1080 30)" -f lavfi -i "$aud" \
  -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -c:a aac -b:a 128k
mk hevc10-4k60.mkv libx265 -f lavfi -i "$(src 3840x2160 60)" -f lavfi -i "$aud" \
  -c:v libx265 -preset ultrafast -crf 22 -pix_fmt yuv420p10le -profile:v main10 -tag:v hvc1 -x265-params log-level=error -c:a aac -b:a 128k
mk vp9-1080p30.webm libvpx-vp9 -f lavfi -i "$(src 1920x1080 30)" -f lavfi -i "$aud" \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 7 -row-mt 1 -b:v 8M -pix_fmt yuv420p -c:a libopus -b:a 96k
mk av1-1080p30.webm libsvtav1 -f lavfi -i "$(src 1920x1080 30)" -f lavfi -i "$aud" \
  -c:v libsvtav1 -preset 10 -crf 32 -pix_fmt yuv420p -c:a libopus -b:a 96k
mk mpeg4-720p30.avi mpeg4 -f lavfi -i "$(src 1280x720 30)" -f lavfi -i "$aud" \
  -c:v mpeg4 -q:v 4 -pix_fmt yuv420p -c:a libmp3lame -b:a 128k
mk wmv2-720p30.wmv wmv2 -f lavfi -i "$(src 1280x720 30)" -f lavfi -i "$aud" \
  -c:v wmv2 -q:v 5 -pix_fmt yuv420p -c:a wmav2 -b:a 128k
mk mpeg2-1080p30.ts mpeg2video -f lavfi -i "$(src 1920x1080 30)" -f lavfi -i "$aud" \
  -c:v mpeg2video -q:v 4 -pix_fmt yuv420p -c:a mp2 -b:a 192k
mk flv1-640x360.flv flv -f lavfi -i "$(src 640x360 30)" -f lavfi -i "$aud" \
  -c:v flv -q:v 4 -pix_fmt yuv420p -c:a libmp3lame -ar 44100 -b:a 128k
mk prores-1080p30.mov prores_ks -f lavfi -i "$(src 1920x1080 30)" -f lavfi -i "$aud" \
  -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -c:a pcm_s16le
ffmpeg -hide_banner -encoders 2>/dev/null | grep -E " (libmp3lame|libopus|wmav2|mp2|aac) " | awk '{print "audio encoder:", $2}'
