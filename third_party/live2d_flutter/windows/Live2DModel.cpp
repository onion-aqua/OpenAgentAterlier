#include "Live2DModel.hpp"

#include <CubismDefaultParameterId.hpp>
#include <CubismModelSettingJson.hpp>
#include <Effect/CubismEyeBlink.hpp>
#include <Id/CubismIdManager.hpp>
#include <Motion/CubismMotion.hpp>
#include <Physics/CubismPhysics.hpp>
#include <Rendering/D3D11/CubismRenderer_D3D11.hpp>
#include <Utils/CubismString.hpp>

#include <cstdio>
#include <cstring>
#include <cmath>

#include "Live2DPal.hpp"

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::DefaultParameterId;

namespace {
constexpr int kPriorityIdle = 1;
}

Live2DModel::Live2DModel(Live2DTextureManager* texture_manager)
    : CubismUserModel(),
      _modelSetting(nullptr),
      user_time_seconds_(0.0f),
      texture_manager_(texture_manager) {
  id_param_angle_x_ = CubismFramework::GetIdManager()->GetId(ParamAngleX);
  id_param_angle_y_ = CubismFramework::GetIdManager()->GetId(ParamAngleY);
  id_param_angle_z_ = CubismFramework::GetIdManager()->GetId(ParamAngleZ);
  id_param_body_angle_x_ =
      CubismFramework::GetIdManager()->GetId(ParamBodyAngleX);
  id_param_eye_ball_x_ =
      CubismFramework::GetIdManager()->GetId(ParamEyeBallX);
  id_param_eye_ball_y_ =
      CubismFramework::GetIdManager()->GetId(ParamEyeBallY);
}

Live2DModel::~Live2DModel() {
  ReleaseMotions();
  ReleaseExpressions();
  delete _modelSetting;
}

Csm::csmByte* Live2DModel::CreateBuffer(const Csm::csmChar* path,
                                        Csm::csmSizeInt* size) {
  return Live2DPal::LoadFileAsBytes(path, size);
}

void Live2DModel::DeleteBuffer(Csm::csmByte* buffer) {
  Live2DPal::ReleaseBytes(buffer);
}

void Live2DModel::LoadAssets(const Csm::csmChar* model_dir,
                             const Csm::csmChar* model_file_name) {
  model_home_dir_ = model_dir;
  Csm::csmSizeInt size = 0;
  const Csm::csmString path = Csm::csmString(model_dir) + model_file_name;
  Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
  if (!buffer || size <= 0) return;

  _modelSetting = new CubismModelSettingJson(buffer, size);
  DeleteBuffer(buffer);
  SetupModel();
}

void Live2DModel::SetupModel() {
  _updating = true;
  _initialized = false;

  {
    Csm::csmSizeInt size = 0;
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetModelFileName();
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (!buffer || size <= 0) return;
    LoadModel(buffer, size);
    DeleteBuffer(buffer);
    if (!_model) return;
  }

  for (Csm::csmInt32 i = 0; i < _modelSetting->GetExpressionCount(); ++i) {
    const Csm::csmChar* name = _modelSetting->GetExpressionName(i);
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetExpressionFileName(i);
    Csm::csmSizeInt size = 0;
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (!buffer) continue;
    expressions_[name] = LoadExpression(buffer, size, name);
    DeleteBuffer(buffer);
  }

  if (strcmp(_modelSetting->GetPhysicsFileName(), "") != 0) {
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetPhysicsFileName();
    Csm::csmSizeInt size = 0;
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (buffer) {
      LoadPhysics(buffer, size);
      DeleteBuffer(buffer);
    }
  }

  if (strcmp(_modelSetting->GetPoseFileName(), "") != 0) {
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetPoseFileName();
    Csm::csmSizeInt size = 0;
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (buffer) {
      LoadPose(buffer, size);
      DeleteBuffer(buffer);
    }
  }

  if (_modelSetting->GetEyeBlinkParameterCount() > 0) {
    _eyeBlink = CubismEyeBlink::Create(_modelSetting);
  }

  for (Csm::csmInt32 i = 0;
       i < _modelSetting->GetLipSyncParameterCount(); ++i) {
    lip_sync_ids_.PushBack(_modelSetting->GetLipSyncParameterId(i));
  }

  if (strcmp(_modelSetting->GetUserDataFile(), "") != 0) {
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetUserDataFile();
    Csm::csmSizeInt size = 0;
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (buffer) {
      LoadUserData(buffer, size);
      DeleteBuffer(buffer);
    }
  }

  for (Csm::csmInt32 i = 0; i < _modelSetting->GetMotionGroupCount(); ++i) {
    PreloadMotionGroup(_modelSetting->GetMotionGroupName(i));
  }

  _model->SaveParameters();
  _updating = false;
  _initialized = true;
}

