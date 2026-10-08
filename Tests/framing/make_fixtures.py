#!/usr/bin/env python3
"""Writes the synthetic face tracks in Tests/framing/fixtures/, in faces.json's format.

No real faces: every box is made up here. Looks are 5 a second, as the finisher looks, with a
small, fixed wobble, as a detector gives. Run it again only to change the fixtures; check.swift reads the files.
"""
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "fixtures")
RATE = 5.0


def wobble(i, k):
    # The same small wobble every run, about 0.3 % of the picture.
    return 0.003 * math.sin(i * 1.7 + k * 2.3) * math.cos(i * 0.61 + k)


def face(mid_x, mid_y, h, aspect, i, k=0):
    # A face about as wide as it is tall, in pixels.
    w = h / aspect
    return [round(mid_x - w / 2 + wobble(i, k), 4), round(mid_y - h / 2 + wobble(i, k + 5), 4), round(w, 4), round(h, 4)]


def write(name, width, height, seconds, faces_at, note):
    aspect = width / height
    looks = []
    for i in range(int(seconds * RATE)):
        t = round(i / RATE, 3)
        looks.append({"t": t, "faces": faces_at(t, i, aspect)})
    data = {"version": 1, "file": "camera.mov", "width": width, "height": height, "duration": seconds,
            "looksPerSecond": RATE, "origin": "top-left", "spans": [[0, seconds]], "note": note, "looks": looks}
    with open(os.path.join(OUT, name + ".faces.json"), "w") as f:
        f.write(json.dumps(data, separators=(",", ":")) + "\n")


os.makedirs(OUT, exist_ok=True)
W, H = 1920, 1080

write("still", W, H, 30, lambda t, i, a: [face(0.42, 0.35, 0.18, a, i)],
      "She sits still and talks, a little left of the middle.")

write("drift", W, H, 40, lambda t, i, a: [face(0.40 + 0.006 * t, 0.35, 0.18, a, i)],
      "She drifts slowly to the right, 0.6 % of the picture a second.")

write("jump", W, H, 30, lambda t, i, a: [face(0.35 if t < 10 else 0.65, 0.35, 0.18, a, i)],
      "At 10 s she is suddenly somewhere else, far to the right.")

write("edge", W, H, 30, lambda t, i, a: [face(0.40 + 0.30 * min(1, max(0, t - 10)), 0.35, 0.18, a, i)],
      "At 10 s she walks quickly to the right, reaching the edge of the frame within a second.")

write("lost", W, H, 30, lambda t, i, a: [] if 10 <= t < 18 else [face(0.42, 0.35, 0.18, a, i)],
      "She looks down for 8 s (no face found), then up again in the same place.")

write("gone", W, H, 40, lambda t, i, a: [] if 10 <= t < 30 else [face(0.42 if t < 10 else 0.62, 0.35, 0.18, a, i)],
      "She is gone for 20 s, then comes back further right.")


def two(t, i, a):
    out = [face(0.40, 0.35, 0.18, a, i), face(0.78, 0.30, 0.10, a, i, 3)]
    if 12 <= t < 13.5:
        out.append(face(0.85, 0.45, 0.30, a, i, 7))
    return out


write("two", W, H, 30, two,
      "Her face, a smaller face in the background all along, and someone close to the lens passing by at 12 s.")

write("tall", 1080, 1920, 30, lambda t, i, a: [face(0.5, 0.30 if t < 12 else 0.50, 0.12, a, i)],
      "A phone filming tall: at 12 s she leans down, her face moving from 30 % to 50 % of the picture's height.")
