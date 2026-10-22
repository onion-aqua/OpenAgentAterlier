#pragma once

#include <CubismFramework.hpp>

#include <string>

class Live2DPal {
 public:
  static Csm::csmByte* LoadFileAsBytes(std::string file_path,
                                       Csm::csmSizeInt* out_size);
  static void ReleaseBytes(Csm::csmByte* bytes);
  static Csm::csmFloat32 GetDeltaTime();
  static void UpdateTime();

 private:
  static double last_frame_seconds_;
  static double delta_time_seconds_;
};
