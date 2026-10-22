#ifndef FLUTTER_PLUGIN_FLUTTER_LIVE2D_PLUGIN_H_
#define FLUTTER_PLUGIN_FLUTTER_LIVE2D_PLUGIN_H_

#include <d3d11.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

#include "Live2DAllocator.hpp"
#include "Live2DWindowsView.hpp"

namespace flutter_live2d {

class FlutterLive2dPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  explicit FlutterLive2dPlugin(flutter::PluginRegistrarWindows* registrar);
  ~FlutterLive2dPlugin() override;

  FlutterLive2dPlugin(const FlutterLive2dPlugin&) = delete;
  FlutterLive2dPlugin& operator=(const FlutterLive2dPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  bool InitializeRuntime();
  void ShutdownRuntime();
  void RenderLoop();
  std::shared_ptr<Live2DWindowsView> FindView(int64_t view_id);

  flutter::TextureRegistrar* texture_registrar_;
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Live2DAllocator allocator_;
  Csm::CubismFramework::Option cubism_option_{};
  bool framework_initialized_ = false;
  std::atomic<bool> running_{false};
  std::thread render_thread_;
  std::mutex views_mutex_;
  std::map<int64_t, std::shared_ptr<Live2DWindowsView>> views_;
  int64_t next_view_id_ = 1;
};

}  // namespace flutter_live2d

#endif
