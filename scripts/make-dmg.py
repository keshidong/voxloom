#!/usr/bin/env python3
"""Build a signed Voxloom app and package it in a verified macOS disk image."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
INSTALLER_ART = ROOT / "scripts/dmg"


def build_installer_image(image, app):
    from dmgbuild import build_dmg

    build_dmg(str(image), f"{app.stem} Installer", settings={
        "filesystem": "HFS+",
        "format": "ULFO",
        "files": [str(app)],
        "symlinks": {"Applications": "/Applications"},
        "icon": str(INSTALLER_ART / "install-volume.icns"),
        "background": str(INSTALLER_ART / "install-background.tiff"),
        "default_view": "icon-view",
        "window_rect": ((150, 150), (640, 340)),
        "icon_size": 104,
        "text_size": 14,
        "icon_locations": {app.name: (160, 187), "Applications": (480, 187)},
    })


def package_disk_image(configuration, output, voice_isolation, version=None, build_number=None):
    app_name = "Voxloom Debug" if configuration == "debug" else "Voxloom"
    build = ROOT / ".build"
    build.mkdir(exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(dir=build, prefix="dmg-source-") as source_directory, \
            tempfile.TemporaryDirectory(dir=output.parent, prefix="dmg-output-") as image_directory:
        app = Path(source_directory) / f"{app_name}.app"
        command = [
            sys.executable, "scripts/package-app.py",
            "--configuration", configuration, "--output", str(app),
            "--external-models",
        ]
        if voice_isolation:
            command.append("--voice-isolation")
        if version is not None:
            command.extend(["--version", version])
        if build_number is not None:
            command.extend(["--build-number", build_number])
        subprocess.run(command, cwd=ROOT, check=True)
        image = Path(image_directory) / output.name
        build_installer_image(image, app)
        subprocess.run(["hdiutil", "verify", "-quiet", str(image)], check=True)
        image.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-c", "--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--voice-isolation", action="store_true")
    parser.add_argument("--version", help="App version in major.minor.patch form")
    parser.add_argument("--build-number", help="Positive integer identifying this build")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.suffix != ".dmg":
        parser.error("--output must end in .dmg")
    output = arguments.output.absolute()
    package_disk_image(arguments.configuration, output, arguments.voice_isolation,
                       version=arguments.version, build_number=arguments.build_number)
    print(output)


if __name__ == "__main__":
    main()
