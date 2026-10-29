import AgentsManifest

#if DEBUG
  package let probeConfiguration = "debug"
  package let probeWatchdogSeconds = 30.0
#else
  package let probeConfiguration = "release"
  package let probeWatchdogSeconds = 2.0
#endif

/// Wire format shared by the watchdog parent and its isolated child.
package struct ProbeReport: Codable {
  package let configuration: String
  package let status: String
  package let stage: FrontEndStage
  package let offset: Int
  package let line: Int
  package let column: Int
  package let message: String
  package let metrics: FrontEndMetrics
  package let peakMemoryBytes: UInt64

  package init(
    status: String, stage: FrontEndStage, offset: Int = 0, line: Int = 1, column: Int = 1,
    message: String = "", metrics: FrontEndMetrics, peakMemoryBytes: UInt64
  ) {
    configuration = probeConfiguration
    self.status = status
    self.stage = stage
    self.offset = offset
    self.line = line
    self.column = column
    self.message = message
    self.metrics = metrics
    self.peakMemoryBytes = peakMemoryBytes
  }
}
