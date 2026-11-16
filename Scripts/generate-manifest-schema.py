#!/usr/bin/env python3
"""Compile the finite field shapes used by the shipped manifest schema."""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ANNOTATIONS = {'title', 'description', 'examples'}
INTEGER_MIN = -(2 ** 63)
INTEGER_MAX = 2 ** 63 - 1


def q(value):
    escapes = {'"': '\\"', '\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t'}
    return '"' + ''.join(escapes.get(c, '\\u{' + format(ord(c), 'x') + '}' if ord(c) < 32 else c)
                         for c in value) + '"'


def integer(value, name, minimum=INTEGER_MIN):
    if type(value) is not int or not minimum <= value <= INTEGER_MAX:
        raise ValueError(f'{name} must be an integer in {minimum}...{INTEGER_MAX}')
    return str(value)


def emit(value, definitions, *, root=False):
    if not isinstance(value, dict):
        raise ValueError('field shapes must be schema objects')

    def allow(keys):
        accepted = set(keys) | ANNOTATIONS
        if root:
            accepted |= {'$schema', '$id', '$defs'}
        unsupported = set(value) - accepted
        if unsupported:
            raise ValueError('unsupported schema keywords or combination: ' + ', '.join(sorted(unsupported)))

    for key in ('title', 'description', '$schema', '$id'):
        if key in value and not isinstance(value[key], str):
            raise ValueError(key + ' must be a string')
    if 'examples' in value and not isinstance(value['examples'], list):
        raise ValueError('examples must be an array')
    if '$ref' in value:
        allow({'$ref'})
        ref = value['$ref']
        if not isinstance(ref, str) or not ref.startswith('#/$defs/') or ref[8:] not in definitions:
            raise ValueError('expected a reference to a bundled definition')
        return '.named(' + q(ref[8:]) + ')'
    if 'x-agents-native-value' in value:
        allow({'x-agents-native-value'})
        if value['x-agents-native-value'] is not True:
            raise ValueError('x-agents-native-value must be true')
        return '.native'
    if 'oneOf' in value:
        allow({'oneOf'})
        choices = value['oneOf']
        if not isinstance(choices, list) or not choices:
            raise ValueError('oneOf must contain field shapes')
        return '.oneOf([' + ', '.join(emit(x, definitions) for x in choices) + '])'
    if 'const' in value:
        allow({'const', 'type', 'x-agents-scalar-kind'})
        literal = value['const']
        if isinstance(literal, str) and value.get('type', 'string') == 'string':
            if 'x-agents-scalar-kind' in value:
                raise ValueError('scalar-kind is supported only on integers')
            return '.constant(' + q(literal) + ')'
        if type(literal) is int and value.get('type') == 'integer':
            if value.get('x-agents-scalar-kind', 'integer') != 'integer':
                raise ValueError('unsupported scalar-kind')
            return '.integerConstant(' + integer(literal, 'const') + ')'
        raise ValueError('const supports strings and typed integers')
    if 'enum' in value:
        allow({'enum', 'type'})
        choices = value['enum']
        if (value.get('type', 'string') != 'string' or not isinstance(choices, list)
                or not choices or any(not isinstance(x, str) for x in choices)
                or len(set(choices)) != len(choices)):
            raise ValueError('enum must contain unique strings')
        return '.enumeration([' + ', '.join(q(x) for x in choices) + '])'
    kind = value.get('type')
    if kind == 'string':
        allow({'type'})
        return '.string'
    if kind == 'integer':
        allow({'type', 'minimum', 'x-agents-scalar-kind'})
        if value.get('x-agents-scalar-kind', 'integer') != 'integer':
            raise ValueError('unsupported scalar-kind')
        return '.integer(minimum: ' + integer(value.get('minimum', INTEGER_MIN), 'minimum') + ')'
    if kind == 'array':
        allow({'type', 'items', 'maxItems'})
        if 'items' not in value:
            raise ValueError('arrays require an item shape')
        maximum = integer(value['maxItems'], 'maxItems', 0) if 'maxItems' in value else 'nil'
        return '.array(' + emit(value['items'], definitions) + ', maximum: ' + maximum + ')'
    if kind == 'object':
        allow({'type', 'properties', 'required', 'additionalProperties', 'maxProperties'})
        maximum = integer(value['maxProperties'], 'maxProperties', 0) if 'maxProperties' in value else 'nil'
        additional = value.get('additionalProperties')
        if isinstance(additional, dict):
            if 'properties' in value or 'required' in value:
                raise ValueError('dictionary shapes cannot also declare fixed fields or required keys')
            return '.dictionary(' + emit(additional, definitions) + ', maximum: ' + maximum + ')'
        if additional is not False:
            raise ValueError('objects require false or a field shape for additionalProperties')
        properties = value.get('properties', {})
        required = value.get('required', [])
        if not isinstance(properties, dict) or any(not isinstance(x, str) for x in properties):
            raise ValueError('properties must map field names to shapes')
        if (not isinstance(required, list) or any(not isinstance(x, str) for x in required)
                or len(set(required)) != len(required) or not set(required) <= set(properties)):
            raise ValueError('required must contain unique declared field names')
        fields = ', '.join(q(k) + ': ' + emit(v, definitions) for k, v in properties.items())
        return ('.object([' + (fields or ':') + '], required: [' + ', '.join(q(x) for x in required)
                + '], maximum: ' + maximum + ')')
    raise ValueError('unsupported field shape: ' + str(kind))


