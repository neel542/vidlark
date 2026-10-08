// Vidlark for Windows. One window: the panel, drawn in WebView2 from the files in ui/, talking to this
// C++ side through web messages. Recording itself (camera, mics, screen, sound) is done here in C++.

#include "devices.h"
#include "session.h"

#include <windows.h>
#include <dwmapi.h>
#include <mfapi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wrl.h>
#include <WebView2.h>

#include <algorithm>
#include <filesystem>
#include <memory>
#include <string>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

constexpr wchar_t windowClass[] = L"VidlarkWindow";
constexpr wchar_t uiHost[] = L"app.vidlark.local";
constexpr COLORREF graphite = RGB(0x0E, 0x11, 0x10);

constexpr UINT postMessageId = WM_APP + 1;  // a message for the panel, from any thread
constexpr UINT_PTR tickTimer = 1;

HWND window = nullptr;
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;
std::unique_ptr<app::Session> session;

// The panel can only be told things on the window's own thread, so other threads hand messages over.
void post(nlohmann::json message) {
    auto* text = new std::string(message.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace));
    if (!window || !PostMessageW(window, postMessageId, 0, reinterpret_cast<LPARAM>(text))) delete text;
}

fs::path exeDir() {
    std::wstring buffer(32768, L'\0');
    buffer.resize(GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size())));
    return fs::path(buffer).parent_path();
}

fs::path localAppData() {
    PWSTR raw = nullptr;
    fs::path path;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw))) path = raw;
    CoTaskMemFree(raw);
    return path / L"Vidlark";
}

void send(const nlohmann::json& message) {
    if (webview) webview->PostWebMessageAsJson(app::wide(message.dump()).c_str());
}

// Everything the panel asks for arrives here as {"type": "...", ...}.
void received(const nlohmann::json& message) {
    const std::string type = message.value("type", "");
    if (type == "hello" || type == "devices") {
        send({{"type", "devices"},
              {"cameras", app::cameras()},
              {"microphones", app::microphones()},
              {"screens", app::screens()},
              {"recording", session && session->recording()}});
        if (type == "hello" && session && !session->recording()) session->open("", "");
    } else if (type == "open" && session) {
        session->open(message.value("camera", ""), message.value("microphone", ""));
    } else if (type == "record" && session) {
        std::string title = message.value("title", "");
        std::vector<std::string> extras;
        for (const auto& id : message.value("extraMics", nlohmann::json::array())) {
            if (id.is_string()) extras.push_back(id.get<std::string>());
        }
        session->record(title.empty() ? std::nullopt : std::optional<std::string>(title), extras);
    } else if (type == "stop" && session) {
        session->stop();
    } else if (type == "show-take") {
        const std::wstring folder = app::wide(message.value("folder", ""));
        if (!folder.empty()) ShellExecuteW(window, L"open", L"explorer.exe", (L"\"" + folder + L"\"").c_str(), nullptr, SW_SHOWNORMAL);
    }
}

void fitWebView() {
    if (!controller) return;
    RECT bounds;
    GetClientRect(window, &bounds);
    controller->put_Bounds(bounds);
}

