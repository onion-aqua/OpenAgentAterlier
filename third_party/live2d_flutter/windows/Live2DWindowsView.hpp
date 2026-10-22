#pragma once

#include <d3d11.h>
#include <flutter/texture_registrar.h>
#include <wrl/client.h>

#include <atomic>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "Live2DModel.hpp"
#include "Live2DTextureManager.hpp"

class Live2DWindowsView {
 public:
  Live2DWindowsView(ID3D11Device* device, ID3D11DeviceContext* context,
                    flutter::TextureRegistrar* texture_registrar, int width,
                    int height);
  ~Live2DWindowsView();

  Live2DWindowsView(const Live2DWindowsView&) = delete;
  Live2DWindowsView& operator=(const Live2DWindowsView&) = delete;

  int64_t texture_id() const { return texture_id_; }
  bool Resize(int width, int height);
  bool LoadModel(const std::string& model_dir,
                 const std::string& model_file_name);
  void UnloadModel();
  void SetRenderingPaused(bool paused) { paused_ = paused; }
  void StartMotion(const std::string& group, int index, int priority);
  bool SetIdleMotion(const std::string& group, int index);
  void SetExpression(int index);
  void SetParameter(const std::string& parameter_id, float value);
  void SetMotionSpeed(float speed);
  void SetDragging(float x, float y);
  bool RenderFrame();

 private:
  struct RenderTarget;

  std::shared_ptr<RenderTarget> CreateRenderTarget(int width, int height);
  const FlutterDesktopGpuSurfaceDescriptor* ObtainSurfaceDescriptor(
      size_t width, size_t height);
  void UpdateModelScale();
  void RetireOldTargets();

  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  flutter::TextureRegistrar* texture_registrar_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  int width_ = 1;
  int height_ = 1;
  bool paused_ = false;

  std::shared_ptr<RenderTarget> active_target_;
  std::vector<std::pair<std::shared_ptr<RenderTarget>, int>> retired_targets_;
  std::atomic<const FlutterDesktopGpuSurfaceDescriptor*>
      active_descriptor_{nullptr};

  std::unique_ptr<Live2DTextureManager> texture_manager_;
  std::unique_ptr<Live2DModel> model_;
};
