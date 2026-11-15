#!/usr/bin/env python3
"""Guard the bundled schema compiler's accepted validation semantics."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('manifest_schema', Path(__file__).with_name('generate-manifest-schema.py'))
compiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compiler)


class SchemaCompilerTests(unittest.TestCase):
    def test_schema_values_drive_runtime_constraints_and_help(self):
        schema = {
            'type': 'object', 'additionalProperties': False, '$defs': {},
            'properties': {
                'version': {'type': 'integer', 'const': 2},
                'items': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 3},
                'names': {'type': 'object', 'additionalProperties': {'type': 'string'}, 'maxProperties': 4},
                'record': {'type': 'object', 'additionalProperties': False, 'maxProperties': 0},
                'count': {'type': 'integer', 'minimum': 5},
            },
        }
        swift, help_text = compiler.compile_schema(schema)
        for expected in ['.integerConstant(2)', '.array(.string, maximum: 3)',
                         '.dictionary(.string, maximum: 4)', '.object([:], required: [], maximum: 0)',
                         '.integer(minimum: 5)']:
            self.assertIn(expected, swift)
        for expected in ['`2`', 'at most 3 items', 'at most 4 properties', 'at most 0 properties', 'integer ≥ 5']:
            self.assertIn(expected, help_text)

    def test_validation_siblings_are_not_discarded(self):
        for shape in [{'$ref': '#/$defs/string'}, {'oneOf': [{'type': 'string'}]},
                      {'x-agents-native-value': True}, {'const': 'a'}, {'enum': ['a']}]:
            with self.subTest(shape=shape), self.assertRaises(ValueError):
                compiler.emit({**shape, 'maxItems': 1}, {'string': {'type': 'string'}})
        for shape in [{'type': 'string', 'minimum': 1}, {'type': 'array', 'items': {'type': 'string'}, 'maxProperties': 1},
                      {'type': 'object', 'additionalProperties': {'type': 'string'}, 'properties': {}}]:
            with self.subTest(shape=shape), self.assertRaises(ValueError):
                compiler.emit(shape, {})

    def test_unsupported_values_are_rejected(self):
        for shape in [{'const': True}, {'const': 2.5}, {'type': 'integer', 'const': 2 ** 63},
                      {'const': 'a', 'type': 'integer'}, {'enum': [1]}, {'enum': []},
                      {'type': 'object', 'additionalProperties': True}, {'type': 'object'},
                      {'x-agents-native-value': False}, {'oneOf': []}, {'$ref': 'external'},
                      {'$ref': '#/$defs/missing'}, {'type': 'integer', 'x-agents-scalar-kind': 'float'},
                      {'type': 'object', 'additionalProperties': False, 'required': ['absent']}]:
            with self.subTest(shape=shape), self.assertRaises(ValueError):
                compiler.emit(shape, {})
        for maximum in [-1, True, 1.5, 2 ** 63]:
            for shape in [{'type': 'array', 'items': {'type': 'string'}, 'maxItems': maximum},
                          {'type': 'object', 'additionalProperties': False, 'maxProperties': maximum}]:
                with self.subTest(shape=shape), self.assertRaises(ValueError):
                    compiler.emit(shape, {})


if __name__ == '__main__':
    unittest.main()
