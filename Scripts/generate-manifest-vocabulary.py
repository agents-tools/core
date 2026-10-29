#!/usr/bin/env python3
"""Generate authoring types, evaluation metadata and editor factories from one inventory."""
import sys

# Imports must not leave bytecode caches in the source tree.
sys.dont_write_bytecode = True

import json
from pathlib import Path

from manifest_generation import run_generator

ROOT = Path(__file__).resolve().parent.parent
SPEC = json.loads((ROOT / "Scripts/ManifestVocabulary.json").read_text())
HEADER = "// Generated from Scripts/ManifestVocabulary.json. Run Scripts/generate-manifest-vocabulary.py.\n"


def quoted(value):
    return json.dumps(value, ensure_ascii=False)


def type_expression(spelling):
    if spelling in SPEC["aliases"]:
        return type_expression(SPEC["aliases"][spelling])
    if spelling.endswith("?"):
        return ".optional(" + type_expression(spelling[:-1]) + ")"
    if spelling.startswith("["):
        inner = spelling[1:-1]
        if inner.startswith("String: "):
            return ".dictionary(" + type_expression(inner[8:]) + ")"
        return ".array(" + type_expression(inner) + ")"
    if spelling in SPEC["contextualTypes"]:
        return ".named(" + quoted(SPEC["contextualTypes"][spelling]) + ")"
    return ".named(" + quoted(spelling) + ")"


def parameters_declaration(parameters):
    result = []
    for parameter in parameters:
        label, name = parameter["label"], parameter["name"]
        spelling = (label + " " if label != name else "") + name + ": " + parameter["type"]
        if "default" in parameter:
            spelling += " = " + parameter["default"]
        result.append(spelling)
    return ", ".join(result)


def fields_expression(parameters):
    return dictionary_expression({p["name"]: p["name"] + ".constructionValue" for p in parameters})


def dictionary_expression(fields):
    return "[" + (", ".join(quoted(k) + ": " + v for k, v in fields.items()) or ":") + "]"


def literal_initializers(name):
    result = []
    for kind, conversion in SPEC["literals"].get(name, {}).get("conversions", {}).items():
        payload_type = conversion.get("payloadType")
        if kind == "nil":
            declaration, payload = "nilLiteral: ()", None
        elif kind == "array":
            declaration, payload = "arrayLiteral elements: " + payload_type[1:-1] + "...", "elements"
        elif kind == "dictionary":
            element_type = payload_type[len("[String: "):-1]
            declaration = "dictionaryLiteral elements: (String, " + element_type + ")..."
            payload = "Dictionary(elements, uniquingKeysWith: { _, last in last })"
        else:
            declaration, payload = kind + "Literal value: " + payload_type, "value"
        member = conversion["member"]
        if name in SPEC["enums"]:
            body = "self = ." + member + ("(" + payload + ")" if payload else "")
        else:
            fields = {k: ".none" if v == "nil" else v for k, v in conversion.get("defaults", {}).items()}
            if payload:
                fields[conversion["payload"]] = payload + ".constructionValue"
            body = "self.init(value: .construct(type: " + quoted(name) + ", member: " + quoted(member) + ", fields: " + dictionary_expression(fields) + "))"
        result.append("  public init(" + declaration + ") { " + body + " }")
    return result


def authoring_source():
    lines = [HEADER]
    for name, cases in SPEC["enums"].items():
        recursive = "indirect " if name in SPEC["recursiveEnums"] else ""
        protocols = ["Sendable", "Equatable"] + SPEC["literals"].get(name, {}).get("protocols", [])
        lines.append("public " + recursive + "enum " + name + ": " + ", ".join(protocols) + " {")
        for case in cases:
            parameters = case.get("parameters", [])
            declaration = case["name"]
            if parameters:
                declaration += "(" + ", ".join((p["label"] + ": " if p["label"] != "_" else "") + p["type"] for p in parameters) + ")"
            lines.append("  case " + declaration)
        lines += literal_initializers(name)
        lines += ["}", "", "extension " + name + ": ConstructionRepresentable {", "  package var constructionValue: ConstructionValue {", "    switch self {"]
        for case in cases:
            parameters = case.get("parameters", [])
            pattern = "." + case["name"]
            if parameters:
                pattern += "(" + ", ".join("let " + p["name"] for p in parameters) + ")"
            lines.append("    case " + pattern + ": .node(type: " + quoted(name) + ", member: " + quoted(case["name"]) + ", fields: " + fields_expression(parameters) + ")")
        lines += ["    }", "  }", "}", ""]
    for name in SPEC["structs"]:
        protocols = ["Sendable", "Equatable"] + SPEC["literals"].get(name, {}).get("protocols", [])
        lines += ["public struct " + name + ": " + ", ".join(protocols) + " {", "  private let storage: ConstructionValue", "  package var constructionValue: ConstructionValue { storage }", "  package init(value: ConstructionValue) { storage = value }"]
        lines += literal_initializers(name)
        for factory in SPEC["factories"]:
            if factory["type"] != name:
                continue
            member = factory["name"]
            parameters = factory.get("parameters", [])
            construct = "ConstructionValue.construct(type: " + quoted(name) + ", member: " + quoted(member) + ", fields: " + fields_expression(parameters) + ")"
            if factory.get("property"):
                declaration = "public static var " + member + ": " + name
                body = "Self(value: " + construct + ")"
            elif factory.get("initializer"):
                declaration = "public init(" + parameters_declaration(parameters) + ")"
                body = "self.init(value: " + construct + ")"
            else:
                declaration = "public static func " + member + "(" + parameters_declaration(parameters) + ") -> " + name
                body = "Self(value: " + construct + ")"
            lines.append("  " + declaration + " { " + body + " }")
        lines += ["}", "extension " + name + ": ConstructionRepresentable {}", ""]
    for name, spelling in SPEC["aliases"].items():
        lines += ["public typealias " + name + " = " + spelling, ""]
    return "\n".join(lines)