void Live2DModel::SetupTextures() {
  auto* renderer = GetRenderer<Rendering::CubismRenderer_D3D11>();
  if (!renderer) return;

  for (Csm::csmInt32 i = 0; i < _modelSetting->GetTextureCount(); ++i) {
    if (strcmp(_modelSetting->GetTextureFileName(i), "") == 0) continue;
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetTextureFileName(i);
    auto* texture =
        texture_manager_->CreateTextureFromPngFile(path.GetRawString());
    if (texture) renderer->BindTexture(i, texture->texture_view.Get());
  }
  renderer->IsPremultipliedAlpha(false);
}

void Live2DModel::PreloadMotionGroup(const Csm::csmChar* group) {
  for (Csm::csmInt32 i = 0; i < _modelSetting->GetMotionCount(group); ++i) {
    const Csm::csmString path =
        Csm::csmString(model_home_dir_.c_str()) +
        _modelSetting->GetMotionFileName(group, i);
    Csm::csmSizeInt size = 0;
    Csm::csmByte* buffer = CreateBuffer(path.GetRawString(), &size);
    if (!buffer) continue;
    auto* motion =
        static_cast<CubismMotion*>(LoadMotion(buffer, size, nullptr));
    DeleteBuffer(buffer);
    if (!motion) continue;

    Csm::csmFloat32 fade_time =
        _modelSetting->GetMotionFadeInTimeValue(group, i);
    if (fade_time >= 0.0f) motion->SetFadeInTime(fade_time);
    fade_time = _modelSetting->GetMotionFadeOutTimeValue(group, i);
    if (fade_time >= 0.0f) motion->SetFadeOutTime(fade_time);

    char index[16];
    snprintf(index, sizeof(index), "%d", i);
    const Csm::csmString name = Csm::csmString(group) + "_" + index;
    motions_[name.GetRawString()] = motion;
  }
}

void Live2DModel::ReleaseMotions() {
  for (Csm::csmMap<Csm::csmString, Csm::ACubismMotion*>::const_iterator it =
           motions_.Begin();
       it != motions_.End(); ++it) {
    Csm::ACubismMotion::Delete(it->Second);
  }
  motions_.Clear();
}

void Live2DModel::ReleaseExpressions() {
  for (Csm::csmMap<Csm::csmString, Csm::ACubismMotion*>::const_iterator it =
           expressions_.Begin();
       it != expressions_.End(); ++it) {
    Csm::ACubismMotion::Delete(it->Second);
  }
  expressions_.Clear();
}

