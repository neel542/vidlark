#pragma once
// Small pictures for the panel: JPEG in base64, ready for a data: link.

#include <windows.h>

#include <string>
#include <vector>

namespace app {

std::string base64(const BYTE* data, size_t size);
// A BGRA picture as a JPEG in base64, or nothing if it could not be made. Uses COM (WIC) on this thread.
std::string jpegBase64(const std::vector<BYTE>& bgra, UINT32 w, UINT32 h);

}  // namespace app
