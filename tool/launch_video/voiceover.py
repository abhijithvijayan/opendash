#!/usr/bin/env python3
"""Lays a voiceover on a rendered video: each clip at its scene, the music under it.

  voiceover.py <video.mp4> <music> <clip-dir> <prefix> <out.mp4> <music-start-s> <start>...

Clip <prefix>-01.mp3 goes at the first start (seconds), -02 at the second, and so
on. A clip whose start comes before the last one has finished waits for it, plus
a short breath, so lines never talk over each other. The music sits low and dips
further while the voice speaks.
"""
import json
import subprocess
import sys

BREATH = 0.3


def duration(path):
    out = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                         check=True, capture_output=True, text=True).stdout
    return float(out)


def main():
    video, music, clips, prefix, out, music_from = sys.argv[1:7]
    starts = [float(s) for s in sys.argv[7:]]
    length = duration(video)
    placed, end = [], 0.0
    for i, want in enumerate(starts, 1):
        path = f'{clips}/{prefix}-{i:02d}.mp3'
        at = max(want, end + BREATH if end else want)
        d = duration(path)
        placed.append((path, at, d))
        end = at + d
        print(f'{prefix}-{i:02d}  wanted {want:6.2f}  placed {at:6.2f}  ends {end:6.2f}')
    if end > length:
        sys.exit(f'the voice runs to {end:.2f} s but the video is {length:.2f} s')

    inputs = ['-i', video, '-ss', music_from, '-t', f'{length}', '-i', music]
    for path, _, _ in placed:
        inputs += ['-i', path]
    parts = []
    for n, (_, at, _) in enumerate(placed):
        ms = int(at * 1000)
        parts.append(f'[{n + 2}:a]aresample=44100,aformat=channel_layouts=stereo,adelay={ms}|{ms}[v{n}]')
    mix = ''.join(f'[v{n}]' for n in range(len(placed)))
    fade = max(length - 3, 0)
    graph = ';'.join(parts + [
        f'{mix}amix=inputs={len(placed)}:normalize=0,apad=whole_dur={length},loudnorm=I=-16:TP=-1.5:LRA=7[voice]',
        '[voice]asplit=2[voice1][key]',
        f'[1:a]aresample=44100,volume=-17dB,afade=t=in:d=0.5,afade=t=out:st={fade}:d=3[music]',
        '[music][key]sidechaincompress=threshold=0.02:ratio=6:attack=40:release=450[ducked]',
        '[ducked][voice1]amix=inputs=2:normalize=0,alimiter=limit=0.95[a]',
    ])
    subprocess.run(['ffmpeg', '-y', '-v', 'error', *inputs, '-filter_complex', graph,
                    '-map', '0:v', '-map', '[a]', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '256k',
                    '-t', f'{length}', '-movflags', '+faststart', out], check=True)
    print(json.dumps({'out': out, 'voice_ends': round(end, 2), 'length': round(length, 2)}))


if __name__ == '__main__':
    main()
