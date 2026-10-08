# Vidlark for Windows.
#   vidlark-finish  the after-stop tool (sync, transcript, retakes, chapters, video.mp4, report).
#                   Plain C++20, so it also builds and runs on a Mac, where Tests/run_tests.sh checks it.
#   vidlark-tests   unit tests for the finisher's logic.
#   Vidlark         the Windows app itself (Windows only).
cmake_minimum_required(VERSION 3.24)
project(Vidlark VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

include(FetchContent)
FetchContent_Declare(json
  URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
  URL_HASH SHA256=d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_MakeAvailable(json)

if(MSVC)
  add_compile_options(/utf-8 /W4 /permissive- /EHsc)
  add_compile_definitions(UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
  # One exe with nothing to install alongside it.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
  add_compile_options(-Wall -Wextra -Wno-unused-parameter)
endif()

# The finisher's logic, shared by the tool and the tests.
add_library(finish_core STATIC
  finish/support.cpp
  finish/audio.cpp
  finish/events.cpp
  finish/chapters.cpp
  finish/transcript.cpp
  finish/report.cpp
  finish/compose.cpp
  core/library.cpp)
target_include_directories(finish_core PUBLIC finish core)
target_link_libraries(finish_core PUBLIC nlohmann_json::nlohmann_json)

add_executable(vidlark-finish finish/main.cpp)
target_link_libraries(vidlark-finish PRIVATE finish_core $<$<BOOL:${WIN32}>:shell32>)

add_executable(vidlark-tests tests/unit.cpp tests/test_audio.cpp tests/test_text.cpp tests/test_library.cpp)
target_link_libraries(vidlark-tests PRIVATE finish_core)
enable_testing()
add_test(NAME unit COMMAND vidlark-tests)

if(WIN32)
  add_subdirectory(app)
endif()
