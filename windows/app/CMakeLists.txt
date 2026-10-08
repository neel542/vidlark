# Vidlark.exe: a Win32 window hosting the app's screens in WebView2, with the recording done in C++.
FetchContent_Declare(webview2
  URL https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4258.31/microsoft.web.webview2.1.0.4258.31.nupkg
  URL_HASH SHA256=56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(webview2)
set(WEBVIEW2_DIR ${webview2_SOURCE_DIR}/build/native)

# Recording: the movie writer, camera, mics, the screen (Windows.Graphics.Capture through C++/WinRT), and
# the stage and face bubble windows that put her camera on the recorded screen.
add_library(capture STATIC capture/writer.cpp capture/camera.cpp capture/mic.cpp capture/gpu.cpp capture/screen.cpp overlay.cpp)
target_link_libraries(capture PUBLIC finish_core mfplat mfreadwrite mfuuid mf ole32 avrt d3d11 dxgi d3dcompiler dcomp dwmapi shcore windowsapp)
# C++/WinRT's headers come with the Windows SDK; Visual Studio usually has them on the path already.
if(CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION)
  get_filename_component(kits_root "[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots;KitsRoot10]" ABSOLUTE)
  set(cppwinrt_dir "${kits_root}/Include/${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}/cppwinrt")
  if(EXISTS "${cppwinrt_dir}/winrt/base.h")
    target_include_directories(capture PUBLIC "${cppwinrt_dir}")
  endif()
endif()

# Writes a test movie with the writer, for CI (no camera there).
add_executable(vidlark-writer-test tests/writer_test.cpp)
target_link_libraries(vidlark-writer-test PRIVATE capture)

# Records the screen with the stage and bubble windows into a screen.mov, for CI.
add_executable(vidlark-screen-test tests/screen_test.cpp)
target_link_libraries(vidlark-screen-test PRIVATE capture nlohmann_json::nlohmann_json)

add_executable(Vidlark WIN32
  main.cpp
  devices.cpp
  picture.cpp
  session.cpp
  app.manifest
  app.rc)
target_include_directories(Vidlark PRIVATE ${WEBVIEW2_DIR}/include)
target_link_libraries(Vidlark PRIVATE
  nlohmann_json::nlohmann_json
  capture
  finish_core
  ${WEBVIEW2_DIR}/x64/WebView2LoaderStatic.lib
  version mfplat mf mfuuid ole32 shell32 dwmapi windowscodecs)

# The screens, and the finisher, sit next to Vidlark.exe.
add_dependencies(Vidlark vidlark-finish)
add_custom_command(TARGET Vidlark POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/ui $<TARGET_FILE_DIR:Vidlark>/ui
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:vidlark-finish> $<TARGET_FILE_DIR:Vidlark>)