void Live2DModel::Update() {
  if (!_model) return;
  const Csm::csmFloat32 delta_time = Live2DPal::GetDeltaTime();
  user_time_seconds_ += delta_time;

  _dragManager->Update(delta_time);
  const Csm::csmFloat32 drag_x = _dragManager->GetX();
  const Csm::csmFloat32 drag_y = _dragManager->GetY();

  _model->LoadParameters();
  if (_motionManager->IsFinished()) {
    StartMotion(idle_motion_group_.c_str(), idle_motion_index_, kPriorityIdle);
  } else {
    _motionManager->UpdateMotion(_model, delta_time * motion_speed_);
  }
  _model->SaveParameters();

  _model->AddParameterValue(id_param_angle_x_, drag_x * 30.0f);
  _model->AddParameterValue(id_param_angle_y_, drag_y * 30.0f);
  _model->AddParameterValue(id_param_angle_z_, drag_x * drag_y * -30.0f);
  _model->AddParameterValue(id_param_body_angle_x_, drag_x * 10.0f);
  _model->AddParameterValue(id_param_eye_ball_x_, drag_x);
  _model->AddParameterValue(id_param_eye_ball_y_, drag_y);

  if (_eyeBlink) _eyeBlink->UpdateParameters(_model, delta_time);
  if (_expressionManager) {
    _expressionManager->UpdateMotion(_model, delta_time);
  }
  if (_physics) _physics->Evaluate(_model, delta_time);
  if (_pose) _pose->UpdateParameters(_model, delta_time);
  // External controls override animation layers after the saved baseline has
  // been restored and updated, matching Android's lip-sync parameter pipeline.
  for (Csm::csmMap<Csm::CubismIdHandle, Csm::csmFloat32>::const_iterator i =
           parameter_overrides_.Begin(); i != parameter_overrides_.End(); ++i) {
    _model->SetParameterValue(i->First, i->Second);
  }
  _model->Update();
}

void Live2DModel::Draw(const Csm::CubismMatrix44& matrix) {
  if (!_model) return;
  Csm::CubismMatrix44 mvp = matrix;
  mvp.MultiplyByMatrix(_modelMatrix);
  auto* renderer = GetRenderer<Rendering::CubismRenderer_D3D11>();
  if (!renderer) return;
  renderer->SetMvpMatrix(&mvp);
  renderer->DrawModel();
}

void Live2DModel::StartMotion(const Csm::csmChar* group,
                              Csm::csmInt32 index,
                              Csm::csmInt32 priority) {
  if (!_modelSetting || !group) return;
  const Csm::csmInt32 count = _modelSetting->GetMotionCount(group);
  if (index < 0 || index >= count) return;

  char index_text[16];
  snprintf(index_text, sizeof(index_text), "%d", index);
  const Csm::csmString name = Csm::csmString(group) + "_" + index_text;
  if (!motions_.IsExist(name)) return;

  if (priority == 3) {
    _motionManager->SetReservePriority(priority);
  } else if (!_motionManager->ReserveMotion(priority)) {
    return;
  }
  _motionManager->StartMotionPriority(motions_[name], false, priority);
}

bool Live2DModel::SetIdleMotion(const Csm::csmChar* group,
                                Csm::csmInt32 index) {
  if (!_modelSetting || !group || index < 0 ||
      index >= _modelSetting->GetMotionCount(group)) {
    return false;
  }
  char index_text[16];
  snprintf(index_text, sizeof(index_text), "%d", index);
  const Csm::csmString name = Csm::csmString(group) + "_" + index_text;
  if (!motions_.IsExist(name) || !motions_[name]) return false;

  idle_motion_group_ = group;
  idle_motion_index_ = index;
  return true;
}

void Live2DModel::SetExpression(Csm::csmInt32 index) {
  if (!_modelSetting || index < 0 ||
      index >= _modelSetting->GetExpressionCount()) {
    return;
  }
  const Csm::csmChar* name = _modelSetting->GetExpressionName(index);
  if (expressions_.IsExist(name)) {
    _expressionManager->StartMotion(expressions_[name], false);
  }
}

void Live2DModel::ResizeMaskBuffer(int width, int height) {
  auto* renderer = GetRenderer<Rendering::CubismRenderer_D3D11>();
  if (renderer) {
    renderer->SetDrawableClippingMaskBufferSize(
        static_cast<Csm::csmFloat32>(width),
        static_cast<Csm::csmFloat32>(height));
  }
}

void Live2DModel::SetParameterValue(const Csm::csmChar* parameter_id,
                                    Csm::csmFloat32 value) {
  if (!_model || !parameter_id || parameter_id[0] == '\0' ||
      !std::isfinite(value)) return;
  const Csm::CubismId* id =
      CubismFramework::GetIdManager()->GetId(parameter_id);
  parameter_overrides_[id] = value;
}

void Live2DModel::SetMotionSpeed(Csm::csmFloat32 speed) {
  motion_speed_ = speed > 0.0f ? speed : 0.0f;
}
