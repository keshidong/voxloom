#!/usr/bin/env python3
"""Build a signed Voxloom app and package it in a verified macOS disk image."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def package_disk_image(configuration, output, voice_isolation):
    app_name = "Voxloom Debug" if configuration == "debug" else "Voxloom"
    build = ROOT / ".build"
    build.mkdir(exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(dir=build, prefix="dmg-source-") as source_directory, \
            tempfile.TemporaryDirectory(dir=output.parent, prefix="dmg-output-") as image_directory:
        source = Path(source_directory)
        command = [
            sys.executable, "scripts/make-demo.py", "--product", "voxloom",
            "--configuration", configuration, "--output", str(source / f"{app_name}.app"),
            "--external-models",
        ]
        if voice_isolation:
            command.append("--voice-isolation")
        subprocess.run(command, cwd=ROOT, check=True)
        (source / "Applications").symlink_to("/Applications", target_is_directory=True)
        # hdiutil inherits the source directory's permissions for the mounted volume.
        source.chmod(0o755)

        image = Path(image_directory) / output.name
        subprocess.run([
            "hdiutil", "create", "-srcfolder", str(source), "-volname", app_name,
            "-fs", "HFS+", "-format", "ULFO", "-quiet", str(image),
        ], check=True)
        subprocess.run(["hdiutil", "verify", "-quiet", str(image)], check=True)
        image.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--voice-isolation", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.suffix != ".dmg":
        parser.error("--output must end in .dmg")
    output = arguments.output.absolute()
    package_disk_image(arguments.configuration, output, arguments.voice_isolation)
    print(output)


if __name__ == "__main__":
    main()
