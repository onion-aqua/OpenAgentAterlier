#include "flutter_live2d_plugin.h"

#include <windows.h>
#include <VersionHelpers.h>

#include <CubismFramework.hpp>
#include <Rendering/D3D11/CubismDeviceInfo_D3D11.hpp>
#include <Rendering/D3D11/CubismRenderer_D3D11.hpp>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <optional>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "Live2DPal.hpp"

namespace flutter_live2d {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableMap* GetArguments(
    const flutter::MethodCall<EncodableValue>& call) {
  return call.arguments() ? std::get_if<EncodableMap>(call.arguments())
                          : nullptr;
}

const EncodableValue* FindArgument(const EncodableMap* arguments,
                                   const char* name) {
  if (!arguments) return nullptr;
  const auto it = arguments->find(EncodableValue(name));
  return it == arguments->end() ? nullptr : &it->second;
}

std::optional<int64_t> GetInt(const EncodableMap* arguments,
                              const char* name) {
  const EncodableValue* value = FindArgument(arguments, name);
  if (!value) return std::nullopt;
  if (const auto* integer = std::get_if<int32_t>(value)) return *integer;
  if (const auto* integer = std::get_if<int64_t>(value)) return *integer;
  return std::nullopt;
}

std::optional<double> GetDouble(const EncodableMap* arguments,
                                const char* name) {
  const EncodableValue* value = FindArgument(arguments, name);
  if (!value) return std::nullopt;
  if (const auto* number = std::get_if<double>(value)) return *number;
  if (const auto* integer = std::get_if<int32_t>(value)) return *integer;
  if (const auto* integer = std::get_if<int64_t>(value)) {
    return static_cast<double>(*integer);
  }
  return std::nullopt;
}

std::optional<bool> GetBool(const EncodableMap* arguments,
                            const char* name) {
  const EncodableValue* value = FindArgument(arguments, name);
  if (!value) return std::nullopt;
  if (const auto* boolean = std::get_if<bool>(value)) return *boolean;
  return std::nullopt;
}

std::optional<std::string> GetString(const EncodableMap* arguments,
                                     const char* name) {
  const EncodableValue* value = FindArgument(arguments, name);
  if (!value) return std::nullopt;
  if (const auto* text = std::get_if<std::string>(value)) return *text;
  return std::nullopt;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1,
                                         nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string result(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), length,
                      nullptr, nullptr);
  result.resize(static_cast<size_t>(length - 1));
  return result;
}

std::string GetTemporaryDirectory() {
  const DWORD length = GetTempPathW(0, nullptr);
  if (length == 0) return {};
  std::wstring path(static_cast<size_t>(length), L'\0');
  const DWORD written = GetTempPathW(length, path.data());
  if (written == 0) return {};
  path.resize(written);
  return WideToUtf8(path);
}

}  // namespace

void FlutterLive2dPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "flutter_live2d",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlutterLive2dPlugin>(registrar);
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

FlutterLive2dPlugin::FlutterLive2dPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : texture_registrar_(registrar->texture_registrar()) {
  if (InitializeRuntime()) {
    running_.store(true);
    render_thread_ = std::thread(&FlutterLive2dPlugin::RenderLoop, this);
  }
}

FlutterLive2dPlugin::~FlutterLive2dPlugin() { ShutdownRuntime(); }

bool FlutterLive2dPlugin::InitializeRuntime() {
  constexpr D3D_FEATURE_LEVEL feature_levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
  D3D_FEATURE_LEVEL selected_level;
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
#ifdef _DEBUG
  flags |= D3D11_CREATE_DEVICE_DEBUG;
#endif
  HRESULT status = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, feature_levels,
      ARRAYSIZE(feature_levels), D3D11_SDK_VERSION, device_.GetAddressOf(),
      &selected_level, context_.GetAddressOf());
  if (FAILED(status)) {
    flags &= ~D3D11_CREATE_DEVICE_DEBUG;
    status = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, feature_levels,
        ARRAYSIZE(feature_levels), D3D11_SDK_VERSION, device_.GetAddressOf(),
        &selected_level, context_.GetAddressOf());
  }
  if (FAILED(status)) return false;

  cubism_option_.LogFunction = nullptr;
  cubism_option_.LoggingLevel = Csm::CubismFramework::Option::LogLevel_Off;
  cubism_option_.LoadFileFunction = Live2DPal::LoadFileAsBytes;
  cubism_option_.ReleaseBytesFunction = Live2DPal::ReleaseBytes;
  if (!Csm::CubismFramework::StartUp(&allocator_, &cubism_option_)) {
    return false;
  }
  Csm::CubismFramework::Initialize();
  Csm::Rendering::CubismRenderer_D3D11::SetConstantSettings(1, device_.Get());
  framework_initialized_ = true;
  return true;
}

