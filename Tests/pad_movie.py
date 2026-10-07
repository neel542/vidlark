#!/usr/bin/env python3
"""Pads a movie the way AVCaptureMovieFileOutput does: every chunk starts on a 16 KB boundary,
with zeros in between, and the chunk tables point at the new places. Used to test vidlark-finish
--tidy, which takes the padding out again. Usage: pad_movie.py <in.mov> <out.mov>"""
import struct, sys

data = open(sys.argv[1], "rb").read()

def boxes(start, end):
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[at + 8:at + 16])[0]; header = 16
        elif size == 0:
            size = end - at
        yield kind.decode("latin-1"), at, size, header
        at += size

def find(kind, start, end):
    return next((b for b in boxes(start, end) if b[0] == kind), None)

top = list(boxes(0, len(data)))
moov = next(b for b in top if b[0] == "moov")
mdat = next(b for b in top if b[0] == "mdat")
assert moov[1] > mdat[1], "expects the moov after the media data"
chunks = []  # (offset, size, entry position, wide)
for trak in boxes(moov[1] + moov[3], moov[1] + moov[2]):
    if trak[0] != "trak":
        continue
    node = trak
    for kind in ("mdia", "minf", "stbl"):
        node = find(kind, node[1] + node[3], node[1] + node[2])
    kids = {b[0]: b for b in boxes(node[1] + node[3], node[1] + node[2])}
    stsz, stsc = kids["stsz"], kids["stsc"]
    co = kids.get("co64") or kids["stco"]
    wide = co[0] == "co64"
    base = stsz[1] + stsz[3] + 4
    fixed, count = struct.unpack(">II", data[base:base + 8])
    sizes = [fixed] * count if fixed else list(struct.unpack(">%dI" % count, data[base + 8:base + 8 + 4 * count]))
    n = struct.unpack(">I", data[co[1] + co[3] + 4:co[1] + co[3] + 8])[0]
    runs = struct.unpack(">I", data[stsc[1] + stsc[3] + 4:stsc[1] + stsc[3] + 8])[0]
    table = [struct.unpack(">III", data[stsc[1] + stsc[3] + 8 + 12 * r:stsc[1] + stsc[3] + 20 + 12 * r]) for r in range(runs)]
    per = []
    for r, (first, samples, _) in enumerate(table):
        last = table[r + 1][0] - 1 if r + 1 < runs else n
        per += [samples] * (last - first + 1)
    s = 0
    for c in range(n):
        at = co[1] + co[3] + 8 + c * (8 if wide else 4)
        offset = struct.unpack(">Q" if wide else ">I", data[at:at + (8 if wide else 4)])[0]
        chunks.append((offset, sum(sizes[s:s + per[c]]), at, wide))
        s += per[c]

chunks.sort()
out = bytearray(data[:mdat[1]])
out += b"\0" * 8  # mdat header, filled in below
moved = {}
for offset, size, at, wide in chunks:
    out += b"\0" * (-len(out) % 16384)
    moved[at] = (len(out), wide)
    out += data[offset:offset + size]
struct.pack_into(">I4s", out, mdat[1], len(out) - mdat[1], b"mdat")
shift = len(out) - moov[1]
moov_bytes = bytearray(data[moov[1]:moov[1] + moov[2]])
for at, (new, wide) in moved.items():
    struct.pack_into(">Q" if wide else ">I", moov_bytes, at - moov[1], new)
out += moov_bytes + data[moov[1] + moov[2]:]
open(sys.argv[2], "wb").write(out)
