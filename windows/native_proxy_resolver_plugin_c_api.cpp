#include "include/native_proxy_resolver/native_proxy_resolver_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "native_proxy_resolver_plugin.h"

void NativeProxyResolverPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  native_proxy_resolver::NativeProxyResolverPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
