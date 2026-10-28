import Foundation
import Testing

@testable import AgentsSkills

@Suite("Artifact networking")
struct NetworkingTests {
  @Test func defaultFetcherLoadsHTTPData() throws {
    // Exercise the default loader: injected fetch closures cannot detect a
    // missing FoundationNetworking linkage on Linux. The child alarm bounds I/O.
    let script = """
      use IO::Socket::INET;
      alarm 15;
      my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp'
      ) or die $!;
      $| = 1;
      print $server->sockport, "\\n";
      my $client = $server->accept() or die $!;
      while (my $line = <$client>) { last if $line eq "\\r\\n"; }
      print $client "HTTP/1.1 200 OK\\r\\nContent-Length: 8\\r\\nConnection: close\\r\\n\\r\\nartifact";
      close $client;
      """
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", script]
    process.standardOutput = output
    try process.run()
    output.fileHandleForWriting.closeFile()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
    }
    var bytes = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
      if byte == Data([10]) { break }
      bytes.append(byte)
    }
    let port = try #require(Int(String(decoding: bytes, as: UTF8.self)))
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/artifact"))
    #expect(try WellKnownProvider().fetch(url) == Data("artifact".utf8))
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
