#!/usr/bin/env python3
"""Generate compiler-backed values for every complete positive manifest fixture."""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests/AgentsManifestTests/Fixtures"
DESTINATION = Path("Tests/AgentsManifestTests/CompiledFixtures.swift")
HEADER = "// Generated from Tests/AgentsManifestTests/Fixtures. Run Scripts/generate-manifest-fixtures.py."
BINDING = re.compile(r"^let ([A-Za-z_][A-Za-z_0-9]*)\b", re.MULTILINE)


def function_name(path):
    return "compiled" + path.name.removesuffix(".swift.txt")


def fixture_function(path):
    # Imports stay at file scope; all bindings remain ordinary Swift inside the function.
    lines = [line for line in path.read_text().splitlines() if line != "import AgentsDescription"]
    names = BINDING.findall("\n".join(lines))
    result = ["private func " + function_name(path) + "() -> CompiledManifestFixture {"]
    result += ["  " + line if line else "" for line in lines]
    result += ["  return CompiledManifestFixture(", "    name: " + json.dumps(path.name) + ", agents: agents, constants: ["]
    result += ["      " + json.dumps(name) + ": " + name + ".constructionValue," for name in names]
    return result + ["    ])", "}", ""]


def generated_source(paths):
    lines = [HEADER, "", "import AgentsDescription", "import Foundation", "",
             "#if canImport(SwiftUI)", "  import SwiftUI", "#endif", "",
             "struct CompiledManifestFixture {", "  let name: String", "  let agents: Agents",
             "  let constants: [String: ConstructionValue]", "}", "",
             "func compiledFixtures() -> [CompiledManifestFixture] {", "  ["]
    lines += ["    " + function_name(path) + "()," for path in paths]
    lines += ["  ]", "}", ""]
    for path in paths:
        lines += fixture_function(path)
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=ROOT)
    arguments = parser.parse_args()
    paths = sorted(FIXTURES.glob("*.swift.txt"))
    destination = arguments.output_root / DESTINATION
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(generated_source(paths))
    subprocess.run(["swift", "format", "format", "--in-place", "--configuration",
                    str(ROOT / ".swift-format"), str(destination)], check=True)


if __name__ == "__main__":
    main()