void FlutterLive2dPlugin::ShutdownRuntime() {
  running_.store(false);
  if (render_thread_.joinable()) render_thread_.join();

  std::map<int64_t, std::shared_ptr<Live2DWindowsView>> views;
  {
    std::lock_guard<std::mutex> lock(views_mutex_);
    views.swap(views_);
  }
  for (const auto& entry : views) {
    texture_registrar_->UnregisterTexture(entry.second->texture_id());
  }
  views.clear();

  if (device_) {
    Csm::Rendering::CubismDeviceInfo_D3D11::ReleaseAllDeviceInfo();
  }
  if (framework_initialized_) {
    Csm::CubismFramework::Dispose();
    framework_initialized_ = false;
  }
  context_.Reset();
  device_.Reset();
}

std::shared_ptr<Live2DWindowsView> FlutterLive2dPlugin::FindView(
    int64_t view_id) {
  const auto it = views_.find(view_id);
  return it == views_.end() ? nullptr : it->second;
}

void FlutterLive2dPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const EncodableMap* arguments = GetArguments(method_call);

  if (method == "getPlatformVersion") {
    std::ostringstream version;
    version << "Windows ";
    version << (IsWindows10OrGreater() ? "10+" : "legacy");
    result->Success(EncodableValue(version.str()));
    return;
  }
  if (method == "getTempDirectory") {
    result->Success(EncodableValue(GetTemporaryDirectory()));
    return;
  }
  if (!framework_initialized_) {
    result->Error("RUNTIME_INIT_FAILED",
                  "Unable to initialize the Windows D3D11 runtime.");
    return;
  }

  if (method == "createView") {
    const auto width = GetInt(arguments, "width");
    const auto height = GetInt(arguments, "height");
    if (!width || !height || *width <= 0 || *height <= 0 || *width > 4096 ||
        *height > 4096) {
      result->Error("INVALID_ARGS", "Invalid texture dimensions.");
      return;
    }
    try {
      std::lock_guard<std::mutex> lock(views_mutex_);
      const int64_t view_id = next_view_id_++;
      auto view = std::make_shared<Live2DWindowsView>(
          device_.Get(), context_.Get(), texture_registrar_,
          static_cast<int>(*width), static_cast<int>(*height));
      const int64_t texture_id = view->texture_id();
      views_[view_id] = std::move(view);
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("viewId"), EncodableValue(view_id)},
          {EncodableValue("textureId"), EncodableValue(texture_id)},
      }));
    } catch (const std::exception& error) {
      result->Error("CREATE_VIEW_FAILED", error.what());
    }
    return;
  }

  const auto view_id = GetInt(arguments, "viewId");
  if (!view_id) {
    result->Error("INVALID_ARGS", "Missing or invalid 'viewId'.");
    return;
  }

  if (method == "disposeView") {
    std::shared_ptr<Live2DWindowsView> view;
    {
      std::lock_guard<std::mutex> lock(views_mutex_);
      const auto it = views_.find(*view_id);
      if (it != views_.end()) {
        view = std::move(it->second);
        views_.erase(it);
      }
    }
    if (view) {
      texture_registrar_->UnregisterTexture(
          view->texture_id(), [view = std::move(view)]() {});
    }
    result->Success();
    return;
  }

  std::lock_guard<std::mutex> lock(views_mutex_);
  const auto view = FindView(*view_id);
  if (!view) {
    result->Error("VIEW_NOT_FOUND", "No Live2D view for the supplied id.");
    return;
  }

  if (method == "resizeView") {
    const auto width = GetInt(arguments, "width");
    const auto height = GetInt(arguments, "height");
    if (!width || !height || *width <= 0 || *height <= 0 || *width > 4096 ||
        *height > 4096) {
      result->Error("INVALID_ARGS", "Invalid texture dimensions.");
      return;
    }
    if (!view->Resize(static_cast<int>(*width), static_cast<int>(*height))) {
      result->Error("RESIZE_FAILED", "Unable to resize the D3D11 texture.");
      return;
    }
    result->Success();
    return;
  }
  if (method == "loadModel") {
    const auto model_dir = GetString(arguments, "modelDir");
    const auto model_file_name = GetString(arguments, "modelFileName");
    if (!model_dir || model_dir->empty() || !model_file_name ||
        model_file_name->empty()) {
      result->Error("INVALID_ARGS", "Invalid model path.");
      return;
    }
    const bool loaded = view->LoadModel(*model_dir, *model_file_name);
    result->Success(EncodableValue(loaded));
    return;
  }
  if (method == "unloadModel") {
    view->UnloadModel();
    result->Success();
    return;
  }
  if (method == "setRenderingPaused") {
    const auto paused = GetBool(arguments, "paused");
    if (!paused) {
      result->Error("INVALID_ARGS", "Missing or invalid 'paused'.");
      return;
    }
    view->SetRenderingPaused(*paused);
    result->Success();
    return;
  }
  if (method == "startMotion") {
    const auto group = GetString(arguments, "group");
    const auto index = GetInt(arguments, "index");
    const auto priority = GetInt(arguments, "priority");
    if (!group || !index || !priority) {
      result->Error("INVALID_ARGS", "Invalid motion arguments.");
      return;
    }
    view->StartMotion(*group, static_cast<int>(*index),
                      static_cast<int>(*priority));
    result->Success();
    return;
  }
  if (method == "setIdleMotion") {
    const auto group = GetString(arguments, "group");
    const auto index = GetInt(arguments, "index");
    if (!group || !index || *index < 0) {
      result->Error("INVALID_MOTION", "Invalid idle motion arguments.");
      return;
    }
    if (!view->SetIdleMotion(*group, static_cast<int>(*index))) {
      result->Error("INVALID_MOTION",
                    "The idle motion is not present in the loaded model.");
      return;
    }
    result->Success();
    return;
  }
  if (method == "setExpression") {
    const auto index = GetInt(arguments, "index");
    if (!index) {
      result->Error("INVALID_ARGS", "Missing or invalid 'index'.");
      return;
    }
    view->SetExpression(static_cast<int>(*index));
    result->Success();
    return;
  }
  if (method == "setParameter") {
    const auto parameter_id = GetString(arguments, "parameterId");
    const auto value = GetDouble(arguments, "value");
    if (!parameter_id || parameter_id->empty() || !value) {
      result->Error("INVALID_ARGS", "Invalid parameter arguments.");
      return;
    }
    view->SetParameter(*parameter_id, static_cast<float>(*value));
    result->Success();
    return;
  }
  if (method == "setMotionSpeed") {
    const auto speed = GetDouble(arguments, "speed");
    if (!speed || *speed < 0.0) {
      result->Error("INVALID_ARGS", "Motion speed must be non-negative.");
      return;
    }
    view->SetMotionSpeed(static_cast<float>(*speed));
    result->Success();
    return;
  }
  if (method == "setDragging") {
    const auto x = GetDouble(arguments, "x");
    const auto y = GetDouble(arguments, "y");
    if (!x || !y) {
      result->Error("INVALID_ARGS", "Invalid dragging coordinates.");
      return;
    }
    view->SetDragging(static_cast<float>(*x), static_cast<float>(*y));
    result->Success();
    return;
  }

  result->NotImplemented();
}

void FlutterLive2dPlugin::RenderLoop() {
  using Clock = std::chrono::steady_clock;
  constexpr auto frame_interval = std::chrono::milliseconds(16);
  auto next_frame = Clock::now();
  while (running_.load()) {
    next_frame += frame_interval;
    std::vector<int64_t> updated_textures;
    {
      std::lock_guard<std::mutex> lock(views_mutex_);
      Live2DPal::UpdateTime();
      for (const auto& entry : views_) {
        if (entry.second->RenderFrame()) {
          updated_textures.push_back(entry.second->texture_id());
        }
      }
    }
    for (const int64_t texture_id : updated_textures) {
      texture_registrar_->MarkTextureFrameAvailable(texture_id);
    }
    std::this_thread::sleep_until(next_frame);
    if (Clock::now() - next_frame > frame_interval) next_frame = Clock::now();
  }
}

}  // namespace flutter_live2d
