#include "devices.h"

#include <windows.h>
#include <propsys.h>
#include <initguid.h>  // defines PKEY_Device_FriendlyName below, in this file only
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <dwmapi.h>

#include "picture.h"

#include <algorithm>
#include <filesystem>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace app {

std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n);
    return out;
}

nlohmann::json cameras() {
    auto list = nlohmann::json::array();
    ComPtr<IMFAttributes> attributes;
    if (FAILED(MFCreateAttributes(&attributes, 1))) return list;
    attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    if (FAILED(MFEnumDeviceSources(attributes.Get(), &devices, &count))) return list;
    for (UINT32 i = 0; i < count; i++) {
        auto text = [&](REFGUID key) {
            WCHAR* value = nullptr;
            UINT32 length = 0;
            std::wstring out;
            if (SUCCEEDED(devices[i]->GetAllocatedString(key, &value, &length))) {
                out.assign(value, length);
                CoTaskMemFree(value);
            }
            return out;
        };
        list.push_back({{"name", utf8(text(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME))},
                        {"id", utf8(text(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK))}});
        devices[i]->Release();
    }
    CoTaskMemFree(devices);
    return list;
}

nlohmann::json microphones() {
    auto list = nlohmann::json::array();
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return list;
    std::wstring defaultId;
    ComPtr<IMMDevice> fallback;
    if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &fallback))) {
        LPWSTR id = nullptr;
        if (SUCCEEDED(fallback->GetId(&id))) {
            defaultId = id;
            CoTaskMemFree(id);
        }
    }
    ComPtr<IMMDeviceCollection> collection;
    if (FAILED(enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection))) return list;
    UINT count = 0;
    collection->GetCount(&count);
    for (UINT i = 0; i < count; i++) {
        ComPtr<IMMDevice> device;
        if (FAILED(collection->Item(i, &device))) continue;
        std::wstring id;
        LPWSTR raw = nullptr;
        if (SUCCEEDED(device->GetId(&raw))) {
            id = raw;
            CoTaskMemFree(raw);
        }
        std::wstring name;
        ComPtr<IPropertyStore> properties;
        if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &properties))) {
            PROPVARIANT value;
            PropVariantInit(&value);
            if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) && value.vt == VT_LPWSTR) name = value.pwszVal;
            PropVariantClear(&value);
        }
        list.push_back({{"name", utf8(name)}, {"id", utf8(id)}, {"default", id == defaultId}});
    }
    return list;
}

namespace {

std::vector<HMONITOR> monitors() {
    std::vector<HMONITOR> list;
    EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR m, HDC, LPRECT, LPARAM data) -> BOOL {
        reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(m);
        return TRUE;
    }, reinterpret_cast<LPARAM>(&list));
    return list;
}

// The monitor's own name from the display settings ("DELL U2720Q"), or "Built-in screen" for a laptop's.
std::wstring friendlyName(const wchar_t* gdiName) {
    UINT32 pathCount = 0, modeCount = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &pathCount, &modeCount) != ERROR_SUCCESS) return {};
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(pathCount);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(modeCount);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &pathCount, paths.data(), &modeCount, modes.data(), nullptr) != ERROR_SUCCESS) return {};
    for (UINT32 i = 0; i < pathCount; i++) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
        source.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        source.header.size = sizeof source;
        source.header.adapterId = paths[i].sourceInfo.adapterId;
        source.header.id = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS || wcscmp(source.viewGdiDeviceName, gdiName) != 0) continue;
        DISPLAYCONFIG_TARGET_DEVICE_NAME target{};
        target.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        target.header.size = sizeof target;
        target.header.adapterId = paths[i].targetInfo.adapterId;
        target.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&target.header) != ERROR_SUCCESS) continue;
        const auto tech = target.outputTechnology;
        if (tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED ||
            tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED) {
            return L"Built-in screen";
        }
        if (target.monitorFriendlyDeviceName[0]) return target.monitorFriendlyDeviceName;
    }
    return {};
}

RECT frameOf(HWND window) {
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r))) GetWindowRect(window, &r);
    return r;
}

