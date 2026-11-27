#!/usr/bin/env python3
"""Run the package tests in the pinned Linux toolchain as the checkout owner."""

import json
import os
from pathlib import Path
import subprocess
import sys


def main(image):
    root = Path(__file__).resolve().parents[1]
    config = json.loads((root / ".github/swift-package.json").read_text())
    if os.getuid() == 0:
        raise SystemExit("Run Linux validation as a regular user for filesystem permission tests.")

    dockerfile = root / ".github/ci/linux-tests.Dockerfile"
    test_image = subprocess.check_output(
        [
            "docker", "build", "--quiet", "--file", str(dockerfile),
            "--build-arg", f"SWIFT_IMAGE={image}",
            "--build-arg", f"TEST_UID={os.getuid()}",
            "--build-arg", f"TEST_GID={os.getgid()}",
            str(dockerfile.parent),
        ],
        text=True,
    ).strip()
    for configuration in config["test_configurations"]:
        subprocess.run(
            [
                "docker", "run", "--rm", "--init", "--volume", f"{root}:/workspace",
                test_image, "swift", "test", "-c", configuration, "--jobs", "2", "--no-parallel",
            ],
            check=True,
        )


if __name__ == "__main__":
    main(sys.argv[1])
