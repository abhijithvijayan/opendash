#!/usr/bin/env python3
"""Read a raw recording made by OpenDash (Settings, Developer, "Record raw data"),
or a file of the bus log ("Bus log": bus-<stamp>.jsonl, burst-<stamp>-<reason>.jsonl).

    scripts/raw-recording.py raw-<stamp>.jsonl                 # what is on the bus
    scripts/raw-recording.py raw-<stamp>.jsonl --id 1a5        # one frame over time
    scripts/raw-recording.py raw-<stamp>.jsonl --scrub out.jsonl   # a copy safe to pass on

A recording holds every frame on the scooter's bus and every update from
the stock service for a few minutes, each with its time in ms. This lists
each frame id with how often it came, its length, which bytes changed,
the range of each 16-bit word, and what it could be: a frame of words
between 2.5 and 4.5 V is probably cell voltages, whatever its id.

A bus-log file (kind "bus_log") holds a frame only when it changed, plus a
keyframe line with every id's last payload every 30 s: counts there are
changes, not frames. A burst (kind "bus_burst") holds every frame of the
minute before its trigger and the seconds after; "trigger_t" is when it
fired. In every kind, log_mono_ms + t is the analytics log's mono, in ms.

Frames that spell text (a VIN, a serial number, a part number) are named.
--scrub writes a copy without them and without any frame that never
changed, which is where an identifier that is not text would sit; they
are taken out of keyframes as well.

Reads files only. Nothing is sent anywhere.
"""
import json
import sys

KNOWN = {
    "140": "limits and current", "150": "bus voltage, SOH", "160": "balancing", "170": "balancing per cell",
    "1a4": "pack temperatures 1-4", "1a5": "cells 1-4", "1a6": "cells 5-8", "1a7": "pack temperatures 5-6",
    "1a8": "pack voltage", "1a9": "cells 9-12", "1aa": "cells 13-14", "144": "lock state",
    "353": "brightness, service, trunk", "683": "regen, tow", "6f4": "range",
}


def read(path):
    header, frames, batches = {}, {}, []
    with open(path, errors="replace") as f:
        for line in f:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if "raw_recording" in row:
                header = row
            elif "f" in row:
                frames.setdefault(row["f"], []).append((row.get("t", 0), row.get("n", 0), bytes.fromhex(row.get("d", ""))))
            elif "b" in row:
                batches.append((row.get("t", 0), row["b"]))
    return header, frames, batches


def texty(data):
    return sum(1 for b in data if 0x30 <= b <= 0x39 or 0x41 <= b <= 0x5a or 0x61 <= b <= 0x7a)


def is_text(samples):
    """Most of its bytes are letters or digits in most of its frames."""
    hits = sum(1 for _, _, d in samples if len(d) >= 4 and texty(d) >= max(4, len(d) - 2))
    return hits * 2 >= len(samples)


def describe(fid, samples, seconds):
    width = max(len(d) for _, _, d in samples)
    changed = bytearray(width)
    first = samples[0][2]
    lo, hi = [65535] * (width // 2), [0] * (width // 2)
    for _, _, d in samples:
        for i in range(min(len(d), len(first))):
            changed[i] |= d[i] ^ first[i]
        for w in range(len(d) // 2):
            v = d[2 * w] | (d[2 * w + 1] << 8)
            lo[w], hi[w] = min(lo[w], v), max(hi[w], v)
    guess = KNOWN.get(fid, "")
    volts = [w for w in range(len(lo)) if 2500 <= lo[w] and hi[w] <= 4500]
    if not guess and len(volts) >= 2:
        guess = f"words {volts} stay between 2.5 and 4.5 V: cell voltages?"
    if is_text(samples):
        guess = "TEXT: an identifier or a part number; scrubbed"
    elif not any(changed):
        guess = (guess + "; " if guess else "") + "never changed; scrubbed"
    rate = len(samples) / seconds if seconds else 0
    words = " ".join(f"{a}-{b}" if a != b else f"{a}" for a, b in zip(lo, hi))
    lengths = sorted({n for _, n, _ in samples})
    return f"0x{fid:<4} {len(samples):>7} {rate:>6.1f}/s  len {lengths}  changed {changed.hex()}  words {words}  {guess}"


def drop(fid, samples):
    first = samples[0][2]
    return is_text(samples) or (fid not in KNOWN and all(d == first for _, _, d in samples))


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2
    path, rest = args[0], args[1:]
    header, frames, batches = read(path)
    if not header:
        print("Not a raw recording: no header line.")
        return 2
    last = max([s[-1][0] for s in frames.values()] + [b[0] for b in batches[-1:]] + [0])
    seconds = last / 1000

    if "--id" in rest:
        fid = rest[rest.index("--id") + 1].lower().removeprefix("0x")
        for t, _, d in frames.get(fid, []):
            words = " ".join(str(d[i] | (d[i + 1] << 8)) for i in range(0, len(d) - 1, 2))
            print(f"{t:>8} {d.hex()}  {words}")
        return 0 if fid in frames else 2

    if "--scrub" in rest:
        out = rest[rest.index("--scrub") + 1]
        gone = {fid for fid, s in frames.items() if drop(fid, s)}
        kept = 0
        with open(path, errors="replace") as src, open(out, "w") as dst:
            for line in src:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("f") in gone:
                    continue
                if "key" in row:
                    row["key"] = {fid: d for fid, d in row["key"].items() if fid not in gone}
                if "raw_recording" in row:
                    row["warning"] = f"Scrubbed: {len(gone)} frame ids removed (text, or never changing and unknown)."
                dst.write(json.dumps(row, separators=(",", ":")) + "\n")
                kept += 1
        print(f"{out}: {kept} lines kept, {len(gone)} frame ids removed: {', '.join('0x' + g for g in sorted(gone)) or 'none'}")
        print("Read it once yourself before passing it on: the scrub is a filter, not a guarantee.")
        return 0

    kind = header.get("kind", "raw_recording")
    if kind == "bus_log":
        print("Bus log: a frame is listed each time it changed; the counts and rates below are changes.")
    elif kind == "bus_burst":
        print(f"Burst for {', '.join(header.get('reasons', []))}, triggered at t={header.get('trigger_t')} ms.")
    print(f"OpenDash {header.get('version')} build {header.get('build')}, {seconds:.0f} s, "
          f"{sum(len(s) for s in frames.values())} frames on {len(frames)} ids, {len(batches)} updates from the stock service")
    print(header.get("warning", ""))
    print()
    for fid in sorted(frames, key=lambda x: int(x, 16)):
        print(describe(fid, frames[fid], seconds))
    missing = sorted(set(KNOWN) - set(frames))
    if missing:
        print(f"\nframes OpenDash reads that never came: {', '.join('0x' + m for m in missing)}")
    keys = {}
    for _, b in batches:
        for k in b:
            keys[k] = keys.get(k, 0) + 1
    print(f"\n{len(keys)} keys from the stock service; the busiest: "
          + ", ".join(f"{k} x{n}" for k, n in sorted(keys.items(), key=lambda x: -x[1])[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
