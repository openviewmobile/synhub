#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// r711 (W-B9): single instance.
//   Clicking a system toast makes Windows start ANOTHER process: MSIX AUMID
//   activation has no "forward to the running instance" semantics unless the
//   app implements C++/WinRT `AppInstance.RedirectActivationToAsync`.
//   Measured in r711: after a toast click the process count went 1 -> 2
//   (pid 8524 logged in, pid 6276 new and showing "offline"), and the original
//   window stayed behind. So the user's click landed in a dead end.
//   => Guard with a named mutex: if an instance exists, bring its window to the
//   front and exit. Our toasts carry no activation payload (no launch/arguments
//   set on ToastNotification), so "focus the window" is the intended semantics.
// NOTE: keep this file ASCII-only. MSVC builds it under code page 936 here and
//   C4819 is treated as an error; worse, a GBK trailing 0x5C byte can swallow
//   the next source line and produce bogus "undeclared identifier" errors
//   (r711 burned one full build on exactly that).
static HANDLE g_instance_mutex = nullptr;

static HWND FindRunningMainWindow() {
  struct Search {
    HWND found;
  } search{nullptr};
  ::EnumWindows(
      [](HWND hwnd, LPARAM param) -> BOOL {
        wchar_t class_name[256];
        if (::GetClassNameW(hwnd, class_name, 256) == 0) return TRUE;
        if (::wcscmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) {
          return TRUE;
        }
        wchar_t title[256];
        if (::GetWindowTextW(hwnd, title, 256) == 0) return TRUE;
        if (::wcscmp(title, L"SynHub") != 0) return TRUE;
        if (!::IsWindowVisible(hwnd)) return TRUE;
        reinterpret_cast<Search*>(param)->found = hwnd;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // r711 (W-B9): single-instance gate BEFORE COM/engine starts, so a duplicate
  // activation does not pay for a full Flutter engine boot first.
  g_instance_mutex = ::CreateMutexW(nullptr, TRUE, L"Local\\SynHub.SingleInstance");
  if (g_instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = FindRunningMainWindow();
    if (running != nullptr) {
      if (::IsIconic(running)) ::ShowWindow(running, SW_RESTORE);
      ::SetForegroundWindow(running);
    }
    ::CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
    return EXIT_SUCCESS;
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
  if (!window.Create(L"SynHub", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (g_instance_mutex != nullptr) {
    ::ReleaseMutex(g_instance_mutex);
    ::CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
  }
  return EXIT_SUCCESS;
}
