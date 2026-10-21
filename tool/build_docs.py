#!/usr/bin/env python3
"""Build the static guide and dartdoc using the resolved local package."""
import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default="dart", help="Dart executable (default: dart)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = root / "build" / "site"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(root / "doc" / "site", destination)
    subprocess.run(
        [args.dart, "doc", "--validate-links", "--output", str(destination / "api")],
        cwd=root,
        check=True,
    )


if __name__ == "__main__":
    main()
