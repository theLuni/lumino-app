#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <app_links/app_links_plugin_c_api.h>
#include <windows.h>
#include <shlobj.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

bool RegisterLuminoProtocol() {
  std::vector<wchar_t> executable_path(32768);
  const DWORD path_length = GetModuleFileNameW(
      nullptr, executable_path.data(),
      static_cast<DWORD>(executable_path.size()));
  if (path_length == 0 || path_length >= executable_path.size()) {
    OutputDebugStringW(L"Lumino could not resolve its executable path.\n");
    return false;
  }

  const std::wstring executable(executable_path.data(), path_length);
  const std::wstring root = L"Software\\Classes\\lumino";
  const auto set_value = [](const std::wstring& key_path,
                            const wchar_t* name,
                            const std::wstring& value) {
    HKEY key = nullptr;
    const LSTATUS opened = RegCreateKeyExW(
        HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr, REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE, nullptr, &key, nullptr);
    if (opened != ERROR_SUCCESS) {
      return opened;
    }
    const LSTATUS written = RegSetValueExW(
        key, name, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(value.c_str()),
        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    return written;
  };

  const std::wstring command = L"\"" + executable + L"\" \"%1\"";
  const std::wstring icon = L"\"" + executable + L"\",0";
  const bool registered =
      set_value(root, nullptr, L"URL:Lumino Protocol") == ERROR_SUCCESS &&
      set_value(root, L"URL Protocol", L"") == ERROR_SUCCESS &&
      set_value(root + L"\\DefaultIcon", nullptr, icon) == ERROR_SUCCESS &&
      set_value(root + L"\\shell\\open\\command", nullptr, command) ==
          ERROR_SUCCESS;
  if (!registered) {
    OutputDebugStringW(L"Lumino could not register the lumino:// URL protocol.\n");
  } else {
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  }
  return registered;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  RegisterLuminoProtocol();
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

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lumino", origin, size)) {
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
