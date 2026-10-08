#pragma once
// What this PC can record from: cameras (Media Foundation), microphones (the audio endpoints) and screens.

#include <nlohmann/json.hpp>

#include <string>

namespace app {

std::string utf8(const std::wstring& text);
std::wstring wide(const std::string& text);

// [{ "name": "...", "id": "..." }], cameras in the order Windows lists them.
nlohmann::json cameras();
// [{ "name": "...", "id": "...", "default": true }]
nlohmann::json microphones();
// [{ "name": "...", "width": 2560, "height": 1440, "primary": true }]
nlohmann::json screens();

}  // namespace app
