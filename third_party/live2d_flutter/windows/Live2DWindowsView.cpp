#include "Live2DWindowsView.hpp"

#include <Rendering/D3D11/CubismDeviceInfo_D3D11.hpp>
#include <Rendering/D3D11/CubismRenderer_D3D11.hpp>

#include <algorithm>
#include <cstdint>
#include <stdexcept>

#include "Live2DPal.hpp"

using Microsoft::WRL::ComPtr;
using namespace Live2D::Cubism::Framework;

struct Live2DWindowsView::RenderTarget {
  ~RenderTarget() {
    if (shared_handle) CloseHandle(shared_handle);
  }

  ComPtr<ID3D11Texture2D> texture;
  ComPtr<ID3D11RenderTargetView> render_target_view;
  ComPtr<ID3D11Texture2D> depth_texture;
  ComPtr<ID3D11DepthStencilView> depth_view;
  HANDLE shared_handle = nullptr;
  FlutterDesktopGpuSurfaceDescriptor descriptor = {};
};

Live2DWindowsView::Live2DWindowsView(
    ID3D11Device* device, ID3D11DeviceContext* context,
    flutter::TextureRegistrar* texture_registrar, int width, int height)
    : device_(device),
      context_(context),
      texture_registrar_(texture_registrar),
      width_(width),
      height_(height) {
  active_target_ = CreateRenderTarget(width_, height_);
  if (!active_target_) {
    throw std::runtime_error("Failed to create Live2D render target.");
  }
  active_descriptor_.store(&active_target_->descriptor,
                           std::memory_order_release);

  texture_ = std::make_unique<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(
          kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [this](size_t requested_width, size_t requested_height) {
            return ObtainSurfaceDescriptor(requested_width, requested_height);
          }));
  texture_id_ = texture_registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    throw std::runtime_error("Failed to register Live2D Flutter texture.");
  }
}

Live2DWindowsView::~Live2DWindowsView() {
  UnloadModel();
  active_descriptor_.store(nullptr, std::memory_order_release);
  retired_targets_.clear();
  active_target_.reset();
}

std::shared_ptr<Live2DWindowsView::RenderTarget>
Live2DWindowsView::CreateRenderTarget(int width, int height) {
  auto target = std::make_shared<RenderTarget>();

  D3D11_TEXTURE2D_DESC texture_desc = {};
  texture_desc.Width = static_cast<UINT>(width);
  texture_desc.Height = static_cast<UINT>(height);
  texture_desc.MipLevels = 1;
  texture_desc.ArraySize = 1;
  texture_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  texture_desc.SampleDesc.Count = 1;
  texture_desc.Usage = D3D11_USAGE_DEFAULT;
  texture_desc.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  texture_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  if (FAILED(device_->CreateTexture2D(
          &texture_desc, nullptr, target->texture.GetAddressOf()))) {
    return nullptr;
  }
  if (FAILED(device_->CreateRenderTargetView(
          target->texture.Get(), nullptr,
          target->render_target_view.GetAddressOf()))) {
    return nullptr;
  }

  ComPtr<IDXGIResource> shared_resource;
  if (FAILED(target->texture.As(&shared_resource)) ||
      FAILED(shared_resource->GetSharedHandle(&target->shared_handle))) {
    return nullptr;
  }

  D3D11_TEXTURE2D_DESC depth_desc = {};
  depth_desc.Width = static_cast<UINT>(width);
  depth_desc.Height = static_cast<UINT>(height);
  depth_desc.MipLevels = 1;
  depth_desc.ArraySize = 1;
  depth_desc.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
  depth_desc.SampleDesc.Count = 1;
  depth_desc.Usage = D3D11_USAGE_DEFAULT;
  depth_desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
  if (FAILED(device_->CreateTexture2D(
          &depth_desc, nullptr, target->depth_texture.GetAddressOf()))) {
    return nullptr;
  }
  if (FAILED(device_->CreateDepthStencilView(
          target->depth_texture.Get(), nullptr,
          target->depth_view.GetAddressOf()))) {
    return nullptr;
  }

  target->descriptor.struct_size =
      sizeof(FlutterDesktopGpuSurfaceDescriptor);
  target->descriptor.handle = target->shared_handle;
  target->descriptor.width = static_cast<size_t>(width);
  target->descriptor.height = static_cast<size_t>(height);
  target->descriptor.visible_width = static_cast<size_t>(width);
  target->descriptor.visible_height = static_cast<size_t>(height);
  return target;
}

const FlutterDesktopGpuSurfaceDescriptor*
Live2DWindowsView::ObtainSurfaceDescriptor(size_t width, size_t height) {
  return active_descriptor_.load(std::memory_order_acquire);
}

