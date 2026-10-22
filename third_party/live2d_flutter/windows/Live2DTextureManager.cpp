#include "Live2DTextureManager.hpp"

#include "Live2DPal.hpp"

#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

Live2DTextureManager::Live2DTextureManager(ID3D11Device* device)
    : device_(device) {}

Live2DTextureManager::~Live2DTextureManager() { ReleaseTextures(); }

Live2DTextureManager::TextureInfo*
Live2DTextureManager::CreateTextureFromPngFile(
    const std::string& file_path) {
  for (const auto& texture : textures_) {
    if (texture->file_name == file_path) return texture.get();
  }

  Csm::csmSizeInt data_size = 0;
  Csm::csmByte* data = Live2DPal::LoadFileAsBytes(file_path, &data_size);
  if (!data) return nullptr;

  int width = 0;
  int height = 0;
  int channels = 0;
  unsigned char* pixels = stbi_load_from_memory(
      data, static_cast<int>(data_size), &width, &height, &channels,
      STBI_rgb_alpha);
  Live2DPal::ReleaseBytes(data);
  if (!pixels) return nullptr;

  D3D11_TEXTURE2D_DESC texture_desc = {};
  texture_desc.Width = static_cast<UINT>(width);
  texture_desc.Height = static_cast<UINT>(height);
  texture_desc.MipLevels = 1;
  texture_desc.ArraySize = 1;
  texture_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  texture_desc.SampleDesc.Count = 1;
  texture_desc.Usage = D3D11_USAGE_IMMUTABLE;
  texture_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;

  D3D11_SUBRESOURCE_DATA initial_data = {};
  initial_data.pSysMem = pixels;
  initial_data.SysMemPitch = static_cast<UINT>(width * 4);

  auto info = std::make_unique<TextureInfo>();
  HRESULT result = device_->CreateTexture2D(
      &texture_desc, &initial_data, info->texture.GetAddressOf());
  stbi_image_free(pixels);
  if (FAILED(result)) return nullptr;

  result = device_->CreateShaderResourceView(
      info->texture.Get(), nullptr, info->texture_view.GetAddressOf());
  if (FAILED(result)) return nullptr;

  info->width = width;
  info->height = height;
  info->file_name = file_path;
  TextureInfo* result_info = info.get();
  textures_.push_back(std::move(info));
  return result_info;
}

void Live2DTextureManager::ReleaseTextures() { textures_.clear(); }
