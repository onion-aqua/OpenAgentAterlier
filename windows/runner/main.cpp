#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <app_links/app_links_plugin_c_api.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
void RegisterFishMcpProtocol() {
  HKEY scheme_key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\agentatelier-fishmcp", 0,
                      nullptr, 0, KEY_SET_VALUE, nullptr, &scheme_key,
                      nullptr) != ERROR_SUCCESS) {
    return;
  }
  const wchar_t url_protocol[] = L"URL:AgentAtelier Fish MCP";
  RegSetValueExW(scheme_key, nullptr, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(url_protocol),
                 sizeof(url_protocol));
  const wchar_t empty[] = L"";
  RegSetValueExW(scheme_key, L"URL Protocol", 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(empty), sizeof(empty));
  HKEY command_key = nullptr;
  if (RegCreateKeyExW(scheme_key, L"shell\\open\\command", 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &command_key,
                      nullptr) == ERROR_SUCCESS) {
    wchar_t executable[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, executable, MAX_PATH);
    std::wstring command = L"\"" + std::wstring(executable) + L"\" \"%1\"";
    RegSetValueExW(command_key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(command.c_str()),
                   static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(command_key);
  }
  RegCloseKey(scheme_key);
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Browser OAuth callbacks launch the URL protocol command as another
  // process. Forward the link to the running instance, which owns the PKCE
  // verifier and state, before creating a second Flutter engine.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  RegisterFishMcpProtocol();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // Keep the desktop window in the same portrait ratio as the mobile UI.
  Win32Window::Size size(540, 960);
  if (!window.Create(L"AgentAtelier", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
