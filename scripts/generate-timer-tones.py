#!/usr/bin/env python3
"""Regenerate the original PCM timer tones; no external samples/dependencies."""
import math
from pathlib import Path
import struct
import wave

OUTPUT = Path(__file__).resolve().parents[1] / "ios/TresFort/Sounds"
RATE = 44_100


def write_tone(name, frequency, duration):
    samples = []
    for frame in range(round(RATE * duration)):
        elapsed = frame / RATE
        # Gentle attack/release avoids an audible click at the waveform edges.
        envelope = min(1, elapsed / 0.008, (duration - elapsed) / 0.035)
        sample = 0.35 * envelope * math.sin(2 * math.pi * frequency * elapsed)
        samples.append(round(32_767 * sample))
    with wave.open(str(OUTPUT / f"timed-set-{name}.wav"), "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(struct.pack("<" + "h" * len(samples), *samples))


if __name__ == "__main__":
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_tone("tick", 880, 0.12)
    write_tone("complete", 1320, 0.55)
