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
BOOL CALLBACK addScreen(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
    auto* list = reinterpret_cast<nlohmann::json*>(data);
    MONITORINFOEXW info{};
    info.cbSize = sizeof info;
    if (GetMonitorInfoW(monitor, &info)) {
        DEVMODEW mode{};
        mode.dmSize = sizeof mode;
        int width = info.rcMonitor.right - info.rcMonitor.left;
        int height = info.rcMonitor.bottom - info.rcMonitor.top;
        // The real pixels, not the scaled size the window sees.
        if (EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode)) {
            width = static_cast<int>(mode.dmPelsWidth);
            height = static_cast<int>(mode.dmPelsHeight);
        }
        list->push_back({{"name", "Screen " + std::to_string(list->size() + 1)},
                         {"width", width},
                         {"height", height},
                         {"primary", (info.dwFlags & MONITORINFOF_PRIMARY) != 0}});
    }
    return TRUE;
}
}  // namespace

nlohmann::json screens() {
    auto list = nlohmann::json::array();
    EnumDisplayMonitors(nullptr, nullptr, addScreen, reinterpret_cast<LPARAM>(&list));
    return list;
}

}  // namespace app
