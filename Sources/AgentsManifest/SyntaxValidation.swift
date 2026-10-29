import AgentsCore
import Foundation
import SwiftParser
import SwiftSyntax

package struct CheckedSyntax: Sendable {
  package let tree: SourceFileSyntax
  package let metrics: FrontEndMetrics
}

package enum SyntaxValidation {
  /// All-nodes view, with cached lengths only until the complete tree fits.
  package static func guardTree(_ root: Syntax, source: SourceText) throws -> (
    nodes: Int, depth: Int
  ) {
    var pending: [(Syntax, Int, Int)] = [(root, 1, 0)]
    var scheduled = 1
    var count = 0
    var maximum = 0
    while let (node, depth, offset) = pending.popLast() {
      if depth > 128 { throw source.failure("manifest.limit", "syntax tree depth", offset) }
      count += 1
      maximum = max(maximum, depth)
      var childOffset = offset
      for child in node.children(viewMode: .all) {
        if scheduled == 100_000 {
          throw source.failure("manifest.limit", "syntax tree nodes", childOffset)
        }
        if depth == 128 { throw source.failure("manifest.limit", "syntax tree depth", childOffset) }
        scheduled += 1
        pending.append((child, depth + 1, childOffset))
        childOffset += child.totalLength.utf8Length
      }
    }
    return (count, maximum)
  }

  package static func parse(
    _ source: SourceText, admission: Admission, metrics initial: FrontEndMetrics
  ) throws -> CheckedSyntax {
    var metrics = initial
    let clock = ContinuousClock()
    let parseStart = clock.now
    let tree = source.bytes.withUnsafeBufferPointer {
      Parser.parse(source: $0, maximumNestingLevel: 20)
    }
    metrics.parserCalls += 1
    metrics.parsingSeconds = seconds(parseStart.duration(to: clock.now))
    let guardStart = clock.now
    do {
      let bounds = try guardTree(Syntax(tree), source: source)
      metrics.syntaxNodes = bounds.nodes
      metrics.syntaxDepth = bounds.depth
    } catch let failure as ManifestFailure {
      throw ManifestFailure(failure.diagnostics[0], metrics: metrics)
    }
    metrics.guardSeconds = seconds(guardStart.duration(to: clock.now))
    let inspectionStart = clock.now
    if tree.hasError {
      throw ManifestFailure(
        ManifestDiagnostic(
          code: "manifest.syntax", message: "SwiftParser disagreed with grammar admission",
          span: source.span(0..<0)), metrics: metrics)
    }
    // This independent projection is also a dependency-upgrade regression gate.
    let actual = projection(Syntax(tree), source: source)
    guard actual == admission.projection, metrics.syntaxNodes <= admission.reservation else {
      let offset = zip(actual, admission.projection).first(where: { $0 != $1 })?.0.start ?? 0
      throw ManifestFailure(
        ManifestDiagnostic(
          code: "manifest.syntax",
          message: "SwiftParser projection or syntax reservation disagreed with admission",
          span: source.span(offset..<offset)), metrics: metrics)
    }
    metrics.inspectionSeconds = seconds(inspectionStart.duration(to: clock.now))
    return CheckedSyntax(tree: tree, metrics: metrics)
  }

  package static func projection(_ root: Syntax, source: SourceText) -> [ProjectionEvent] {
    var pending = [root]
    var events: [ProjectionEvent] = []
    func emit(_ node: Syntax, _ kind: String, _ detail: String = "") {
      events.append(
        ProjectionEvent(
          start: node.positionAfterSkippingLeadingTrivia.utf8Offset,
          end: node.endPositionBeforeTrailingTrivia.utf8Offset, kind: kind, detail: detail))
    }
    func literal(_ node: Syntax, _ kind: String) {
      emit(
        node, kind,
        source.spelling(
          node.positionAfterSkippingLeadingTrivia
            .utf8Offset..<node.endPositionBeforeTrailingTrivia.utf8Offset))
    }
    while let node = pending.popLast() {
      if let value = node.as(ImportDeclSyntax.self) {
        emit(node, "import", value.path.first?.name.text ?? "")
      } else if let value = node.as(VariableDeclSyntax.self) {
        emit(
          node, "let",
          value.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? "")
      } else if let value = node.as(MemberAccessExprSyntax.self) {
        emit(node, "member", value.declName.baseName.text)
        if let base = value.base { pending.append(Syntax(base)) }
        continue
      } else if let value = node.as(DeclReferenceExprSyntax.self) {
        emit(node, "reference", value.baseName.text)
      } else if let value = node.as(BinaryOperatorExprSyntax.self), value.operator.text == "..<" {
        emit(node, "reference", "..<")
      } else if let value = node.as(LabeledExprSyntax.self), let label = value.label {
        emit(Syntax(label), "label", label.text)
      } else if let value = node.as(IdentifierTypeSyntax.self) {
        emit(node, "type", value.name.text)
      } else if node.is(ArrayTypeSyntax.self) {
        emit(node, "arrayType")
      } else if node.is(DictionaryTypeSyntax.self) {
        emit(node, "dictionaryType")
      } else if node.is(FunctionCallExprSyntax.self) {
        emit(node, "call")
      } else if node.is(ArrayExprSyntax.self) {
        emit(node, "array")
      } else if node.is(DictionaryExprSyntax.self) {
        emit(node, "dictionary")
      } else if node.is(TupleExprSyntax.self) {
        emit(node, "group")
      } else if node.is(SequenceExprSyntax.self) {
        emit(node, "sequence")
      } else if node.is(PrefixOperatorExprSyntax.self) {
        emit(node, "negative")
      } else if node.is(IntegerLiteralExprSyntax.self) {
        literal(node, "integer")
      } else if node.is(StringLiteralExprSyntax.self) {
        literal(node, "string")
      } else if node.is(BooleanLiteralExprSyntax.self) {
        literal(node, "boolean")
      } else if node.is(NilLiteralExprSyntax.self) {
        literal(node, "nil")
      }
      pending.append(contentsOf: node.children(viewMode: .all))
    }
    return events.sorted()
  }
}

package func seconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
