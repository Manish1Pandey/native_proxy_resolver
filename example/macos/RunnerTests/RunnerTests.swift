import Foundation
import FlutterMacOS
import XCTest

@testable import native_proxy_resolver

/// Exercises the real CFNetwork code paths of the plugin.
class RunnerTests: XCTestCase {

  func testResolveReturnsEntriesForTheSystemConfiguration() {
    let plugin = NativeProxyResolverPlugin()
    let call = FlutterMethodCall(
      methodName: "resolve",
      arguments: ["url": "https://example.com/", "timeoutMs": 5000])
    let done = expectation(description: "result block must be called")
    plugin.handle(call) { result in
      let reply = result as? [String: Any]
      XCTAssertNotNil(reply)
      let entries = reply?["entries"] as? [[String: Any]] ?? []
      XCTAssertFalse(entries.isEmpty)
      XCTAssertNotNil(reply?["source"] as? String)
      done.fulfill()
    }
    waitForExpectations(timeout: 10)
  }

  func testRejectsRelativeUrl() {
    let plugin = NativeProxyResolverPlugin()
    let call = FlutterMethodCall(methodName: "resolve", arguments: ["url": "/relative"])
    let done = expectation(description: "result block must be called")
    plugin.handle(call) { result in
      XCTAssertEqual((result as? FlutterError)?.code, "bad_args")
      done.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testInlinePacScriptIsExecutedByCFNetwork() {
    let script = """
      function FindProxyForURL(url, host) {
        if (dnsDomainIs(host, ".internal.test")) return "DIRECT";
        return "PROXY proxy.test:3128; SOCKS socks.test:1080; DIRECT";
      }
      """
    let outcome = NativeProxyResolverPlugin.executePac(
      scriptURL: nil, script: script, target: URL(string: "https://example.com/")!, timeout: 10)
    XCTAssertNil(outcome.error)
    XCTAssertEqual(outcome.entries.count, 3)
    XCTAssertEqual(outcome.entries[0]["type"] as? String, "http")
    XCTAssertEqual(outcome.entries[0]["host"] as? String, "proxy.test")
    XCTAssertEqual(outcome.entries[0]["port"] as? Int, 3128)
    XCTAssertEqual(outcome.entries[1]["type"] as? String, "socks")
    XCTAssertEqual(outcome.entries[2]["type"] as? String, "direct")

    let bypassed = NativeProxyResolverPlugin.executePac(
      scriptURL: nil, script: script, target: URL(string: "http://a.internal.test/")!,
      timeout: 10)
    XCTAssertNil(bypassed.error)
    XCTAssertEqual(bypassed.entries.count, 1)
    XCTAssertEqual(bypassed.entries[0]["type"] as? String, "direct")
  }

  func testPacDownloadFailureIsReported() {
    // Nothing listens on port 9 of the loopback interface.
    let outcome = NativeProxyResolverPlugin.executePac(
      scriptURL: URL(string: "http://127.0.0.1:9/proxy.pac")!, script: nil,
      target: URL(string: "https://example.com/")!, timeout: 10)
    XCTAssertTrue(outcome.entries.isEmpty)
    XCTAssertNotNil(outcome.error)
  }

  func testEntryMapTranslatesCFNetworkDictionaries() {
    let https: [String: Any] = [
      kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String,
      kCFProxyHostNameKey as String: "proxy.corp",
      kCFProxyPortNumberKey as String: NSNumber(value: 8443),
    ]
    let entry = NativeProxyResolverPlugin.entryMap(https)
    XCTAssertEqual(entry?["type"] as? String, "http")
    XCTAssertEqual(entry?["host"] as? String, "proxy.corp")
    XCTAssertEqual(entry?["port"] as? Int, 8443)

    let none: [String: Any] = [kCFProxyTypeKey as String: kCFProxyTypeNone as String]
    XCTAssertEqual(NativeProxyResolverPlugin.entryMap(none)?["type"] as? String, "direct")

    let missingPort: [String: Any] = [
      kCFProxyTypeKey as String: kCFProxyTypeHTTP as String,
      kCFProxyHostNameKey as String: "proxy.corp",
    ]
    XCTAssertNil(NativeProxyResolverPlugin.entryMap(missingPort))
  }
}
