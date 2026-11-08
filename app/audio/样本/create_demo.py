#!/usr/bin/env python3
"""Create a small original practice loop. Existing source material is never replaced."""
from pathlib import Path
import math
import random
import struct
import wave

output = Path(__file__).resolve().parent / '原始分轨混音' / '混音.wav'
if output.exists() or output.is_symlink():
    print('保留已有示例：', output)
    raise SystemExit(0)
output.parent.mkdir(parents=True, exist_ok=True)
rate, duration = 44100, 12
chords = [(45, 52, 57, 60, 64), (41, 48, 53, 57, 60),
          (48, 55, 60, 64, 67), (43, 50, 55, 59, 62)]
rng = random.Random(731)
data = bytearray()
for frame in range(rate * duration):
    t = frame / rate
    notes = chords[min(3, int(t // 3))]
    value = 0.0
    for index, note in enumerate(notes):
        age = (t - index * 0.012) % 0.75
        frequency = 440 * 2 ** ((note - 69) / 12)
        tone = sum(math.sin(2 * math.pi * frequency * harmonic * age) / harmonic
                   for harmonic in (1, 2, 3))
        value += 0.045 * tone * math.exp(-4.8 * age)
    beat_age = t % 0.5
    value += 0.09 * math.sin(2 * math.pi * 65 * beat_age) * math.exp(-45 * beat_age)
    value += 0.013 * rng.uniform(-1, 1) * math.exp(-80 * (t % 0.25))
    sample = int(max(-0.8, min(0.8, value)) * 32767)
    data.extend(struct.pack('<hh', sample, int(sample * 0.96)))
with output.open('xb') as raw:
    with wave.open(raw, 'wb') as stream:
        stream.setnchannels(2)
        stream.setsampwidth(2)
        stream.setframerate(rate)
        stream.writeframes(data)
print('已生成 12 秒原创合成练习示例：', output)
