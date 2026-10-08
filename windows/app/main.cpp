// Vidlark for Windows. The panel, drawn in WebView2 from the files in ui/, talking to this C++ side
// through web messages; while the screen is shared, a small recording box instead (ui/box.html). Both are
// kept out of the screen recording, as the Mac keeps its windows out. Recording itself (camera, mics,
// screen, sound) is done here in C++.

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
#include <functional>
#include <memory>
#include <string>
#include <thread>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

constexpr wchar_t windowClass[] = L"VidlarkWindow";
constexpr wchar_t boxClass[] = L"VidlarkBox";
constexpr wchar_t uiHost[] = L"app.vidlark.local";
constexpr COLORREF graphite = RGB(0x0E, 0x11, 0x10);

constexpr UINT postMessageId = WM_APP + 1;  // a message for the panel, from any thread
constexpr UINT runMessageId = WM_APP + 2;   // work for the window thread, from any thread
constexpr UINT_PTR tickTimer = 1;

HWND window = nullptr;
ComPtr<ICoreWebView2Environment> environment;
ComPtr<ICoreWebView2Controller> controller;
ComPtr<ICoreWebView2> webview;
std::unique_ptr<app::Session> session;

// The recording box, while the screen is shared.
HWND box = nullptr;
ComPtr<ICoreWebView2Controller> boxController;
ComPtr<ICoreWebView2> boxView;
// The app she was using last, so a click in the box can hand the keyboard straight back to it.
HWND lastOtherWindow = nullptr;

// The panel can only be told things on the window's own thread, so other threads hand messages over.
void post(nlohmann::json message) {
    auto* text = new std::string(message.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace));
    if (!window || !PostMessageW(window, postMessageId, 0, reinterpret_cast<LPARAM>(text))) delete text;
}

void runOnWindowThread(std::function<void()> work) {
    auto* job = new std::function<void()>(std::move(work));
    if (!window || !PostMessageW(window, runMessageId, 0, reinterpret_cast<LPARAM>(job))) delete job;
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

void received(const nlohmann::json& message, bool fromBox);

void send(const nlohmann::json& message) {
    const std::wstring text = app::wide(message.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace));
    if (webview) webview->PostWebMessageAsJson(text.c_str());
    if (boxView) boxView->PostWebMessageAsJson(text.c_str());
}

void fitBox() {
    if (!boxController) return;
    RECT bounds;
    GetClientRect(box, &bounds);
    boxController->put_Bounds(bounds);
}

void closeBox() {
    if (boxController) boxController->Close();
    boxController = nullptr;
    boxView = nullptr;
    if (box) DestroyWindow(box);
    box = nullptr;
}

void showPanel() {
    ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
}

// The recording box: top right of the shared screen, over everything, kept out of the video.
void openBox(const nlohmann::json& work) {
    if (box || !environment) return;
    RECT area{0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
    if (work.is_array() && work.size() == 4) area = RECT{work[0].get<LONG>(), work[1].get<LONG>(), work[2].get<LONG>(), work[3].get<LONG>()};
    const UINT dpi = std::max<UINT>(96, GetDpiForWindow(window));
    const int w = MulDiv(300, dpi, 96), h = MulDiv(156, dpi, 96), margin = MulDiv(12, dpi, 96);
    box = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, boxClass, L"Vidlark recording", WS_POPUP | WS_CLIPCHILDREN,
                          area.right - w - margin, area.top + margin, w, h, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!box) return;
    SetWindowDisplayAffinity(box, WDA_EXCLUDEFROMCAPTURE);
    const DWORD round = 2;  // DWMWCP_ROUND: Windows 11's rounded corners
    DwmSetWindowAttribute(box, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &round, sizeof round);
    BOOL dark = TRUE;
    DwmSetWindowAttribute(box, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
    ShowWindow(box, SW_SHOWNOACTIVATE);
    const fs::path ui = exeDir() / L"ui";
    environment->CreateCoreWebView2Controller(
        box, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>([ui](HRESULT result, ICoreWebView2Controller* created) -> HRESULT {
                 if (FAILED(result) || !created || !box) return S_OK;
                 boxController = created;
                 boxController->get_CoreWebView2(&boxView);
                 ComPtr<ICoreWebView2Controller2> controller2;
                 if (SUCCEEDED(boxController.As(&controller2))) controller2->put_DefaultBackgroundColor({255, 0x0E, 0x11, 0x10});
                 ComPtr<ICoreWebView2Settings> settings;
                 boxView->get_Settings(&settings);
                 settings->put_IsStatusBarEnabled(FALSE);
                 settings->put_IsZoomControlEnabled(FALSE);
                 settings->put_AreDefaultContextMenusEnabled(FALSE);
                 // The box is dragged by its background (CSS app-region).
                 ComPtr<ICoreWebView2Settings9> settings9;
                 if (SUCCEEDED(settings.As(&settings9))) settings9->put_IsNonClientRegionSupportEnabled(TRUE);
                 ComPtr<ICoreWebView2_3> view3;
                 if (SUCCEEDED(boxView.As(&view3))) {
                     view3->SetVirtualHostNameToFolderMapping(uiHost, ui.c_str(), COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS);
                 }
                 EventRegistrationToken token;
                 boxView->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                                     [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                                         LPWSTR json = nullptr;
                                                         if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
                                                             auto message = nlohmann::json::parse(app::utf8(json), nullptr, false);
                                                             CoTaskMemFree(json);
                                                             if (message.is_object()) received(message, true);
                                                         }
                                                         return S_OK;
                                                     })
                                                     .Get(),
                                                 &token);
                 fitBox();
                 boxView->Navigate((std::wstring(L"https://") + uiHost + L"/box.html").c_str());
                 return S_OK;
             }).Get());
}

