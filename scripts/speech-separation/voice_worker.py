"""Bounded local WAV-to-WAV worker for Voxloom."""

import argparse
from functools import lru_cache
from io import BytesIO
import json
from pathlib import Path
import sys
import wave

import numpy as np

from models import load_matcher
from residual import suppress_residual
from separate import SAMPLE_RATE


def read_pcm(data):
    with wave.open(BytesIO(data), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, SAMPLE_RATE):
            raise ValueError("Expected 16 kHz mono PCM")
        if audio.getnframes() > 60 * SAMPLE_RATE:
            raise ValueError("Recording exceeds limit")
        return np.frombuffer(audio.readframes(audio.getnframes()), dtype="<i2").astype(np.float32) / 32768


def write_pcm(path, audio):
    pcm = np.clip(np.rint(audio * 32768), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as output:
        output.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        output.writeframes(pcm.tobytes() if np.any(pcm) else b"")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--weights-directory", type=Path)
    args = parser.parse_args()
    config = json.loads((args.assets / "engine.json").read_text())
    matcher = load_matcher(args.weights_directory or args.assets, config["model"], config.get("threads", 4), config["backend"])

    @lru_cache(maxsize=6)
    def enroll(references):
        return matcher.enroll([read_pcm(reference) for reference in references])

    print('{"ready":true}', flush=True)
    preview_session = None
    preview = None
    for line in sys.stdin:
        try:
            request = json.loads(line)
            references = request["references"]
            if not 1 <= len(references) <= 3:
                raise ValueError("Expected one to three reference recordings")
            audio = read_pcm(Path(request["audio"]).read_bytes())
            session = request.get("previewSession")
            if session is not None and session == preview_session:
                filtered = preview.extend(audio)
            else:
                preview_session, preview = None, None
                enrollment = enroll(tuple(Path(reference).read_bytes() for reference in references))
                if session is None:
                    filtered = matcher.run(audio, enrollment)
                else:
                    preview = matcher.preview(enrollment)
                    preview_session = session
                    filtered = preview.extend(audio)
            if config["model"] == "voxlock":
                filtered = suppress_residual(audio, filtered)
            write_pcm(request["output"], filtered)
            print('{"ok":true}', flush=True)
        except (ValueError, RuntimeError, OSError, KeyError, AttributeError, wave.Error):
            preview_session, preview = None, None
            print('{"ok":false}', flush=True)


if __name__ == "__main__":
    main()
