#!/usr/bin/env python3
"""Capture the Release test host under LLDB on the selected macOS toolchain."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / ".build/release-crash-diagnostics"
FLAGS = ["-c", "release", "--disable-index-store", "--build-system", "native"]
FILTER = "PublicationTests.primitiveFailuresCleanPrivateResourcesBeforeChangingUserData"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--filter-only", action="store_true")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="home-", dir=OUTPUT) as home:
        environment = {key: value for key, value in os.environ.items()
                       if key in ("PATH", "DEVELOPER_DIR", "SDKROOT", "TMPDIR")}
        environment.update(HOME=home, GIT_CONFIG_NOSYSTEM="1",
                           GIT_CONFIG_GLOBAL="/dev/null", GIT_TERMINAL_PROMPT="0",
                           TERM="dumb", LC_ALL="C")

        def output(command):
            return subprocess.check_output(command, cwd=ROOT, env=environment,
                                           text=True).strip()

        def record(name, command):
            print(shlex.join(command), flush=True)
            result = subprocess.run(command, cwd=ROOT, env=environment,
                                    text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=1800)
            (OUTPUT / (name + ".log")).write_text(result.stdout)
            print(result.stdout, flush=True)
            return result

        print(output(["xcodebuild", "-version"]), flush=True)
        print(output(["swift", "--version"]), flush=True)
        print(output(["git", "rev-parse", "HEAD"]), flush=True)
        build = record("build", ["swift", "test", *FLAGS, "list"])
        if build.returncode:
            return build.returncode
        swift = Path(output(["xcrun", "--find", "swift"]))
        helper = swift.parent.parent / "libexec/swift/pm/swiftpm-testing-helper"
        platform = Path(output(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"]))
        binary_directory = Path(output(["swift", "build", *FLAGS, "--show-bin-path"]))
        bundle = binary_directory / "corePackageTests.xctest/Contents/MacOS/corePackageTests"
        framework_directory = platform / "Developer/Library/Frameworks"
        for path in (helper, bundle, framework_directory / "Testing.framework"):
            if not path.exists():
                raise RuntimeError(f"Missing selected-toolchain artifact: {path}")
        settings = "settings set target.env-vars " + " ".join(map(shlex.quote, [
            "DYLD_FRAMEWORK_PATH=" + str(framework_directory),
            "DYLD_LIBRARY_PATH=" + str(platform / "Developer/usr/lib"),
        ]))
        command = ["xcrun", "lldb", "--batch", "--no-lldbinit", "-o", settings,
                   "-o", "run", "-k", "thread backtrace all", "-k", "register read",
                   "-k", "image list", "--", str(helper), "--test-bundle-path",
                   str(bundle), "-c", "release", "--disable-index-store", str(bundle),
                   "--testing-library", "swift-testing"]
        results = []
        probes = [("filtered", ["--filter", FILTER])]
        if not args.filter_only:
            probes.append(("full", []))
        for name, extra in probes:
            result = record(name, command + extra)
            passed = (result.returncode == 0
                      and "stop reason =" not in result.stdout
                      and re.search(r"Test run with [1-9]\d* tests? in .* passed", result.stdout)
                      and re.search(r"Process \d+ exited with status = 0", result.stdout))
            results.append({"probe": name, "lldb_exit": result.returncode,
                            "passed": bool(passed), "command": command + extra})
            (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            if not passed:
                return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
