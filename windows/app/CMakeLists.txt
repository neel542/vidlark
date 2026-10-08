# Vidlark.exe: a Win32 window hosting the app's screens in WebView2, with the recording done in C++.
FetchContent_Declare(webview2
  URL https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4258.31/microsoft.web.webview2.1.0.4258.31.nupkg
  URL_HASH SHA256=56f7f4b8bf9aee4b8efefbbdd4f67d5f74ebd1b100ed0806da71bf76af481aa9
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(webview2)
set(WEBVIEW2_DIR ${webview2_SOURCE_DIR}/build/native)

# Recording: the movie writer now; camera, mics and screen next.
add_library(capture STATIC capture/writer.cpp)
target_link_libraries(capture PUBLIC mfplat mfreadwrite mfuuid mf ole32)

# Writes a test movie with the writer, for CI (no camera there).
add_executable(vidlark-writer-test tests/writer_test.cpp)
target_link_libraries(vidlark-writer-test PRIVATE capture)

add_executable(Vidlark WIN32
  main.cpp
  devices.cpp
  app.manifest
  app.rc)
target_include_directories(Vidlark PRIVATE ${WEBVIEW2_DIR}/include)
target_link_libraries(Vidlark PRIVATE
  nlohmann_json::nlohmann_json
  capture
  ${WEBVIEW2_DIR}/x64/WebView2LoaderStatic.lib
  version mfplat mf mfuuid ole32 shell32 dwmapi)

# The screens, and the finisher, sit next to Vidlark.exe.
add_dependencies(Vidlark vidlark-finish)
add_custom_command(TARGET Vidlark POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/ui $<TARGET_FILE_DIR:Vidlark>/ui
  COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:vidlark-finish> $<TARGET_FILE_DIR:Vidlark>)
