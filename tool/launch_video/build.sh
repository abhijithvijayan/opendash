#!/usr/bin/env bash
# Renders the launch video from the app itself: every frame through the
# Flutter test renderer, then ffmpeg for the encode and the music.
#   tool/launch_video/build.sh            the full video
#   tool/launch_video/build.sh --stills   three stills per scene, for a look
#   tool/launch_video/build.sh --thumbnails  1280x720 thumbnails, one per look
#   tool/launch_video/build.sh --reel     the vertical cut for Shorts and Reels (--reel --stills for a look)
# The music is not in the repository: OPENDASH_VIDEO_MUSIC, or the default below.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/launch_video
name=opendash-launch
reel=false
music_from=0
if [[ "${1:-}" == "--reel" ]]; then
  shift
  reel=true
  out=build/launch_video/reel
  name=opendash-reel
  # The reel starts where the track is already full, on a beat.
  music_from=13
fi
music="${OPENDASH_VIDEO_MUSIC:-$HOME/Downloads/bensound-dontgoaway.mp3}"
final="${OPENDASH_VIDEO_OUT:-$HOME/Movies/OpenDash-launch}"

if [[ "${1:-}" == "--thumbnails" ]]; then
  flutter test tool/launch_video/render_test.dart --dart-define=OPENDASH_NO_DEV_PANEL=true --dart-define=OPENDASH_THUMBNAIL=true
  /bin/mkdir -p "$final/thumbnails"
  for f in build/launch_video/thumbs/*.png; do
    ffmpeg -v error -y -i "$f" -vf scale=1280:720 -q:v 2 "$final/thumbnails/$(basename "$f" .png).jpg"
  done
  echo "thumbnails: $final/thumbnails"
  exit 0
fi

if [[ "${1:-}" == "--stills" ]]; then
  flutter test tool/launch_video/render_test.dart --dart-define=OPENDASH_NO_DEV_PANEL=true --dart-define=OPENDASH_VIDEO_REEL=$reel
  echo "stills: $out/stills"
  exit 0
fi

[[ -f "$music" ]] || { echo "no music at $music" >&2; exit 1; }
flutter test tool/launch_video/render_test.dart \
  --dart-define=OPENDASH_NO_DEV_PANEL=true --dart-define=OPENDASH_VIDEO_FULL=true --dart-define=OPENDASH_VIDEO_REEL=$reel

frames=$(find "$out/frames" -name '*.png' | wc -l | tr -d ' ')
seconds=$(python3 -c "print($frames / 60)")
first_beat=$(python3 -I tool/launch_video/beats.py "$music" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['first_beat'] + $music_from * 60 / d['bpm'])")
fade_out=$(python3 -c "print($seconds - 3)")

/bin/mkdir -p "$final"
ffmpeg -y -v error -stats \
  -framerate 60 -i "$out/frames/%05d.png" \
  -ss "$first_beat" -t "$seconds" -i "$music" \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 60 \
  -af "volume=-6dB,afade=t=in:d=0.5,afade=t=out:st=$fade_out:d=3" -c:a aac -b:a 256k \
  -movflags +faststart -shortest "$out/$name.mp4"
/bin/cp -f "$out/$name.mp4" "$final/$name.mp4"

ffprobe -v error -show_entries stream=codec_type,width,height,r_frame_rate,duration -of compact "$final/$name.mp4"
echo "$frames frames, $seconds s -> $final/$name.mp4"