void startWebView() {
    const fs::path ui = exeDir() / L"ui";
    const fs::path data = localAppData() / L"WebView2";
    HRESULT result = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, data.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [ui](HRESULT envResult, ICoreWebView2Environment* environment) -> HRESULT {
                if (FAILED(envResult) || !environment) return envResult;
                return environment->CreateCoreWebView2Controller(
                    window, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                                [ui](HRESULT controllerResult, ICoreWebView2Controller* created) -> HRESULT {
                                    if (FAILED(controllerResult) || !created) return controllerResult;
                                    controller = created;
                                    controller->get_CoreWebView2(&webview);

                                    // The graphite body shows at once, before the page has drawn.
                                    ComPtr<ICoreWebView2Controller2> controller2;
                                    if (SUCCEEDED(controller.As(&controller2))) {
                                        controller2->put_DefaultBackgroundColor({255, 0x0E, 0x11, 0x10});
                                    }
                                    ComPtr<ICoreWebView2Settings> settings;
                                    webview->get_Settings(&settings);
                                    settings->put_IsStatusBarEnabled(FALSE);
                                    settings->put_IsZoomControlEnabled(FALSE);
#ifdef NDEBUG
                                    settings->put_AreDefaultContextMenusEnabled(FALSE);
                                    settings->put_AreDevToolsEnabled(FALSE);
#endif
                                    ComPtr<ICoreWebView2_3> webview3;
                                    if (SUCCEEDED(webview.As(&webview3))) {
                                        webview3->SetVirtualHostNameToFolderMapping(
                                            uiHost, ui.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
                                    }
                                    EventRegistrationToken token;
                                    webview->add_WebMessageReceived(
                                        Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                            [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                                LPWSTR json = nullptr;
                                                if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
                                                    auto message = nlohmann::json::parse(app::utf8(json), nullptr, false);
                                                    CoTaskMemFree(json);
                                                    if (message.is_object()) received(message);
                                                }
                                                return S_OK;
                                            })
                                            .Get(),
                                        &token);
                                    fitWebView();
                                    SetTimer(window, tickTimer, 50, nullptr);
                                    webview->Navigate((std::wstring(L"https://") + uiHost + L"/index.html").c_str());
                                    return S_OK;
                                })
                                .Get());
            })
            .Get());
    if (FAILED(result)) {
        MessageBoxW(window,
                    L"Vidlark needs Microsoft Edge WebView2, which comes with Windows 11.\n\n"
                    L"Install the WebView2 Runtime from Microsoft, then open Vidlark again.",
                    L"Vidlark", MB_OK | MB_ICONINFORMATION);
        PostQuitMessage(1);
    }
}

LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_SIZE:
        fitWebView();
        return 0;
    case postMessageId: {
        std::unique_ptr<std::string> text(reinterpret_cast<std::string*>(lParam));
        if (webview) webview->PostWebMessageAsJson(app::wide(*text).c_str());
        return 0;
    }
    case WM_TIMER:
        if (wParam == tickTimer && session) session->tick();
        return 0;
    case WM_CLOSE:
        if (session && session->recording() &&
            MessageBoxW(hwnd, L"A take is recording. Stop it and close Vidlark?", L"Vidlark", MB_YESNO | MB_ICONQUESTION) != IDYES) {
            return 0;
        }
        if (session) session->stop();
        DestroyWindow(hwnd);
        return 0;
    case WM_GETMINMAXINFO: {
        auto* limits = reinterpret_cast<MINMAXINFO*>(lParam);
        UINT dpi = GetDpiForWindow(hwnd);
        limits->ptMinTrackSize = {MulDiv(760, dpi, 96), MulDiv(520, dpi, 96)};
        return 0;
    }
    case WM_DESTROY:
        KillTimer(hwnd, tickTimer);
        session.reset();
        controller = nullptr;
        webview = nullptr;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    MFStartup(MF_VERSION);

    WNDCLASSEXW wc{sizeof wc};
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(1));
    wc.hIconSm = wc.hIcon;
    wc.hbrBackground = CreateSolidBrush(graphite);
    wc.lpszClassName = windowClass;
    RegisterClassExW(&wc);

    // A window two thirds of the screen, centred, like the Mac panel's first open.
    const int screenW = GetSystemMetrics(SM_CXSCREEN), screenH = GetSystemMetrics(SM_CYSCREEN);
    const int w = std::max(960, screenW * 2 / 3), h = std::max(620, screenH * 2 / 3);
    window = CreateWindowExW(0, windowClass, L"Vidlark", WS_OVERLAPPEDWINDOW, (screenW - w) / 2, (screenH - h) / 2, w, h,
                             nullptr, nullptr, instance, nullptr);
    BOOL dark = TRUE;
    DwmSetWindowAttribute(window, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
    session = std::make_unique<app::Session>(post);
    ShowWindow(window, show);
    UpdateWindow(window);
    startWebView();

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    MFShutdown();
    CoUninitialize();
    return static_cast<int>(msg.wParam);
}
