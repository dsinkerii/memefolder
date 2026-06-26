#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Check for verbose flag file at %APPDATA%\dsinkerii\memefolder\verbose.txt.
  // If present, attach or allocate a console for debug output.
  bool verbose = false;
  {
    char appdata[MAX_PATH];
    DWORD len = GetEnvironmentVariableA("APPDATA", appdata, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      char flagPath[MAX_PATH];
      snprintf(flagPath, MAX_PATH, "%s\\dsinkerii\\memefolder\\verbose.txt", appdata);
      verbose = (GetFileAttributesA(flagPath) != INVALID_FILE_ATTRIBUTES);
    }
  }
  if (verbose) {
    if (!::AttachConsole(ATTACH_PARENT_PROCESS)) {
      CreateAndAttachConsole();
    }
    fprintf(stderr, "[memefolder] started (verbose)\n");
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
  if (!window.Create(L"memefolder", origin, size)) {
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
