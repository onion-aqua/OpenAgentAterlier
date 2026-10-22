#include "include/live2d_flutter/flutter_live2d_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_live2d_plugin.h"

void FlutterLive2dPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_live2d::FlutterLive2dPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