def registration_source():
    type_names = SPEC["primitiveTypes"] + SPEC["customTypes"] + list(SPEC["aliases"]) + list(SPEC["enums"]) + SPEC["structs"]
    lines = [HEADER, "package enum Vocabulary {", "  package static let typeNames: Set<String> = [" + ", ".join(map(quoted, type_names)) + "]", "  package static let signatures: [ConstructionSignature] = ["]
    enum_cases = [dict(type=name, name=case["name"], parameters=case.get("parameters", []), enumCase=True) for name, cases in SPEC["enums"].items() for case in cases]
    for factory in SPEC["factories"] + enum_cases + SPEC["rangeFactories"]:
        parameters = []
        for parameter in factory.get("parameters", []):
            default = parameter.get("default")
            value = "nil" if default is None else "(" + default + " as " + parameter["type"] + ").constructionValue"
            parameters.append("ConstructionParameter(label: " + quoted(parameter["label"]) + ", name: " + quoted(parameter["name"]) + ", type: " + type_expression(parameter["type"]) + ", defaultValue: " + value + ")")
        callable_member = not factory.get("property") and (not factory.get("enumCase") or bool(factory.get("parameters")))
        lines.append("    ConstructionSignature(type: " + quoted(factory["type"]) + ", member: " + quoted(factory["name"]) + ", parameters: [" + ", ".join(parameters) + "], callable: " + str(callable_member).lower() + "),")
    lines += ["  ]", "  package static let literalTypes: [String: Set<LiteralKind>] = ["]
    literal_case = lambda kind: ".nilLiteral" if kind == "nil" else "." + kind
    for name, literal in SPEC["literals"].items():
        lines.append("    " + quoted(name) + ": [" + ", ".join(map(literal_case, literal["kinds"])) + "],")
    lines += ["  ]", "  package static let literalConstructions: [String: [LiteralKind: LiteralConstruction]] = ["]
    for name, literal in SPEC["literals"].items():
        if not literal["conversions"]:
            continue
        lines.append("    " + quoted(name) + ": [")
        for kind, conversion in literal["conversions"].items():
            defaults = {k: ".none" if v == "nil" else v for k, v in conversion.get("defaults", {}).items()}
            lines.append("      " + literal_case(kind) + ": LiteralConstruction(member: " + quoted(conversion["member"]) + ", payload: " + (quoted(conversion["payload"]) if "payload" in conversion else "nil") + ", payloadType: " + (type_expression(conversion["payloadType"]) if "payloadType" in conversion else "nil") + ", defaults: " + dictionary_expression(defaults) + "),")
        lines.append("    ],")
    lines += ["  ]", "  package static let scalarValues: [String: [String: String]] = ["]
    for name, cases in SPEC["enums"].items():
        if all(not case.get("parameters") for case in cases):
            fields = {case["name"]: quoted(case.get("loweredValue", case["name"])) for case in cases}
            lines.append("    " + quoted(name) + ": " + dictionary_expression(fields) + ",")
    lines += ["  ]", "  package static let taggedRecordTypes: Set<String> = [" + ", ".join(map(quoted, SPEC["taggedRecordTypes"])) + "]", "  package static let aliasTypes: [String: ConstructionType] = " + dictionary_expression({k: type_expression(v) for k, v in SPEC["aliases"].items()}), "}", ""]
    return "\n".join(lines)


def editor_factories_source():
    lines = [HEADER, "import AgentsDescription", "", "extension StaticValue {"]
    for factory in SPEC["staticValueFactories"]:
        name, value_type = factory["name"], factory["type"]
        lines += ["  public static func " + name + "(_ value: AgentsDescription." + value_type + ") -> Self {", "    Self.checked(value.constructionValue, type: .named(" + quoted(value_type) + "))", "  }"]
    return "\n".join(lines + ["}", ""])


def main():
    outputs = {
        Path("Sources/AgentsDescription/Vocabulary.swift"): authoring_source(),
        Path("Sources/AgentsDescription/VocabularyInventory.swift"): registration_source(),
        Path("Sources/AgentsManifest/StaticValueVocabulary.swift"): editor_factories_source(),
    }
    run_generator(outputs, repository=ROOT, generator=Path(__file__).resolve())


if __name__ == "__main__":
    main()
