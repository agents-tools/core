"""Write formatted Swift sources or check committed sources for generation drift."""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path


def write_generated(outputs: dict[Path, str], destination: Path, *, configuration: Path):
    paths = []
    for relative, source in outputs.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        paths.append(str(path))
    subprocess.run([
        "swift", "format", "format", "--in-place", "--configuration",
        str(configuration), *paths,
    ], check=True)


def check_generated(outputs: dict[Path, str], repository: Path, *, generator: Path):
    scratch = repository / ".build/manifest-generation"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        generated = Path(directory)
        write_generated(outputs, generated, configuration=repository / ".swift-format")
        drift = [relative for relative in outputs
                 if not (repository / relative).exists()
                 or (repository / relative).read_bytes() != (generated / relative).read_bytes()]
    if drift:
        for relative in drift:
            print(f"generated drift: {relative}", file=sys.stderr)
        print(f"Regenerate with: python3 {generator.relative_to(repository)}", file=sys.stderr)
        raise SystemExit(1)


def run_generator(outputs: dict[Path, str], *, repository: Path, generator: Path):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail on committed source drift")
    arguments = parser.parse_args()
    if arguments.check:
        check_generated(outputs, repository, generator=generator)
    else:
        write_generated(outputs, repository, configuration=repository / ".swift-format")
