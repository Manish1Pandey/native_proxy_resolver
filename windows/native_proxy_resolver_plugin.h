#ifndef FLUTTER_PLUGIN_NATIVE_PROXY_RESOLVER_PLUGIN_H_
#define FLUTTER_PLUGIN_NATIVE_PROXY_RESOLVER_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace native_proxy_resolver {

// Resolves the proxy for a URL through WinHTTP (IE / Internet Settings
// configuration, WPAD auto-detection and PAC scripts). Resolution runs on a
// worker thread; results are posted back to the platform thread through the
// top-level window's message loop.
class NativeProxyResolverPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit NativeProxyResolverPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~NativeProxyResolverPlugin();

  // Disallow copy and assign.
  NativeProxyResolverPlugin(const NativeProxyResolverPlugin&) = delete;
  NativeProxyResolverPlugin& operator=(const NativeProxyResolverPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Resolves |url| synchronously (may block for up to about |timeout_ms| per
  // WinHTTP phase). Exposed for testing.
  static flutter::EncodableMap Resolve(const std::wstring& url,
                                       DWORD timeout_ms);

 private:
  // State shared with worker threads; outlives the plugin if a worker is
  // still running when the engine shuts down.
  struct SharedState {
    std::mutex mutex;
    bool alive = true;
    HWND window = nullptr;
    std::deque<std::pair<int64_t, flutter::EncodableValue>> completed;
  };

  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam, LPARAM lparam);
  void DrainCompleted();
  HWND RootWindow() const;

  flutter::PluginRegistrarWindows* registrar_;
  int window_proc_id_ = -1;
  UINT result_message_ = 0;
  int64_t next_request_id_ = 1;
  std::shared_ptr<SharedState> shared_;
  std::map<int64_t,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>>
      pending_;
};

}  // namespace native_proxy_resolver

#endif  // FLUTTER_PLUGIN_NATIVE_PROXY_RESOLVER_PLUGIN_H_
