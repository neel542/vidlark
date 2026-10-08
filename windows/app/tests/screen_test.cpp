// vidlark-screen-test <out> <seconds> [--pattern] [--crash-after <seconds>]
// Records the main screen into a screen.mov with capture::ScreenRecorder, the way the app does, so CI can
// check the file on a Windows machine with no camera or mic:
//   - the stage and face bubble windows (app::Overlay) show a made-up camera picture: plain green with a
//     white stripe moving across. For the first 1.5 seconds the stage fills the screen (Me), then it
//     shrinks into the bubble in the bottom right corner (Screen).
//   - a magenta window kept out of the capture (WDA_EXCLUDEFROMCAPTURE, as Vidlark's own windows are) and
//     a blue window that is not, both top left.
//   - the first sound track gets the same noise bursts as vidlark-writer-test's camera.mov, so the
//     finisher can line the two files up; the second is the computer's sound, if this PC has any. That
//     goes into screen.mov after Stop (ScreenRecorder::mergeSound), as in the app.
// At the end it prints one line of JSON saying what it did, where the windows were and what went wrong.
// --pattern records a test picture instead of the screen. Without it, the test picture is used only when
// Windows.Graphics.Capture cannot run here, and the JSON says why.

#include "../capture/screen.h"
#include "../overlay.h"

#include <mfapi.h>
#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <thread>
#include <vector>

#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

HWND solidWindow(const wchar_t* name, COLORREF colour, RECT r) {
    WNDCLASSEXW wc{sizeof wc};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hbrBackground = CreateSolidBrush(colour);
    wc.lpszClassName = name;
    RegisterClassExW(&wc);
    HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, name, name, WS_POPUP | WS_VISIBLE, r.left, r.top,
                                  r.right - r.left, r.bottom - r.top, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    UpdateWindow(window);
    return window;
}

void pump(double seconds) {
    const auto until = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < until) {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(5);
    }
}

