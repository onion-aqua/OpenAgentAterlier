#include "Live2DPal.hpp"

#include <windows.h>

#include <chrono>
#include <climits>
#include <cerrno>
#include <cstdio>

using namespace Csm;

double Live2DPal::last_frame_seconds_ = 0.0;
double Live2DPal::delta_time_seconds_ = 0.0;

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1,
                                         nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), length);
  result.resize(static_cast<size_t>(length - 1));
  return result;
}

std::wstring ResolveFilePath(const std::string& file_path) {
  std::wstring path = Utf8ToWide(file_path);
  if (path.empty() || path.front() == L'\\' || path.front() == L'/' ||
      (path.size() >= 2 && path[1] == L':')) {
    return path;
  }

  wchar_t executable_path[MAX_PATH] = {};
  const DWORD length = GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return path;
  std::wstring base(executable_path, length);
  const size_t separator = base.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return path;
  base.resize(separator + 1);
  return base + path;
}

double NowSeconds() {
  using Clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
}

}  // namespace

csmByte* Live2DPal::LoadFileAsBytes(std::string file_path,
                                    csmSizeInt* out_size) {
  *out_size = 0;
  const std::wstring wide_path = ResolveFilePath(file_path);
  if (wide_path.empty()) return nullptr;

  FILE* file = nullptr;
  const errno_t open_error = _wfopen_s(&file, wide_path.c_str(), L"rb");
  if (open_error != 0 || !file) return nullptr;
  _fseeki64(file, 0, SEEK_END);
  const __int64 length = _ftelli64(file);
  _fseeki64(file, 0, SEEK_SET);
  if (length <= 0 || length > INT_MAX) {
    fclose(file);
    return nullptr;
  }

  auto* bytes = new csmByte[static_cast<size_t>(length)];
  const size_t read = fread(bytes, 1, static_cast<size_t>(length), file);
  fclose(file);
  if (read != static_cast<size_t>(length)) {
    delete[] bytes;
    return nullptr;
  }
  *out_size = static_cast<csmSizeInt>(length);
  return bytes;
}

void Live2DPal::ReleaseBytes(csmByte* bytes) { delete[] bytes; }

csmFloat32 Live2DPal::GetDeltaTime() {
  return static_cast<csmFloat32>(delta_time_seconds_);
}

void Live2DPal::UpdateTime() {
  const double current = NowSeconds();
  delta_time_seconds_ =
      last_frame_seconds_ == 0.0 ? 0.0 : current - last_frame_seconds_;
  last_frame_seconds_ = current;
}
