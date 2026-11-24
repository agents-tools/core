import AgentsManifest

#if DEBUG
  package let probeConfiguration = "debug"
  package let probeWatchdogSeconds = 30.0
#else
  package let probeConfiguration = "release"
  package let probeWatchdogSeconds = 2.0
#endif

package enum ProbeOperation: String, Codable {
  case frontEnd, editing
}

/// Wire format shared by the watchdog parent and its isolated child.
package struct ProbeReport: Codable {
  package let configuration: String
  package let status: String
  package let operation: ProbeOperation
  package let stage: FrontEndStage?
  package let offset: Int
  package let line: Int
  package let column: Int
  package let message: String
  package let metrics: FrontEndMetrics
  package let peakMemoryBytes: UInt64
  /// Process RSS high-water mark before preparation, including earlier allocations.
  package let preparationBaselinePeakBytes: UInt64?

  package var preparationPeakGrowthBytes: UInt64? {
    preparationBaselinePeakBytes.map { baseline in
      peakMemoryBytes > baseline ? peakMemoryBytes - baseline : 0
    }
  }

  package init(
    status: String, operation: ProbeOperation = .frontEnd, stage: FrontEndStage? = nil,
    offset: Int = 0, line: Int = 1, column: Int = 1,
    message: String = "", metrics: FrontEndMetrics, peakMemoryBytes: UInt64,
    preparationBaselinePeakBytes: UInt64? = nil
  ) {
    configuration = probeConfiguration
    self.status = status
    self.operation = operation
    self.stage = stage
    self.offset = offset
    self.line = line
    self.column = column
    self.message = message
    self.metrics = metrics
    self.peakMemoryBytes = peakMemoryBytes
    self.preparationBaselinePeakBytes = preparationBaselinePeakBytes
  }
}
