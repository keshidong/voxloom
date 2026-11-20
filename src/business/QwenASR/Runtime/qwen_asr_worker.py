"""Resident local-model ASR worker. Stdout is a bounded JSON-lines protocol."""
import argparse
import contextlib
import json
import sys


def emit(value):
    sys.__stdout__.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.__stdout__.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            from mlx_audio.stt.utils import load_model
            model = load_model(args.model)
        emit({"ready": True})
    except Exception:
        emit({"ready": False})
        return 1
    for line in sys.stdin:
        try:
            if len(line.encode("utf-8")) > 65536:
                raise ValueError("oversized request")
            request = json.loads(line)
            language = {"zh": "Chinese", "en": "English", "auto": None}[request["language"]]
            vocabulary = request.get("context", "")
            if len(vocabulary.encode("utf-8")) > 4096:
                raise ValueError("oversized vocabulary")
            with contextlib.redirect_stdout(sys.stderr):
                result = model.generate(request["audio"], language=language, max_tokens=512,
                                        temperature=0.0, verbose=False, system_prompt=vocabulary or None)
                text = result.text
                detected = getattr(result, "language", None)
                if isinstance(detected, list):
                    detected = next((item for item in detected if item), None)
                code = {"Chinese": "zh", "English": "en"}.get(detected, request["language"])
                mx.clear_cache()
            emit({"text": text, "language": None if code == "auto" else code})
        except Exception:
            emit({"error": "inference_failed"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