bool Live2DWindowsView::Resize(int width, int height) {
  if (width <= 0 || height <= 0) return false;
  if (width == width_ && height == height_) return true;

  auto replacement = CreateRenderTarget(width, height);
  if (!replacement) return false;
  if (active_target_) retired_targets_.push_back({active_target_, 0});
  active_target_ = std::move(replacement);
  active_descriptor_.store(&active_target_->descriptor,
                           std::memory_order_release);
  width_ = width;
  height_ = height;
  if (model_) model_->ResizeMaskBuffer(width_, height_);
  UpdateModelScale();
  return true;
}

bool Live2DWindowsView::LoadModel(const std::string& model_dir,
                                  const std::string& model_file_name) {
  UnloadModel();
  texture_manager_ = std::make_unique<Live2DTextureManager>(device_.Get());
  model_ = std::make_unique<Live2DModel>(texture_manager_.get());
  model_->LoadAssets(model_dir.c_str(), model_file_name.c_str());
  if (!model_->IsLoaded()) {
    UnloadModel();
    return false;
  }
  model_->CreateRenderer(static_cast<Csm::csmUint32>(width_),
                         static_cast<Csm::csmUint32>(height_));
  model_->SetupTextures();
  UpdateModelScale();
  return true;
}

void Live2DWindowsView::UnloadModel() {
  model_.reset();
  texture_manager_.reset();
}

void Live2DWindowsView::StartMotion(const std::string& group, int index,
                                    int priority) {
  if (model_) model_->StartMotion(group.c_str(), index, priority);
}

bool Live2DWindowsView::SetIdleMotion(const std::string& group, int index) {
  return model_ && model_->SetIdleMotion(group.c_str(), index);
}

void Live2DWindowsView::SetExpression(int index) {
  if (model_) model_->SetExpression(index);
}

void Live2DWindowsView::SetParameter(const std::string& parameter_id,
                                     float value) {
  if (model_) model_->SetParameterValue(parameter_id.c_str(), value);
}

void Live2DWindowsView::SetMotionSpeed(float speed) {
  if (model_) model_->SetMotionSpeed(speed);
}

void Live2DWindowsView::SetDragging(float x, float y) {
  if (model_) model_->SetDragging(x, y);
}

void Live2DWindowsView::UpdateModelScale() {
  if (!model_ || !model_->IsLoaded()) return;
  if (width_ > height_) {
    model_->GetModelMatrix()->SetHeight(2.0f);
  } else {
    model_->GetModelMatrix()->SetWidth(2.0f);
  }
}

bool Live2DWindowsView::RenderFrame() {
  if (paused_ || !active_target_) return false;

  D3D11_VIEWPORT viewport = {};
  viewport.Width = static_cast<float>(width_);
  viewport.Height = static_cast<float>(height_);
  viewport.MinDepth = 0.0f;
  viewport.MaxDepth = 1.0f;
  context_->RSSetViewports(1, &viewport);

  ID3D11RenderTargetView* render_target =
      active_target_->render_target_view.Get();
  context_->OMSetRenderTargets(1, &render_target,
                               active_target_->depth_view.Get());
  const float clear_color[4] = {0.0f, 0.0f, 0.0f, 0.0f};
  context_->ClearRenderTargetView(render_target, clear_color);
  context_->ClearDepthStencilView(active_target_->depth_view.Get(),
                                  D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL,
                                  1.0f, 0);

  if (model_ && model_->IsLoaded()) {
    auto* renderer =
        model_->GetRenderer<Rendering::CubismRenderer_D3D11>();
    renderer->StartFrame(context_.Get());
    model_->Update();

    Csm::CubismMatrix44 projection;
    projection.LoadIdentity();
    if (width_ > height_) {
      projection.Scale(static_cast<float>(height_) /
                           static_cast<float>(width_),
                       1.0f);
    } else {
      projection.Scale(1.0f, static_cast<float>(width_) /
                                 static_cast<float>(height_));
    }
    model_->Draw(projection);
    renderer->EndFrame();
    Rendering::CubismDeviceInfo_D3D11::GetDeviceInfo(device_.Get())
        ->GetOffscreenManager()
        ->EndFrameProcess();
  }

  context_->Flush();
  RetireOldTargets();
  return true;
}

void Live2DWindowsView::RetireOldTargets() {
  for (auto& target : retired_targets_) ++target.second;
  retired_targets_.erase(
      std::remove_if(retired_targets_.begin(), retired_targets_.end(),
                     [](const auto& target) { return target.second > 4; }),
      retired_targets_.end());
}
