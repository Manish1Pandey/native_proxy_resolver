import CFNetwork
import Foundation
import Network

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
  import SystemConfiguration
#endif

/// Resolves the system proxy for a URL with CFNetwork, executing PAC scripts
/// (by URL or inline JavaScript) on a background run loop, and reports
/// network / proxy configuration changes.
public class NativeProxyResolverPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let methodChannelName = "dev.manishpanday/native_proxy_resolver"
  static let eventChannelName = "dev.manishpanday/native_proxy_resolver/changes"

  private let resolveQueue = DispatchQueue(
    label: "dev.manishpanday.native_proxy_resolver.resolve",
    qos: .userInitiated,
    attributes: .concurrent)

  private var eventSink: FlutterEventSink?
  private var pathMonitor: NWPathMonitor?
  private var lastPathStatus: NWPath.Status?
  #if os(macOS)
    private var dynamicStore: SCDynamicStore?
  #endif

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let instance = NativeProxyResolverPlugin()
    let channel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "resolve":
      guard let args = call.arguments as? [String: Any],
        let urlString = args["url"] as? String,
        let url = URL(string: urlString), url.host != nil
      else {
        result(FlutterError(code: "bad_args", message: "Expected an absolute 'url'", details: nil))
        return
      }
      let timeoutMs = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 10_000
      let timeout = max(timeoutMs, 1) / 1000.0
      resolveQueue.async {
        let reply = NativeProxyResolverPlugin.resolve(url: url, timeout: timeout)
        DispatchQueue.main.async { result(reply) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Resolution

  /// Resolves `url` and returns the channel reply map.
  static func resolve(url: URL, timeout: TimeInterval) -> [String: Any] {
    guard let settingsRef = CFNetworkCopySystemProxySettings() else {
      return ["entries": [["type": "direct"]], "source": "none"]
    }
    let settings = settingsRef.takeRetainedValue()
    let settingsDict = settings as NSDictionary
    let proxies =
      CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
      as? [[String: Any]] ?? []

    var entries: [[String: Any]] = []
    var errors: [String] = []
    var usedPac = false
    var pacUrl: String?
    let deadline = Date().addingTimeInterval(timeout)

    for proxy in proxies {
      let type = proxy[kCFProxyTypeKey as String] as? String
      if type == typeAutoConfigURL {
        usedPac = true
        guard let scriptUrl = proxy[kCFProxyAutoConfigurationURLKey as String] as? URL else {
          errors.append("PAC entry without a script URL")
          continue
        }
        pacUrl = scriptUrl.absoluteString
        let outcome = executePac(
          scriptURL: scriptUrl, script: nil, target: url,
          timeout: deadline.timeIntervalSinceNow)
        entries.append(contentsOf: outcome.entries)
        if let error = outcome.error { errors.append(error) }
      } else if type == typeAutoConfigScript {
        usedPac = true
        guard let script = proxy[kCFProxyAutoConfigurationJavaScriptKey as String] as? String
        else {
          errors.append("PAC entry without a script")
          continue
        }
        let outcome = executePac(
          scriptURL: nil, script: script, target: url,
          timeout: deadline.timeIntervalSinceNow)
        entries.append(contentsOf: outcome.entries)
        if let error = outcome.error { errors.append(error) }
      } else if let entry = entryMap(proxy) {
        entries.append(entry)
      }
    }

    // No proxy, or a PAC script that failed / timed out: DIRECT is the only
    // answer left.
    if entries.isEmpty { entries.append(["type": "direct"]) }

    let source: String
    if usedPac {
      let autoDiscovery = (settingsDict["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue ?? false
      let pacEnabled =
        (settingsDict[kCFNetworkProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue
        ?? false
      source = (autoDiscovery && !pacEnabled) ? "autoDetect" : "pac"
    } else if entries.contains(where: { ($0["type"] as? String) != "direct" }) {
      source = "manual"
    } else {
      source = hasManualProxy(settingsDict) ? "manual" : "none"
    }

    var reply: [String: Any] = ["entries": entries, "source": source]
    if let pacUrl = pacUrl { reply["pacUrl"] = pacUrl }
    if !errors.isEmpty { reply["error"] = errors.joined(separator: "; ") }
    return reply
  }

  private static func hasManualProxy(_ settings: NSDictionary) -> Bool {
    var keys = [kCFNetworkProxiesHTTPEnable as String]
    #if os(macOS)
      keys += [
        kCFNetworkProxiesHTTPSEnable as String,
        kCFNetworkProxiesSOCKSEnable as String,
      ]
    #endif
    return keys.contains { (settings[$0] as? NSNumber)?.boolValue ?? false }
  }

  private static let typeNone = kCFProxyTypeNone as String
  private static let typeHTTP = kCFProxyTypeHTTP as String
  private static let typeHTTPS = kCFProxyTypeHTTPS as String
  private static let typeSOCKS = kCFProxyTypeSOCKS as String
  private static let typeAutoConfigURL = kCFProxyTypeAutoConfigurationURL as String
  private static let typeAutoConfigScript = kCFProxyTypeAutoConfigurationJavaScript as String

  /// Converts one CFNetwork proxy dictionary into a channel entry map.
  static func entryMap(_ proxy: [String: Any]) -> [String: Any]? {
    let type = proxy[kCFProxyTypeKey as String] as? String
    let wireType: String
    if type == typeNone {
      return ["type": "direct"]
    } else if type == typeHTTP || type == typeHTTPS {
      // kCFProxyTypeHTTPS is "the proxy used for https:// URLs", reached with
      // plain HTTP CONNECT, so it maps to an HTTP proxy.
      wireType = "http"
    } else if type == typeSOCKS {
      wireType = "socks"
    } else {
      return nil
    }
    guard let host = proxy[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
      let port = (proxy[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue, port > 0
    else { return nil }
    var entry: [String: Any] = ["type": wireType, "host": host, "port": port]
    if let user = proxy[kCFProxyUsernameKey as String] as? String, !user.isEmpty {
      entry["username"] = user
    }
    if let password = proxy[kCFProxyPasswordKey as String] as? String, !password.isEmpty {
      entry["password"] = password
    }
    return entry
  }

  /// Holds the outcome of an asynchronous PAC execution.
  private final class PacState {
    var proxies: [[String: Any]]?
    var error: String?
    var done = false
  }

  private static let pacRunLoopMode = CFRunLoopMode(
    "dev.manishpanday.native_proxy_resolver.pac" as CFString)

  /// Runs a PAC script (downloaded from `scriptURL`, or the inline `script`)
  /// for `target` on the current thread's run loop, in a private mode, until
  /// it completes or `timeout` elapses.
  static func executePac(scriptURL: URL?, script: String?, target: URL, timeout: TimeInterval)
    -> (entries: [[String: Any]], error: String?)
  {
    if timeout <= 0 {
      return ([], "PAC evaluation skipped: resolution timeout exhausted")
    }
    let state = PacState()
    var context = CFStreamClientContext(
      version: 0,
      info: Unmanaged.passUnretained(state).toOpaque(),
      retain: nil, release: nil, copyDescription: nil)
    let callback: CFProxyAutoConfigurationResultCallback = { client, proxyList, error in
      let state = Unmanaged<PacState>.fromOpaque(client).takeUnretainedValue()
      if let error = error {
        state.error = "PAC evaluation failed: \(CFErrorCopyDescription(error) as String)"
      } else {
        state.proxies = proxyList as? [[String: Any]] ?? []
      }
      state.done = true
      CFRunLoopStop(CFRunLoopGetCurrent())
    }

    let source: CFRunLoopSource
    if let scriptURL = scriptURL {
      source = CFNetworkExecuteProxyAutoConfigurationURL(
        scriptURL as CFURL, target as CFURL, callback, &context)
    } else if let script = script {
      source = CFNetworkExecuteProxyAutoConfigurationScript(
        script as CFString, target as CFURL, callback, &context)
    } else {
      return ([], "PAC entry without script")
    }

    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, pacRunLoopMode)
    let deadline = Date().addingTimeInterval(timeout)
    while !state.done {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { break }
      _ = CFRunLoopRunInMode(pacRunLoopMode, remaining, false)
    }
    CFRunLoopRemoveSource(runLoop, source, pacRunLoopMode)
    CFRunLoopSourceInvalidate(source)

    if !state.done {
      return ([], String(format: "PAC evaluation timed out after %.1f s", timeout))
    }
    if let error = state.error { return ([], error) }
    let entries = (state.proxies ?? []).compactMap { entryMap($0) }
    return (entries, nil)
  }

  // MARK: - Change events

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      // The first callback reports the current state; only changes matter.
      if self.lastPathStatus != nil { self.emit("network") }
      self.lastPathStatus = path.status
    }
    monitor.start(queue: DispatchQueue.main)
    pathMonitor = monitor
    #if os(macOS)
      startDynamicStore()
    #endif
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    pathMonitor?.cancel()
    pathMonitor = nil
    lastPathStatus = nil
    #if os(macOS)
      stopDynamicStore()
    #endif
    eventSink = nil
    return nil
  }

  private func emit(_ reason: String) {
    eventSink?(reason)
  }

  #if os(macOS)
    private func startDynamicStore() {
      var context = SCDynamicStoreContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil, release: nil, copyDescription: nil)
      guard
        let store = SCDynamicStoreCreate(
          nil, "dev.manishpanday.native_proxy_resolver" as CFString,
          { _, _, info in
            guard let info = info else { return }
            let plugin = Unmanaged<NativeProxyResolverPlugin>.fromOpaque(info).takeUnretainedValue()
            plugin.emit("proxy")
          }, &context)
      else { return }
      let proxiesKey = SCDynamicStoreKeyCreateProxies(nil)
      guard SCDynamicStoreSetNotificationKeys(store, [proxiesKey] as CFArray, nil),
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
      else { return }
      dynamicStore = store
    }

    private func stopDynamicStore() {
      if let store = dynamicStore {
        SCDynamicStoreSetDispatchQueue(store, nil)
      }
      dynamicStore = nil
    }
  #endif
}
