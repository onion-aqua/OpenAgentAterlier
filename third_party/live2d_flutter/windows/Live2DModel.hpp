#pragma once

#include <CubismFramework.hpp>
#include <ICubismModelSetting.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Model/CubismUserModel.hpp>
#include <Type/csmVector.hpp>

#include <string>

#include "Live2DTextureManager.hpp"

class Live2DModel : public Csm::CubismUserModel {
 public:
  explicit Live2DModel(Live2DTextureManager* texture_manager);
  ~Live2DModel() override;

  void LoadAssets(const Csm::csmChar* model_dir,
                  const Csm::csmChar* model_file_name);
  void Update();
  void Draw(const Csm::CubismMatrix44& matrix);
  void StartMotion(const Csm::csmChar* group, Csm::csmInt32 index,
                   Csm::csmInt32 priority);
  bool SetIdleMotion(const Csm::csmChar* group, Csm::csmInt32 index);
  void SetExpression(Csm::csmInt32 index);
  void SetParameterValue(const Csm::csmChar* parameter_id,
                         Csm::csmFloat32 value);
  void SetMotionSpeed(Csm::csmFloat32 speed);
  void SetupTextures();
  void ResizeMaskBuffer(int width, int height);

  bool IsLoaded() const { return _modelSetting != nullptr && _model != nullptr; }

 protected:
  Csm::csmByte* CreateBuffer(const Csm::csmChar* path,
                             Csm::csmSizeInt* size);
  void DeleteBuffer(Csm::csmByte* buffer);

 private:
  void SetupModel();
  void PreloadMotionGroup(const Csm::csmChar* group);
  void ReleaseMotions();
  void ReleaseExpressions();

  Csm::ICubismModelSetting* _modelSetting;
  std::string model_home_dir_;
  Csm::csmFloat32 user_time_seconds_;
  Csm::csmFloat32 motion_speed_ = 1.0f;
  std::string idle_motion_group_ = "Idle";
  Csm::csmInt32 idle_motion_index_ = 0;
  Live2DTextureManager* texture_manager_;

  Csm::csmVector<Csm::CubismIdHandle> lip_sync_ids_;
  Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> motions_;
  Csm::csmMap<Csm::csmString, Csm::ACubismMotion*> expressions_;
  Csm::csmMap<Csm::CubismIdHandle, Csm::csmFloat32> parameter_overrides_;

  const Csm::CubismId* id_param_angle_x_;
  const Csm::CubismId* id_param_angle_y_;
  const Csm::CubismId* id_param_angle_z_;
  const Csm::CubismId* id_param_body_angle_x_;
  const Csm::CubismId* id_param_eye_ball_x_;
  const Csm::CubismId* id_param_eye_ball_y_;
};
