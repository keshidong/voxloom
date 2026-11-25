"""Prepare the pinned MS-SNSD noise cases used by the opt-in Qwen ASR tests."""

import argparse
from array import array
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
import math
from pathlib import Path
import urllib.request
import wave


REVISION = "fe61c4ba0d9ac8dd7e23d719cc79f8947e1dc742"
SOURCE = f"https://raw.githubusercontent.com/microsoft/MS-SNSD/{REVISION}/noise_test"
COUNTS = {
    "AirConditioner": 10,
    "CopyMachine": 2,
    "Munching": 8,
    "ShuttingDoor": 8,
    "Typing": 2,
    "VacuumCleaner": 1,
}
LEVELS = {"public-noise-48dBFS": 0.004, "public-noise-38dBFS": 0.012}
RATE = 16_000


def middle_excerpt(data):
    with wave.open(BytesIO(data), "rb") as source:
        if source.getframerate() != RATE or source.getsampwidth() != 2 or source.getnframes() < 2 * RATE:
            raise ValueError("Expected at least two seconds of 16 kHz PCM16")
        channels = source.getnchannels()
        source.setpos((source.getnframes() - 2 * RATE) // 2)
        interleaved = array("h", source.readframes(2 * RATE))
    return [
        sum(interleaved[index:index + channels]) / channels
        for index in range(0, len(interleaved), channels)
    ]


def prepare_file(output, name):
    with urllib.request.urlopen(f"{SOURCE}/{name}", timeout=30) as response:
        samples = middle_excerpt(response.read())
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    if not rms:
        raise ValueError(f"Unexpected silent excerpt: {name}")
    for directory, level in LEVELS.items():
        gain = level * 32768 / rms
        pcm = array("h", (min(32767, max(-32768, round(sample * gain))) for sample in samples))
        path = output / directory / name
        temporary = path.with_suffix(".wav.part")
        with wave.open(str(temporary), "wb") as result:
            result.setparams((1, 2, RATE, 0, "NONE", ""))
            result.writeframes(pcm.tobytes())
        temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/reports/qwen-noise-fixtures"))
    output = parser.parse_args().output
    for directory in LEVELS:
        (output / directory).mkdir(parents=True, exist_ok=True)
    names = [f"{kind}_{index}.wav" for kind, count in COUNTS.items() for index in range(1, count + 1)]
    with ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(lambda name: prepare_file(output, name), names))
    print(f"Prepared {len(names)} clips at {len(LEVELS)} levels from MS-SNSD {REVISION}")


if __name__ == "__main__":
    main()