// Everything the panel and the box ask for arrives here as {"type": "...", ...}.
void received(const nlohmann::json& message, bool fromBox) {
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
    } else if (type == "share-choices") {
        // Drawing every window takes a moment, so it is done away from the window thread.
        std::thread([] {
            CoInitializeEx(nullptr, COINIT_MULTITHREADED);
            post(app::shareChoices());
            CoUninitialize();
        }).detach();
    } else if (type == "share" && session) {
        session->shareScreen(message.value("target", nlohmann::json::object()), message.value("sound", false));
    } else if (type == "show" && session) {
        session->show(message.value("what", "") == "screen");
    } else if (type == "sound" && session) {
        session->setSound(message.value("on", false));
    } else if (type == "bubble" && session) {
        session->setBubble(message.value("on", true));
    } else if (type == "take" && session) {
        send(session->takeState());
    } else if (type == "back") {
        showPanel();
        return;
    }
    // A click in the box hands the keyboard straight back to the app she was using.
    if (fromBox && box && GetForegroundWindow() == box && lastOtherWindow && IsWindow(lastOtherWindow)) SetForegroundWindow(lastOtherWindow);
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
            [ui](HRESULT envResult, ICoreWebView2Environment* created) -> HRESULT {
                if (FAILED(envResult) || !created) return envResult;
                environment = created;
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
                                                    if (message.is_object()) received(message, false);
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
        // Sharing the screen swaps the panel for the small recording box, and the end of it swaps back.
        const auto message = nlohmann::json::parse(*text, nullptr, false);
        const std::string type = message.is_object() ? message.value("type", "") : "";
        if (type == "sharing") {
            openBox(message.value("work", nlohmann::json()));
            ShowWindow(window, SW_MINIMIZE);
        } else if (type == "share-failed" || type == "stopped") {
            closeBox();
            if (IsIconic(window)) showPanel();
        }
        const std::wstring wide = app::wide(*text);
        if (webview) webview->PostWebMessageAsJson(wide.c_str());
        if (boxView) boxView->PostWebMessageAsJson(wide.c_str());
        return 0;
    }
    case runMessageId: {
        std::unique_ptr<std::function<void()>> job(reinterpret_cast<std::function<void()>*>(lParam));
        (*job)();
        return 0;
    }
    case WM_TIMER:
        if (wParam == tickTimer) {
            HWND front = GetForegroundWindow();
            DWORD pid = 0;
            GetWindowThreadProcessId(front, &pid);
            if (front && pid != GetCurrentProcessId()) lastOtherWindow = front;
            if (session) session->tick();
        }
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
        closeBox();
        session.reset();
        controller = nullptr;
        webview = nullptr;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

LRESULT CALLBACK boxProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_SIZE:
        fitBox();
        return 0;
    case WM_DPICHANGED: {
        const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    case WM_CLOSE:
        return 0;  // the take is stopped with Stop
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
    WNDCLASSEXW boxWc = wc;
    boxWc.lpfnWndProc = boxProc;
    boxWc.lpszClassName = boxClass;
    RegisterClassExW(&boxWc);

    // A window two thirds of the screen, centred, like the Mac panel's first open.
    const int screenW = GetSystemMetrics(SM_CXSCREEN), screenH = GetSystemMetrics(SM_CYSCREEN);
    const int w = std::max(960, screenW * 2 / 3), h = std::max(620, screenH * 2 / 3);
    window = CreateWindowExW(0, windowClass, L"Vidlark", WS_OVERLAPPEDWINDOW, (screenW - w) / 2, (screenH - h) / 2, w, h,
                             nullptr, nullptr, instance, nullptr);
    BOOL dark = TRUE;
    DwmSetWindowAttribute(window, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof dark);
    // Vidlark's own windows are never in the screen recording; only the stage and the face bubble are.
    SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
    session = std::make_unique<app::Session>(post, runOnWindowThread);
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