nlohmann::json box(const RECT& r, const RECT& origin) {
    return {r.left - origin.left, r.top - origin.top, r.right - origin.left, r.bottom - origin.top};
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: vidlark-screen-test <out> <seconds> [--pattern] [--crash-after <seconds>]\n");
        return 2;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const std::filesystem::path out = argv[1];
    const double seconds = _wtof(argv[2]);
    bool pattern = false;
    double crashAfter = -1;
    for (int i = 3; i < argc; i++) {
        std::wstring arg = argv[i];
        if (arg == L"--pattern") pattern = true;
        if (arg == L"--crash-after" && i + 1 < argc) crashAfter = _wtof(argv[++i]);
    }

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION);
    nlohmann::json report;

    HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    const RECT screen = info.rcMonitor;
    report["monitor"] = {screen.left, screen.top, screen.right, screen.bottom};

    // Two windows top left: magenta kept out of the capture, blue let in.
    const RECT keptOut{screen.left + 40, screen.top + 40, screen.left + 340, screen.top + 240};
    const RECT plain{screen.left + 40, screen.top + 280, screen.left + 340, screen.top + 430};
    HWND hidden = solidWindow(L"VidlarkKeptOut", RGB(255, 0, 255), keptOut);
    report["keptOutAffinity"] = SetWindowDisplayAffinity(hidden, WDA_EXCLUDEFROMCAPTURE) != FALSE;
    solidWindow(L"VidlarkLetIn", RGB(0, 0, 255), plain);
    report["keptOut"] = box(keptOut, screen);
    report["plain"] = box(plain, screen);

    // The made-up camera: 640 x 360 green (RGB 0, 200, 0 in BT.601 video range), a white stripe moving.
    std::atomic<bool> stopFeeds{false};
    app::Overlay overlay;
    std::thread camera([&] {
        const UINT32 w = 640, h = 360;
        std::vector<BYTE> nv12(static_cast<size_t>(w) * h * 3 / 2);
        for (int n = 0; !stopFeeds; n++) {
            std::fill(nv12.begin(), nv12.begin() + w * h, BYTE(117));
            for (size_t i = w * h; i + 1 < nv12.size(); i += 2) {
                nv12[i] = 70;
                nv12[i + 1] = 54;
            }
            const UINT32 x0 = (n * 6) % (w - 30);
            for (UINT32 y = 0; y < h; y++)
                for (UINT32 x = x0; x < x0 + 30; x++) nv12[y * w + x] = 235;
            overlay.camera(nv12.data(), static_cast<LONG>(w), w, h);
            Sleep(33);
        }
    });

    // Me first: the stage across the whole screen before the recording starts, as in the app.
    overlay.cover(screen, info.rcWork);
    overlay.showMe(false);
    for (int i = 0; i < 100 && !overlay.ready(); i++) pump(0.02);
    report["stageReady"] = overlay.ready();
    // Clicks go through the stage to what is under it.
    const POINT middle{(screen.left + screen.right) / 2, (screen.top + screen.bottom) / 2};
    report["stageClickThrough"] = WindowFromPoint(middle) != overlay.stageWindow();

    std::unique_ptr<capture::ScreenRecorder> recorder;
    capture::ScreenRecorder::Options options;
    options.file = out;
    options.monitor = monitor;
    options.testPattern = pattern;
    std::string why;
    if (!pattern && !capture::ScreenRecorder::supported(&why)) options.testPattern = true;
    try {
        recorder = std::make_unique<capture::ScreenRecorder>(options);
    } catch (const std::exception& error) {
        why = error.what();
        std::fprintf(stderr, "recording the screen failed: %s\n", error.what());
        if (options.testPattern) {
            std::fprintf(stderr, "%s\n", error.what());
            return 1;
        }
        options.testPattern = true;
        try {
            recorder = std::make_unique<capture::ScreenRecorder>(options);
        } catch (const std::exception& again) {
            std::fprintf(stderr, "%s\n", again.what());
            return 1;
        }
    }
    report["capture"] = recorder->kind();
    if (!why.empty()) report["why"] = why;
    report["width"] = recorder->format().width;
    report["height"] = recorder->format().height;
    report["hearsComputer"] = recorder->hearsComputer();

    // The mic: vidlark-writer-test's noise bursts, in 10 ms packets timed on the PC's clock.
    const LONGLONG soundStart = recorder->startTime();
    std::thread mic([&] {
        std::mt19937 pattern(7), noise(11);
        std::uniform_real_distribution<double> unit(0, 1);
        double burstStart = 0.2, burstEnd = 0.2 + 0.05 + unit(pattern) * 0.35;
        const UINT32 chunk = 480;
        std::vector<int16_t> sound(chunk);
        long long written = 0;
        while (!stopFeeds) {
            const LONGLONG due = soundStart + written * 10'000'000 / 48000;
            const LONGLONG now = MFGetSystemTime();
            if (due > now) {
                Sleep(static_cast<DWORD>((due - now) / 10'000));
                continue;
            }
            for (UINT32 i = 0; i < chunk; i++) {
                const double t = double(written + i) / 48000;
                while (t > burstEnd) {
                    burstStart = burstEnd + 0.1 + unit(pattern) * 0.8;
                    burstEnd = burstStart + 0.05 + unit(pattern) * 0.35;
                }
                const double level = t >= burstStart ? 0.6 : 0.02;
                sound[i] = static_cast<int16_t>((unit(noise) * 2 - 1) * level * 32000);
            }
            recorder->addMic(sound.data(), chunk, due);
            written += chunk;
        }
    });

    // Me for 1.5 seconds, then Screen: the camera shrinks into the bubble.
    const auto started = std::chrono::steady_clock::now();
    auto elapsed = [&] { return std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count(); };
    bool shrunk = false;
    while (elapsed() < seconds) {
        if (!shrunk && elapsed() >= 1.5) {
            overlay.showScreen(true);
            shrunk = true;
        }
        if (crashAfter >= 0 && elapsed() >= crashAfter) {
            std::fprintf(stderr, "crashing at %.2f s\n", elapsed());
            std::fflush(stderr);
            TerminateProcess(GetCurrentProcess(), 3);
        }
        pump(0.01);
    }
    report["bubble"] = box(overlay.bubbleRect(), screen);
    report["bubbleShown"] = IsWindowVisible(overlay.bubbleWindow()) != FALSE;
    recorder->stop();
    stopFeeds = true;
    mic.join();
    camera.join();
    std::string mergeProblem;
    report["merged"] = capture::ScreenRecorder::mergeSound(out, &mergeProblem);
    report["mergeProblem"] = mergeProblem;
    report["pictures"] = recorder->pictures();
    report["newPictures"] = recorder->newPictures();
    report["convertMs"] = recorder->convertMs();
    report["problem"] = recorder->problem();
    report["overlayProblem"] = overlay.problem();
    overlay.hide();
    pump(0.1);
    std::printf("%s\n", report.dump().c_str());
    std::fflush(stdout);
    recorder.reset();
    MFShutdown();
    return 0;
}
