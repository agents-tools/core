"""Format generated Swift sources and optionally check committed bytes without writing them."""
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def write_generated(outputs, output_root, *, check):
    def render(directory):
        paths = []
        for relative, source in outputs.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            paths.append(str(path))
        subprocess.run([
            "swift", "format", "format", "--in-place", "--configuration",
            str(ROOT / ".swift-format"), *paths,
        ], check=True)

    if not check:
        render(output_root)
        return

    scratch = ROOT / ".build/manifest-generation"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as directory:
        generated = Path(directory)
        render(generated)
        drift = [relative for relative in outputs
                 if not (ROOT / relative).exists()
                 or (ROOT / relative).read_bytes() != (generated / relative).read_bytes()]
    if drift:
        for relative in drift:
            print(f"generated drift: {relative}")
        raise SystemExit(1)
