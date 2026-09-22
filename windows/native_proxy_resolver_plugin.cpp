#include "native_proxy_resolver_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <winhttp.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace native_proxy_resolver {

namespace {

constexpr char kMethodChannel[] = "dev.manishpanday/native_proxy_resolver";
constexpr wchar_t kResultMessageName[] =
    L"dev.manishpanday.native_proxy_resolver.result";
constexpr DWORD kDefaultTimeoutMs = 10000;

std::string Narrow(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') {
    return std::string();
  }
  const int length = static_cast<int>(wcslen(text));
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, &out[0], size, nullptr,
                      nullptr);
  return out;
}

std::wstring Widen(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                       static_cast<int>(text.size()), nullptr,
                                       0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      &out[0], size);
  return out;
}

// Frees the strings WinHTTP allocates with GlobalAlloc.
void FreeGlobal(LPWSTR text) {
  if (text != nullptr) {
    GlobalFree(text);
  }
}

// Owns a WinHTTP handle.
class HInternet {
 public:
  explicit HInternet(HINTERNET handle) : handle_(handle) {}
  ~HInternet() {
    if (handle_ != nullptr) {
      WinHttpCloseHandle(handle_);
    }
  }
  HInternet(const HInternet&) = delete;
  HInternet& operator=(const HInternet&) = delete;
  HINTERNET get() const { return handle_; }

 private:
  HINTERNET handle_;
};

std::string ErrorText(const char* what, DWORD code) {
  std::ostringstream stream;
  stream << what << " failed (error " << code << ")";
  switch (code) {
    case ERROR_WINHTTP_AUTODETECTION_FAILED:
      stream << ": WPAD auto-detection found no PAC script";
      break;
    case ERROR_WINHTTP_UNABLE_TO_DOWNLOAD_SCRIPT:
      stream << ": the PAC script could not be downloaded";
      break;
    case ERROR_WINHTTP_BAD_AUTO_PROXY_SCRIPT:
      stream << ": the PAC script is invalid";
      break;
    case ERROR_WINHTTP_TIMEOUT:
      stream << ": timed out";
      break;
    case ERROR_WINHTTP_LOGIN_FAILURE:
      stream << ": the PAC server requires authentication";
      break;
    default:
      break;
  }
  return stream.str();
}

flutter::EncodableValue DirectEntry() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("type"), flutter::EncodableValue("direct")}});
}

}  // namespace

// static
void NativeProxyResolverPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kMethodChannel,
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<NativeProxyResolverPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
  // The channel must outlive this function; the registrar keeps the plugin,
  // and the messenger keeps the handler registered until the engine stops.
  channel.release();
}

NativeProxyResolverPlugin::NativeProxyResolverPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), shared_(std::make_shared<SharedState>()) {
  result_message_ = RegisterWindowMessageW(kResultMessageName);
  if (registrar_->GetView() != nullptr && result_message_ != 0) {
    window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowProc(hwnd, message, wparam, lparam);
        });
  }
}

HWND NativeProxyResolverPlugin::RootWindow() const {
  // Looked up per call: while plugins are registered the Flutter view is not
  // yet parented to the runner's top-level window.
  flutter::FlutterView* view = registrar_->GetView();
  if (view == nullptr) {
    return nullptr;
  }
  HWND child = view->GetNativeWindow();
  if (child == nullptr) {
    return nullptr;
  }
  HWND root = GetAncestor(child, GA_ROOT);
  // Only a real top-level window forwards messages to the delegates.
  return (root != nullptr && root != child) ? root : nullptr;
}

NativeProxyResolverPlugin::~NativeProxyResolverPlugin() {
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->alive = false;
    shared_->window = nullptr;
    shared_->completed.clear();
  }
  if (window_proc_id_ != -1) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
  }
}

void NativeProxyResolverPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() != "resolve") {
    result->NotImplemented();
    return;
  }
  const auto* args =
      std::get_if<flutter::EncodableMap>(method_call.arguments());
  if (args == nullptr) {
    result->Error("bad_args", "Expected a map with 'url'");
    return;
  }
  const auto url_it = args->find(flutter::EncodableValue("url"));
  const std::string* url = url_it == args->end()
                               ? nullptr
                               : std::get_if<std::string>(&url_it->second);
  if (url == nullptr || url->empty()) {
    result->Error("bad_args", "Expected an absolute 'url'");
    return;
  }
  DWORD timeout_ms = kDefaultTimeoutMs;
  const auto timeout_it = args->find(flutter::EncodableValue("timeoutMs"));
  if (timeout_it != args->end()) {
    if (const auto* value = std::get_if<int32_t>(&timeout_it->second)) {
      timeout_ms = *value > 0 ? static_cast<DWORD>(*value) : 1;
    } else if (const auto* value64 =
                   std::get_if<int64_t>(&timeout_it->second)) {
      timeout_ms = *value64 > 0 ? static_cast<DWORD>(*value64) : 1;
    }
  }
  const std::wstring wide_url = Widen(*url);

  HWND window = window_proc_id_ == -1 ? nullptr : RootWindow();
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    shared_->window = window;
  }
  if (window == nullptr) {
    // No window to marshal results through (e.g. headless engine): resolve
    // on the platform thread.
    result->Success(flutter::EncodableValue(Resolve(wide_url, timeout_ms)));
    return;
  }

  const int64_t id = next_request_id_++;
  pending_[id] = std::move(result);
  std::shared_ptr<SharedState> shared = shared_;
  const UINT message = result_message_;
  std::thread([shared, id, wide_url, timeout_ms, message]() {
    flutter::EncodableMap reply = Resolve(wide_url, timeout_ms);
    std::lock_guard<std::mutex> lock(shared->mutex);
    if (!shared->alive || shared->window == nullptr) {
      return;
    }
    shared->completed.emplace_back(id, flutter::EncodableValue(reply));
    PostMessageW(shared->window, message, 0, 0);
  }).detach();
}

std::optional<LRESULT> NativeProxyResolverPlugin::HandleWindowProc(HWND hwnd,
                                                              UINT message,
                                                              WPARAM wparam,
                                                              LPARAM lparam) {
  if (message != result_message_) {
    return std::nullopt;
  }
  DrainCompleted();
  return 0;
}

void NativeProxyResolverPlugin::DrainCompleted() {
  std::deque<std::pair<int64_t, flutter::EncodableValue>> completed;
  {
    std::lock_guard<std::mutex> lock(shared_->mutex);
    completed.swap(shared_->completed);
  }
  for (auto& item : completed) {
    auto it = pending_.find(item.first);
    if (it == pending_.end()) {
      continue;
    }
    it->second->Success(item.second);
    pending_.erase(it);
  }
}

