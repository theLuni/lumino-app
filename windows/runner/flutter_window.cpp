#include "flutter_window.h"

#include <optional>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "flutter/standard_method_codec.h"

namespace {

bool g_efficiency_mode_active = false;
DWORD g_original_priority_class = 0;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  efficiency_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "lumino/efficiency",
          &flutter::StandardMethodCodec::GetInstance());
  efficiency_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setEfficiencyMode") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Expected a settings map.");
          return;
        }
        const auto enabled = arguments->find(flutter::EncodableValue("enabled"));
        const auto minimized =
            arguments->find(flutter::EncodableValue("minimized"));
        if (enabled == arguments->end() || minimized == arguments->end()) {
          result->Error("invalid_arguments",
                        "Expected enabled and minimized boolean values.");
          return;
        }
        const auto* is_enabled = std::get_if<bool>(&enabled->second);
        const auto* is_minimized = std::get_if<bool>(&minimized->second);
        if (is_enabled == nullptr || is_minimized == nullptr) {
          result->Error("invalid_arguments",
                        "Expected enabled and minimized boolean values.");
          return;
        }

        const bool should_enable = *is_enabled && *is_minimized;
        if (should_enable == g_efficiency_mode_active) {
          result->Success();
          return;
        }

        const HANDLE process = GetCurrentProcess();
        PROCESS_POWER_THROTTLING_STATE state{};
        state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
        state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
        state.StateMask =
            should_enable ? PROCESS_POWER_THROTTLING_EXECUTION_SPEED : 0;

        if (should_enable) {
          const DWORD original_priority = GetPriorityClass(process);
          if (original_priority == 0) {
            const DWORD error = GetLastError();
            result->Error("get_priority_class_failed",
                          "Windows could not read the process priority.",
                          flutter::EncodableValue(static_cast<int32_t>(error)));
            return;
          }
          if (!SetProcessInformation(process, ProcessPowerThrottling, &state,
                                     sizeof(state))) {
            const DWORD error = GetLastError();
            result->Error(
                "set_process_information_failed",
                "Windows could not enable process power throttling.",
                flutter::EncodableValue(static_cast<int32_t>(error)));
            return;
          }
          if (!SetPriorityClass(process, BELOW_NORMAL_PRIORITY_CLASS)) {
            const DWORD error = GetLastError();
            state.StateMask = 0;
            SetProcessInformation(process, ProcessPowerThrottling, &state,
                                  sizeof(state));
            result->Error("set_priority_class_failed",
                          "Windows could not lower the process priority.",
                          flutter::EncodableValue(static_cast<int32_t>(error)));
            return;
          }
          g_original_priority_class = original_priority;
        } else {
          if (!SetProcessInformation(process, ProcessPowerThrottling, &state,
                                     sizeof(state))) {
            const DWORD error = GetLastError();
            result->Error(
                "set_process_information_failed",
                "Windows could not disable process power throttling.",
                flutter::EncodableValue(static_cast<int32_t>(error)));
            return;
          }
          if (g_original_priority_class != 0 &&
              !SetPriorityClass(process, g_original_priority_class)) {
            const DWORD error = GetLastError();
            state.StateMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
            SetProcessInformation(process, ProcessPowerThrottling, &state,
                                  sizeof(state));
            result->Error("restore_priority_class_failed",
                          "Windows could not restore the process priority.",
                          flutter::EncodableValue(static_cast<int32_t>(error)));
            return;
          }
          g_original_priority_class = 0;
        }

        g_efficiency_mode_active = should_enable;
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  efficiency_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
