#!/usr/bin/env python3
"""Generate authoring declarations and static registrations from the language inventory."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = json.loads((ROOT / 'Scripts/ManifestVocabulary.json').read_text())
DEST = ROOT / 'Sources/AgentsDescription'
HEADER = '// Generated from Scripts/ManifestVocabulary.json. Run Scripts/generate-manifest-vocabulary.py.\n\n'


def type_expr(t):
    if t == 'NativeConfiguration':
        return '.dictionary(.dictionary(.named("ConfigurationValue")))'
    if t.endswith('?'):
        return '.optional(' + type_expr(t[:-1]) + ')'
    if t.startswith('['):
        inner = t[1:-1]
        if inner.startswith('String: '):
            return '.dictionary(' + type_expr(inner[8:]) + ')'
        return '.array(' + type_expr(inner) + ')'
    if t == 'Range<Version>':
        return '.named("VersionRange")'
    return '.named(' + json.dumps(t) + ')'


def signature(p):
    ext = p['label']
    name = p['name']
    s = (ext + ' ' if ext != name else '') + name + ': ' + p['type']
    if 'default' in p:
        s += ' = ' + p['default']
    return s


def default_expr(p):
    if 'default' not in p:
        return 'nil'
    return '(' + p['default'] + ' as ' + p['type'] + ').constructionValue'


lines = [HEADER]
for name, cases in SPEC['enums'].items():
    recursive = 'indirect ' if name == 'ConfigurationValue' else ''
    protocols = ['Sendable', 'Equatable'] + SPEC['literals'].get(name, {}).get('protocols', [])
    lines.append(f'public {recursive}enum {name}: ' + ', '.join(protocols) + ' {')
    for c in cases:
        ps = c.get('parameters', [])
        decl = c['name']
        if ps:
            decl += '(' + ', '.join((p['label'] + ': ' if p['label'] != '_' else '') + p['type'] for p in ps) + ')'
        lines.append('  case ' + decl)
    for init in SPEC['literals'].get(name, {}).get('initializers', []):
        lines.append('  ' + init)
    lines += ['}', '', f'extension {name}: ConstructionRepresentable {{', '  package var constructionValue: ConstructionValue {', '    switch self {']
    for c in cases:
        ps = c.get('parameters', [])
        pattern = '.' + c['name']
        if ps:
            pattern += '(' + ', '.join('let ' + p['name'] for p in ps) + ')'
        fields = ', '.join(json.dumps(p['name']) + ': ' + p['name'] + '.constructionValue' for p in ps)
        lines.append(f'    case {pattern}: .node(type: "{name}", member: "{c["name"]}", fields: [' + (fields or ':') + '])')
    lines += ['    }', '  }', '}', '']

for name in SPEC['structs']:
    protocols = ['Sendable', 'Equatable'] + SPEC['literals'].get(name, {}).get('protocols', [])
    lines += [f'public struct {name}: ' + ', '.join(protocols) + ' {', '  private let storage: ConstructionValue', '  package var constructionValue: ConstructionValue { storage }', '  package init(value: ConstructionValue) { storage = value }']
    for init in SPEC['literals'].get(name, {}).get('initializers', []):
        lines.append('  ' + init)
    for m in SPEC['factories']:
        if m['type'] != name:
            continue
        if m.get('property'):
            lines.append(f'  public static var {m["name"]}: {name} {{ Self(value: .node(type: "{name}", member: "{m["name"]}", fields: [:])) }}')
            continue
        ps = m['parameters']
        decl = 'public init' if name == 'Agents' else 'public static func ' + m['name']
        decl += '(' + ', '.join(signature(p) for p in ps) + ')'
        if name != 'Agents':
            decl += ' -> ' + name
        fields = ', '.join(json.dumps(p['name']) + ': ' + p['name'] + '.constructionValue' for p in ps)
        construct = f'ConstructionValue.construct(type: "{name}", member: "{m["name"]}", fields: [' + (fields or ':') + '])'
        body = 'self.init(value: ' + construct + ')' if name == 'Agents' else 'Self(value: ' + construct + ')'
        lines.append('  ' + decl + ' { ' + body + ' }')
    lines += ['}', f'extension {name}: ConstructionRepresentable {{}}', '']
lines += ['public typealias NativeConfiguration = [String: [String: ConfigurationValue]]', '']
(DEST / 'Vocabulary.swift').write_text('\n'.join(lines))

reg = [HEADER, 'package enum Vocabulary {', '  package static let typeNames: Set<String> = [' + ', '.join(json.dumps(n) for n in ['String', 'Int', 'Bool', 'Version', 'NativeConfiguration'] + list(SPEC['enums']) + SPEC['structs']) + ']', '  package static let signatures: [ConstructionSignature] = [']
for m in SPEC['factories'] + [dict(type=n, name=c['name'], parameters=c.get('parameters', []), enumCase=True) for n, cases in SPEC['enums'].items() for c in cases]:
    ps = ', '.join('ConstructionParameter(label: ' + json.dumps(p['label']) + ', name: ' + json.dumps(p['name']) + ', type: ' + type_expr(p['type']) + ', defaultValue: ' + default_expr(p) + ')' for p in m.get('parameters', []))
    reg.append('    ConstructionSignature(type: ' + json.dumps(m['type']) + ', member: ' + json.dumps(m['name']) + ', parameters: [' + ps + '], callable: ' + str(not m.get('property') and (not m.get('enumCase') or bool(m.get('parameters')))).lower() + '),')
# Range factories are only contextual at their grammar slot.
for name in ['upToNextMajor', 'upToNextMinor']:
    reg.append('    ConstructionSignature(type: "VersionRange", member: "' + name + '", parameters: [ConstructionParameter(label: "from", name: "from", type: .named("Version"), defaultValue: nil)], callable: true),')
reg += ['  ]', '  package static let literalTypes: [String: Set<String>] = [']
for n, lit in SPEC['literals'].items():
    reg.append('    ' + json.dumps(n) + ': [' + ', '.join(json.dumps(x) for x in lit['kinds']) + '],')
reg += ['  ]', '}', '']
(DEST / 'VocabularyInventory.swift').write_text('\n'.join(reg))

import subprocess
subprocess.run(["swift", "format", "format", "--in-place", "--configuration", str(ROOT / ".swift-format"), str(ROOT / 'Sources/AgentsDescription/Vocabulary.swift'), str(ROOT / 'Sources/AgentsDescription/VocabularyInventory.swift')], check=True)