def describe(value):
    if '$ref' in value:
        return value['$ref'].removeprefix('#/$defs/')
    if 'x-agents-native-value' in value:
        return 'NativeValue'
    if 'const' in value:
        return '`' + str(value['const']) + '`'
    if 'enum' in value:
        return ' / '.join('`' + str(x) + '`' for x in value['enum'])
    if 'oneOf' in value:
        return 'one of: ' + ', '.join(describe(x) for x in value['oneOf'])
    kind = value['type']
    if kind == 'array':
        shape = 'sequence of ' + describe(value['items'])
        return shape + (f" (at most {value['maxItems']} items)" if 'maxItems' in value else '')
    if kind == 'object':
        shape = ('name → ' + describe(value['additionalProperties'])
                 if isinstance(value['additionalProperties'], dict) else 'mapping')
        return shape + (f" (at most {value['maxProperties']} properties)" if 'maxProperties' in value else '')
    if kind == 'integer' and 'minimum' in value:
        return 'integer ≥ ' + str(value['minimum'])
    return kind


def table_text(text):
    return text.replace('&', '&amp;').replace('|', '&#124;').replace('`', '&#96;').replace('\n', '<br>')


def examples(value):
    return ', '.join('<code>' + table_text(json.dumps(example, ensure_ascii=False)).replace('<', '&lt;')
                     .replace('>', '&gt;') + '</code>' for example in value.get('examples', []))


def field_help(value, level=3):
    text = value.get('description', '')
    text = text + '\n\n' if text else ''
    if value.get('examples'):
        text += 'Examples: ' + examples(value) + '\n\n'
    if 'properties' in value:
        if 'maxProperties' in value:
            text += describe(value) + '\n\n'
        text += '| Field | Required | Shape | Description |\n| --- | --- | --- | --- |\n'
        for key, field in value['properties'].items():
            details = table_text(field.get('description', ''))
            if field.get('examples'):
                details += ('<br>' if details else '') + 'Examples: ' + examples(field)
            text += ('| `' + key + '` | ' + ('yes' if key in value.get('required', []) else '')
                     + ' | ' + describe(field) + ' | ' + details + ' |\n')
    elif 'oneOf' not in value:
        text += describe(value) + '\n'
    for index, branch in enumerate(value.get('oneOf', []), 1):
        text = text.rstrip('\n') + '\n\n' + '#' * level + ' Alternative ' + str(index) + '\n\n'
        text += field_help(branch, level + 1)
    return text


def compile_schema(schema):
    if not isinstance(schema, dict) or not isinstance(schema.get('$defs'), dict):
        raise ValueError('the bundled schema requires named definitions')
    if schema.get('$schema', 'https://json-schema.org/draft/2020-12/schema') != 'https://json-schema.org/draft/2020-12/schema':
        raise ValueError('the bundled schema uses the 2020-12 dialect')
    definitions = schema['$defs']
    if any(not isinstance(name, str) or not name or '/' in name or '~' in name for name in definitions):
        raise ValueError('definition names must be nonempty, unescaped pointer segments')
    text = ('// Generated by Scripts/generate-manifest-schema.py.\n\nenum ManifestSchema {\n'
            + '  static let root: YAMLRule = ' + emit(schema, definitions, root=True)
            + '\n  static let definitions: [String: YAMLRule] = [\n')
    text += ''.join('    ' + q(k) + ': ' + emit(v, definitions) + ',\n' for k, v in definitions.items())
    text += '  ]\n}\n'
    help_text = ('# Manifest Field Shapes\n\n'
                 'Generated from `Sources/AgentsManifest/Resources/agents.schema.json`.\n')
    for name, definition in [('Declaration', schema)] + list(definitions.items()):
        help_text += '\n## ' + name + '\n\n'
        help_text += field_help(definition)
    return text, help_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    schema = json.loads((ROOT / 'Sources/AgentsManifest/Resources/agents.schema.json').read_text())
    text, help_text = compile_schema(schema)
    text = subprocess.run(['xcrun', 'swift-format', 'format', '--configuration', str(ROOT / '.swift-format')],
                          input=text, text=True, capture_output=True, check=True).stdout
    outputs = {ROOT / 'Sources/AgentsManifest/ManifestSchema.swift': text,
               ROOT / 'Documentation/Reference/ManifestSchema.md': help_text}
    for path, contents in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != contents:
                raise SystemExit('generated manifest schema/help is stale: ' + str(path))
        else:
            path.write_text(contents)


if __name__ == '__main__':
    main()
