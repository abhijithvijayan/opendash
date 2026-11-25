#!/usr/bin/env python3
"""Tempo and first beat of a track, from its energy envelope.

Prints {"bpm": float, "first_beat": seconds}. Standard library only;
ffmpeg decodes.
"""
import array
import json
import math
import subprocess
import sys

RATE, HOP = 11025, 256


def envelope(path, seconds=120):
    raw = subprocess.run(
        ['ffmpeg', '-v', 'error', '-t', str(seconds), '-i', path, '-ac', '1', '-ar', str(RATE), '-f', 's16le', '-'],
        check=True, capture_output=True).stdout
    pcm = array.array('h', raw)
    energy = [math.log1p(sum(x * x for x in pcm[i:i + HOP]) / HOP) for i in range(0, len(pcm) - HOP, HOP)]
    return [max(0.0, b - a) for a, b in zip(energy, energy[1:])]


def main(path):
    onset = envelope(path)
    fps = RATE / HOP
    best = (0.0, 0)
    for lag in range(int(fps * 60 / 180), int(fps * 60 / 70) + 1):
        score = sum(onset[i] * onset[i + lag] for i in range(len(onset) - lag)) / (len(onset) - lag)
        if score > best[0]:
            best = (score, lag)
    lag = best[1]
    # Refine around the winning lag with fractional periods over many beats.
    period = max((lag + d / 20 for d in range(-20, 21)),
                 key=lambda p: max(sum(onset[int(o + k * p)] for k in range(int((len(onset) - o) / p) - 1)) for o in range(int(p))))
    phase = max(range(int(period)), key=lambda o: sum(onset[int(o + k * period)] for k in range(int((len(onset) - o) / period) - 1)))
    print(json.dumps({'bpm': round(60 * fps / period, 2), 'first_beat': round(phase / fps, 3)}))


if __name__ == '__main__':
    main(sys.argv[1])
