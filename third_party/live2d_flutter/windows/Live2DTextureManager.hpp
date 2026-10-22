#pragma once

#include <d3d11.h>
#include <wrl/client.h>

#include <memory>
#include <string>
#include <vector>

class Live2DTextureManager {
 public:
  struct TextureInfo {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    Microsoft::WRL::ComPtr<ID3D11ShaderResourceView> texture_view;
    int width = 0;
    int height = 0;
    std::string file_name;
  };

  explicit Live2DTextureManager(ID3D11Device* device);
  ~Live2DTextureManager();

  TextureInfo* CreateTextureFromPngFile(const std::string& file_path);
  void ReleaseTextures();

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  std::vector<std::unique_ptr<TextureInfo>> textures_;
};
