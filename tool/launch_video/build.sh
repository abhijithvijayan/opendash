#!/usr/bin/env bash
# Renders the launch video from the app itself: every frame through the
# Flutter test renderer, then ffmpeg for the encode and the music.
#   tool/launch_video/build.sh            the full video
#   tool/launch_video/build.sh --stills   three stills per scene, for a look
# The music is not in the repository: OPENDASH_VIDEO_MUSIC, or the default below.
set -euo pipefail
cd "$(dirname "$0")/../.."

out=build/launch_video
music="${OPENDASH_VIDEO_MUSIC:-$HOME/Downloads/bensound-dontgoaway.mp3}"
final="${OPENDASH_VIDEO_OUT:-$HOME/Movies/OpenDash-launch}"

if [[ "${1:-}" == "--stills" ]]; then
  flutter test tool/launch_video/render_test.dart --dart-define=OPENDASH_NO_DEV_PANEL=true
  echo "stills: $out/stills"
  exit 0
fi

[[ -f "$music" ]] || { echo "no music at $music" >&2; exit 1; }
flutter test tool/launch_video/render_test.dart \
  --dart-define=OPENDASH_NO_DEV_PANEL=true --dart-define=OPENDASH_VIDEO_FULL=true

frames=$(find "$out/frames" -name '*.png' | wc -l | tr -d ' ')
seconds=$(python3 -c "print($frames / 60)")
first_beat=$(python3 -I tool/launch_video/beats.py "$music" | python3 -c "import json,sys; print(json.load(sys.stdin)['first_beat'])")
fade_out=$(python3 -c "print($seconds - 3)")

/bin/mkdir -p "$final"
ffmpeg -y -v error -stats \
  -framerate 60 -i "$out/frames/%05d.png" \
  -ss "$first_beat" -t "$seconds" -i "$music" \
  -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 60 \
  -af "volume=-6dB,afade=t=in:d=0.5,afade=t=out:st=$fade_out:d=3" -c:a aac -b:a 256k \
  -movflags +faststart -shortest "$out/opendash-launch.mp4"
/bin/cp -f "$out/opendash-launch.mp4" "$final/opendash-launch.mp4"

ffprobe -v error -show_entries stream=codec_type,width,height,r_frame_rate,duration -of compact "$final/opendash-launch.mp4"
echo "$frames frames, $seconds s -> $final/opendash-launch.mp4"
