#!/usr/bin/env python3
"""Compile the reviewed positive corpus as ordinary Swift in the test target."""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parent.parent
paths = sorted((ROOT / 'Tests/AgentsManifestTests/Fixtures').glob('*.swift.txt'))
lines = ['// Generated from Tests/AgentsManifestTests/Fixtures. Run Scripts/generate-manifest-fixtures.py.', '', 'import AgentsDescription', 'import Foundation', '', '#if canImport(SwiftUI)', '  import SwiftUI', '#endif', '', 'struct CompiledManifestFixture {', '  let name: String', '  let agents: Agents', '  let constants: [String: ConstructionValue]', '}', '', 'func compiledFixtures() -> [CompiledManifestFixture] {', '  [']
for i,p in enumerate(paths):lines.append(f'    fixture{i}(),')
lines+=['  ]','}','']
for i,p in enumerate(paths):
    body='\n'.join(l for l in p.read_text().splitlines() if l!='import AgentsDescription')
    names = re.findall(r'^let ([A-Za-z_][A-Za-z_0-9]*)\b', body, re.MULTILINE)
    lines += [f'private func fixture{i}() -> CompiledManifestFixture {{']+['  '+l if l else '' for l in body.splitlines()]
    lines += [f'  return CompiledManifestFixture(name: "{p.name}", agents: agents, constants: [']
    lines += [f'    "{name}": {name}.constructionValue,' for name in names]
    lines += ['  ])','}','']
(ROOT / 'Tests/AgentsManifestTests/CompiledFixtures.swift').write_text('\n'.join(lines))

import subprocess
subprocess.run(["swift", "format", "format", "--in-place", "--configuration", str(ROOT / ".swift-format"), str(ROOT / 'Tests/AgentsManifestTests/CompiledFixtures.swift')], check=True)
