#pragma once
// What this PC can record from: cameras (Media Foundation), microphones (the audio endpoints) and screens.

#include <windows.h>
#include <nlohmann/json.hpp>

#include <string>

namespace app {

std::string utf8(const std::wstring& text);
std::wstring wide(const std::string& text);

// [{ "name": "...", "id": "..." }], cameras in the order Windows lists them.
nlohmann::json cameras();
// [{ "name": "...", "id": "...", "default": true }]
nlohmann::json microphones();
// [{ "id": "\\\\.\\DISPLAY1", "name": "Built-in screen", "width": 2560, "height": 1440, "primary": true }], in pixels.
nlohmann::json screens();
// What Share screen can record, each with a small picture (JPEG, base64):
// {"screens": [{"kind": "screen", "id", "name", "detail", "jpeg", "width", "height"}],
//  "windows": [{"kind": "window", "id", "name", "detail", "jpeg", "width", "height"}]}.
// Vidlark's own windows are left out. Slow (it draws every window), so not on the window thread.
nlohmann::json shareChoices();
// The screen with this id, or the main screen when it is not connected.
HMONITOR monitorById(const std::string& id);
// The screen's name as people know it: the monitor's own name, "Built-in screen", or "Screen N".
std::string screenName(HMONITOR monitor);
// A window as the picker names it: "App: title", or just the title.
std::string windowName(HWND window);

}  // namespace app