// What the app that owns a window calls itself: its file description ("Google Chrome"), or its file name.
std::wstring appName(HWND window) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return {};
    std::wstring path(32768, L'\0');
    DWORD size = static_cast<DWORD>(path.size());
    const bool found = QueryFullProcessImageNameW(process, 0, path.data(), &size);
    CloseHandle(process);
    if (!found) return {};
    path.resize(size);
    DWORD ignored = 0;
    const DWORD length = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (length) {
        std::vector<BYTE> data(length);
        struct Translation { WORD language, codePage; }* translation = nullptr;
        UINT translationSize = 0;
        if (GetFileVersionInfoW(path.c_str(), 0, length, data.data()) &&
            VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation", reinterpret_cast<void**>(&translation), &translationSize) &&
            translationSize >= sizeof(Translation)) {
            wchar_t key[64];
            swprintf(key, 64, L"\\StringFileInfo\\%04x%04x\\FileDescription", translation->language, translation->codePage);
            wchar_t* description = nullptr;
            UINT descriptionSize = 0;
            if (VerQueryValueW(data.data(), key, reinterpret_cast<void**>(&description), &descriptionSize) && descriptionSize > 1) {
                return std::wstring(description);
            }
        }
    }
    return std::filesystem::path(path).stem().wstring();
}

std::wstring titleOf(HWND window) {
    std::wstring title(GetWindowTextLengthW(window) + 1, L'\0');
    title.resize(GetWindowTextW(window, title.data(), static_cast<int>(title.size())));
    return title;
}

