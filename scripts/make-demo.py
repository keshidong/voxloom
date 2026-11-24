#!/usr/bin/env python3
"""Build the legacy voice demo."""
from pathlib import Path
import runpy
import sys


if __name__ == "__main__":
    sys.argv[1:1] = ["--product", "voice-demo"]
    runpy.run_path(str(Path(__file__).with_name("package-app.py")), run_name="__main__")