// static
flutter::EncodableMap NativeProxyResolverPlugin::Resolve(const std::wstring& url,
                                                    DWORD timeout_ms) {
  using flutter::EncodableList;
  using flutter::EncodableMap;
  using flutter::EncodableValue;

  EncodableMap reply;
  std::vector<std::string> errors;

  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG ie_config = {};
  if (!WinHttpGetIEProxyConfigForCurrentUser(&ie_config)) {
    const DWORD code = GetLastError();
    // ERROR_FILE_NOT_FOUND means "no proxy settings": a normal direct setup.
    if (code != ERROR_FILE_NOT_FOUND) {
      errors.push_back(ErrorText("WinHttpGetIEProxyConfigForCurrentUser", code));
    }
    ie_config = {};
  }
  const bool auto_detect = ie_config.fAutoDetect != FALSE;
  const std::wstring auto_config_url =
      ie_config.lpszAutoConfigUrl != nullptr ? ie_config.lpszAutoConfigUrl
                                             : L"";
  const std::string manual_proxy = Narrow(ie_config.lpszProxy);
  const std::string manual_bypass = Narrow(ie_config.lpszProxyBypass);
  FreeGlobal(ie_config.lpszAutoConfigUrl);
  FreeGlobal(ie_config.lpszProxy);
  FreeGlobal(ie_config.lpszProxyBypass);

  if (!auto_config_url.empty()) {
    reply[EncodableValue("pacUrl")] = EncodableValue(Narrow(auto_config_url.c_str()));
  }

  if (auto_detect || !auto_config_url.empty()) {
    HInternet session(WinHttpOpen(L"native_proxy_resolver/0.1",
                                  WINHTTP_ACCESS_TYPE_NO_PROXY,
                                  WINHTTP_NO_PROXY_NAME,
                                  WINHTTP_NO_PROXY_BYPASS, 0));
    if (session.get() == nullptr) {
      errors.push_back(ErrorText("WinHttpOpen", GetLastError()));
    } else {
      const int timeout = static_cast<int>(timeout_ms);
      WinHttpSetTimeouts(session.get(), timeout, timeout, timeout, timeout);

      WINHTTP_AUTOPROXY_OPTIONS options = {};
      if (auto_detect) {
        options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
        options.dwAutoDetectFlags =
            WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
      }
      if (!auto_config_url.empty()) {
        options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
        options.lpszAutoConfigUrl = auto_config_url.c_str();
      }
      options.fAutoLogonIfChallenged = FALSE;

      WINHTTP_PROXY_INFO info = {};
      BOOL ok = WinHttpGetProxyForUrl(session.get(), url.c_str(), &options,
                                      &info);
      DWORD code = ok ? ERROR_SUCCESS : GetLastError();
      if (!ok && code == ERROR_WINHTTP_LOGIN_FAILURE) {
        // The PAC server wants NTLM/Kerberos: retry with the logged-on user.
        options.fAutoLogonIfChallenged = TRUE;
        ok = WinHttpGetProxyForUrl(session.get(), url.c_str(), &options,
                                   &info);
        code = ok ? ERROR_SUCCESS : GetLastError();
      }
      if (ok) {
        const std::string source =
            auto_config_url.empty() ? "autoDetect" : "pac";
        reply[EncodableValue("source")] = EncodableValue(source);
        if (info.dwAccessType == WINHTTP_ACCESS_TYPE_NAMED_PROXY &&
            info.lpszProxy != nullptr && *info.lpszProxy != L'\0') {
          reply[EncodableValue("proxyList")] =
              EncodableValue(Narrow(info.lpszProxy));
          reply[EncodableValue("proxyBypass")] =
              EncodableValue(Narrow(info.lpszProxyBypass));
        } else {
          reply[EncodableValue("entries")] = EncodableValue(EncodableList{DirectEntry()});
        }
        FreeGlobal(info.lpszProxy);
        FreeGlobal(info.lpszProxyBypass);
        if (!errors.empty()) {
          std::string joined;
          for (const auto& error : errors) {
            joined += (joined.empty() ? "" : "; ") + error;
          }
          reply[EncodableValue("error")] = EncodableValue(joined);
        }
        return reply;
      }
      errors.push_back(ErrorText("WinHttpGetProxyForUrl", code));
    }
  }

  // No (working) auto-configuration: use the manual settings, like WinINet.
  if (!manual_proxy.empty()) {
    reply[EncodableValue("source")] = EncodableValue("manual");
    reply[EncodableValue("proxyList")] = EncodableValue(manual_proxy);
    reply[EncodableValue("proxyBypass")] = EncodableValue(manual_bypass);
  } else {
    reply[EncodableValue("source")] = EncodableValue(
        auto_detect ? "autoDetect" : (auto_config_url.empty() ? "none" : "pac"));
    reply[EncodableValue("entries")] = EncodableValue(EncodableList{DirectEntry()});
  }
  if (!errors.empty()) {
    std::string joined;
    for (const auto& error : errors) {
      joined += (joined.empty() ? "" : "; ") + error;
    }
    reply[EncodableValue("error")] = EncodableValue(joined);
  }
  return reply;
}

}  // namespace native_proxy_resolver