// Windows a person would share: on screen, a real size, with a title, not Vidlark's and not the desktop's.
std::vector<HWND> shareableWindows() {
    std::vector<HWND> list;
    EnumWindows([](HWND w, LPARAM data) -> BOOL {
        if (!IsWindowVisible(w) || IsIconic(w) || GetWindow(w, GW_OWNER)) return TRUE;
        if (GetWindowLongW(w, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return TRUE;
        DWORD cloaked = 0;
        DwmGetWindowAttribute(w, DWMWA_CLOAKED, &cloaked, sizeof cloaked);
        if (cloaked) return TRUE;  // on another desktop, or a suspended app
        DWORD pid = 0;
        GetWindowThreadProcessId(w, &pid);
        if (pid == GetCurrentProcessId()) return TRUE;
        wchar_t cls[64];
        GetClassNameW(w, cls, 64);
        for (const wchar_t* skip : {L"Progman", L"WorkerW", L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd", L"Windows.UI.Core.CoreWindow"}) {
            if (wcscmp(cls, skip) == 0) return TRUE;
        }
        if (GetWindowTextLengthW(w) == 0) return TRUE;
        const RECT r = frameOf(w);
        if (r.right - r.left < 120 || r.bottom - r.top < 80) return TRUE;
        reinterpret_cast<std::vector<HWND>*>(data)->push_back(w);
        return TRUE;
    }, reinterpret_cast<LPARAM>(&list));
    return list;
}

struct Thumb {
    std::vector<BYTE> bgra;
    UINT32 w = 0, h = 0;
};

// A 32-bit picture GDI can draw into, top row first.
HBITMAP dib(HDC dc, int w, int h, void** bits) {
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof info.bmiHeader;
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    return CreateDIBSection(dc, &info, DIB_RGB_COLORS, bits, nullptr, 0);
}

// `source` (a part of `from`) shrunk to fit 320 x 200.
Thumb shrink(HDC from, const RECT& source) {
    const int sw = std::max<LONG>(1, source.right - source.left), sh = std::max<LONG>(1, source.bottom - source.top);
    const double k = std::min({1.0, 320.0 / sw, 200.0 / sh});
    Thumb t;
    t.w = std::max(2, static_cast<int>(sw * k));
    t.h = std::max(2, static_cast<int>(sh * k));
    HDC dc = CreateCompatibleDC(from);
    void* bits = nullptr;
    HBITMAP bitmap = dib(from, t.w, t.h, &bits);
    HGDIOBJ old = SelectObject(dc, bitmap);
    SetStretchBltMode(dc, HALFTONE);
    SetBrushOrgEx(dc, 0, 0, nullptr);
    StretchBlt(dc, 0, 0, t.w, t.h, from, source.left, source.top, sw, sh, SRCCOPY);
    GdiFlush();
    t.bgra.assign(static_cast<BYTE*>(bits), static_cast<BYTE*>(bits) + static_cast<size_t>(t.w) * t.h * 4);
    for (size_t i = 3; i < t.bgra.size(); i += 4) t.bgra[i] = 255;
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    return t;
}

// The screen as it looks now. Vidlark's own windows are left out of this as they are out of the video.
Thumb screenThumb(const RECT& r) {
    HDC screen = GetDC(nullptr);
    HDC dc = CreateCompatibleDC(screen);
    void* bits = nullptr;
    HBITMAP bitmap = dib(screen, r.right - r.left, r.bottom - r.top, &bits);
    HGDIOBJ old = SelectObject(dc, bitmap);
    BitBlt(dc, 0, 0, r.right - r.left, r.bottom - r.top, screen, r.left, r.top, SRCCOPY | CAPTUREBLT);
    Thumb t = shrink(dc, RECT{0, 0, r.right - r.left, r.bottom - r.top});
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return t;
}

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

// One window drawn by itself, even where others cover it.
Thumb windowThumb(HWND window) {
    RECT whole{};
    GetWindowRect(window, &whole);
    const RECT frame = frameOf(window);
    const int w = whole.right - whole.left, h = whole.bottom - whole.top;
    HDC screen = GetDC(nullptr);
    HDC dc = CreateCompatibleDC(screen);
    void* bits = nullptr;
    HBITMAP bitmap = dib(screen, w, h, &bits);
    HGDIOBJ old = SelectObject(dc, bitmap);
    PrintWindow(window, dc, PW_RENDERFULLCONTENT);
    // Without the see-through edge Windows adds round a window.
    Thumb t = shrink(dc, RECT{frame.left - whole.left, frame.top - whole.top, frame.right - whole.left, frame.bottom - whole.top});
    SelectObject(dc, old);
    DeleteObject(bitmap);
    DeleteDC(dc);
    ReleaseDC(nullptr, screen);
    return t;
}

}  // namespace

std::string screenName(HMONITOR monitor) {
    MONITORINFOEXW info{};
    info.cbSize = sizeof info;
    if (!GetMonitorInfoW(monitor, &info)) return "Screen";
    std::wstring name = friendlyName(info.szDevice);
    if (!name.empty()) return utf8(name);
    const auto all = monitors();
    const auto at = std::find(all.begin(), all.end(), monitor);
    return "Screen " + std::to_string(at == all.end() ? 1 : (at - all.begin()) + 1);
}

std::string windowName(HWND window) {
    const std::wstring app = appName(window), title = titleOf(window);
    if (app.empty() || title == app || title.find(app) != std::wstring::npos) return utf8(title);
    return utf8(app) + ": " + utf8(title);
}

nlohmann::json screens() {
    auto list = nlohmann::json::array();
    for (HMONITOR monitor : monitors()) {
        MONITORINFOEXW info{};
        info.cbSize = sizeof info;
        if (!GetMonitorInfoW(monitor, &info)) continue;
        list.push_back({{"id", utf8(info.szDevice)},
                        {"name", screenName(monitor)},
                        {"width", info.rcMonitor.right - info.rcMonitor.left},
                        {"height", info.rcMonitor.bottom - info.rcMonitor.top},
                        {"primary", (info.dwFlags & MONITORINFOF_PRIMARY) != 0}});
    }
    return list;
}

HMONITOR monitorById(const std::string& id) {
    for (HMONITOR monitor : monitors()) {
        MONITORINFOEXW info{};
        info.cbSize = sizeof info;
        if (GetMonitorInfoW(monitor, &info) && utf8(info.szDevice) == id) return monitor;
    }
    return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}

nlohmann::json shareChoices() {
    nlohmann::json screensOut = nlohmann::json::array(), windowsOut = nlohmann::json::array();
    for (HMONITOR monitor : monitors()) {
        MONITORINFOEXW info{};
        info.cbSize = sizeof info;
        if (!GetMonitorInfoW(monitor, &info)) continue;
        const RECT r = info.rcMonitor;
        Thumb t = screenThumb(r);
        screensOut.push_back({{"kind", "screen"},
                              {"id", utf8(info.szDevice)},
                              {"name", screenName(monitor)},
                              {"detail", std::to_string(r.right - r.left) + " × " + std::to_string(r.bottom - r.top)},
                              {"primary", (info.dwFlags & MONITORINFOF_PRIMARY) != 0},
                              {"width", t.w},
                              {"height", t.h},
                              {"jpeg", jpegBase64(t.bgra, t.w, t.h)}});
    }
    for (HWND window : shareableWindows()) {
        Thumb t = windowThumb(window);
        const std::wstring title = titleOf(window);
        std::wstring app = appName(window);
        if (app.empty()) app = title;
        windowsOut.push_back({{"kind", "window"},
                              {"id", std::to_string(reinterpret_cast<uintptr_t>(window))},
                              {"name", utf8(title)},
                              {"detail", utf8(app)},
                              {"label", windowName(window)},
                              {"width", t.w},
                              {"height", t.h},
                              {"jpeg", jpegBase64(t.bgra, t.w, t.h)}});
    }
    std::stable_sort(windowsOut.begin(), windowsOut.end(), [](const nlohmann::json& a, const nlohmann::json& b) {
        return a["detail"].get<std::string>() < b["detail"].get<std::string>();
    });
    return {{"type", "share-choices"}, {"screens", screensOut}, {"windows", windowsOut}};
}

}  // namespace app
