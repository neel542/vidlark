#include "session.h"

#include "devices.h"
#include "picture.h"
#include "transcript.h"

#include <dwmapi.h>
#include <mfapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cmath>
#include <cstdio>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace app {

namespace {

constexpr LONGLONG second = 10'000'000;

fs::path exeDir() {
    std::wstring buffer(32768, L'\0');
    buffer.resize(GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size())));
    return fs::path(buffer).parent_path();
}

// A small BGRA copy of an NV12 picture, for the panel's preview.
std::vector<BYTE> smallBGRA(const BYTE* nv12, LONG pitch, UINT32 w, UINT32 h, UINT32 outW, UINT32 outH) {
    std::vector<BYTE> out(static_cast<size_t>(outW) * outH * 4);
    const BYTE* uv = nv12 + static_cast<size_t>(pitch) * h;
    auto clip = [](int v) { return static_cast<BYTE>(v < 0 ? 0 : v > 255 ? 255 : v); };
    for (UINT32 y = 0; y < outH; y++) {
        const UINT32 sy = y * h / outH;
        for (UINT32 x = 0; x < outW; x++) {
            const UINT32 sx = x * w / outW;
            const int c = nv12[sy * pitch + sx] - 16;
            const int d = uv[(sy / 2) * pitch + (sx & ~1u)] - 128;
            const int e = uv[(sy / 2) * pitch + (sx & ~1u) + 1] - 128;
            BYTE* p = &out[(static_cast<size_t>(y) * outW + x) * 4];
            p[0] = clip((298 * c + 516 * d + 128) >> 8);
            p[1] = clip((298 * c - 100 * d - 208 * e + 128) >> 8);
            p[2] = clip((298 * c + 409 * e + 128) >> 8);
            p[3] = 255;
        }
    }
    return out;
}

}  // namespace

fs::path recordingsRoot() {
    PWSTR raw = nullptr;
    fs::path root = L"C:\\Users\\Public\\Videos";
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_PublicVideos, 0, nullptr, &raw))) root = raw;
    CoTaskMemFree(raw);
    return root / L"Vidlark Recordings";
}

// One take while it records: its folder, log and files, and where the sound has got to.
struct Session::Take {
    fs::path folder;
    std::unique_ptr<vl::EventLog> log;
    std::unique_ptr<capture::MovieWriter> camera;
    LONGLONG t0 = 0;              // the PC's clock when the take started
    long long soundWritten = 0;   // main mic samples in camera.mov so far
    bool sawPicture = false;
    // The screen, once it is shared.
    std::unique_ptr<capture::ScreenRecorder> screen;
    bool sharing = false;               // from Share until the screen records, or fails to
    bool showingScreen = false;         // Me (false) or Screen (true)
    bool computerSound = false;
    HWND sharedWindow = nullptr;        // one window, followed as it moves; none for a whole screen
    RECT work{};                        // that screen without the taskbar
    ULONGLONG screenAt = 0;             // when Screen follows the first moment of Me after sharing
    ULONGLONG lastFollow = 0;
    struct Extra {
        std::unique_ptr<capture::Mic> mic;
        std::unique_ptr<capture::MovieWriter> writer;
        std::string file, name;
        long long written = 0;
        bool started = false;
    };
    std::vector<std::unique_ptr<Extra>> extras;
};

namespace {
// The main mic and each extra mic are one channel at 48 kHz.
void placeSound(capture::MovieWriter& writer, long long& written, const int16_t* samples, UINT32 frames, LONGLONG time, LONGLONG t0) {
    capture::placeSound(writer, 0, written, samples, frames, 1, time, t0, capture::Mic::rate);
}
}  // namespace

Session::Session(Post post, RunOnWindowThread onWindowThread)
    : post_(std::move(post)), onWindowThread_(std::move(onWindowThread)), overlay_(std::make_unique<Overlay>()) {}

Session::~Session() {
    if (recording_) stop();
    if (sharer_.joinable()) sharer_.join();
    if (finisher_.joinable()) finisher_.join();
    camera_.reset();
    mic_.reset();
    overlay_.reset();
}

void Session::open(const std::string& cameraId, const std::string& micId) {
    if (recording_) return;
    previewReady_ = false;
    camera_.reset();
    mic_.reset();
    cameraName_.clear();
    micName_.clear();
    const auto cameraList = cameras();
    const auto micList = microphones();
    nlohmann::json problems = nlohmann::json::array();
    for (const auto& camera : cameraList) {
        if (!cameraId.empty() && camera["id"] != cameraId) continue;
        try {
            camera_ = std::make_unique<capture::Camera>(wide(camera["id"].get<std::string>()), capture::VideoFormat{1920, 1080, 30, 0},
                                                        [this](IMFSample* s, LONGLONG t) { onFrame(s, t); });
            cameraName_ = camera["name"].get<std::string>();
            format_ = camera_->format();
            previewReady_ = true;
        } catch (const std::exception& error) {
            problems.push_back(camera["name"].get<std::string>() + ": " + error.what());
        }
        break;
    }
    for (const auto& mic : micList) {
        const bool wanted = micId.empty() ? mic.value("default", false) : mic["id"] == micId;
        if (!wanted) continue;
        try {
            mic_ = std::make_unique<capture::Mic>(wide(mic["id"].get<std::string>()), false,
                                                  [this](const int16_t* s, UINT32 n, LONGLONG t, bool q) { onSound(s, n, t, q); });
            micName_ = mic["name"].get<std::string>();
        } catch (const std::exception& error) {
            problems.push_back(mic["name"].get<std::string>() + ": " + error.what());
        }
        break;
    }
    nlohmann::json opened = {{"type", "opened"}, {"camera", cameraName_}, {"microphone", micName_}, {"problems", problems}};
    if (camera_) {
        const auto& f = camera_->format();
        opened["size"] = std::to_string(f.width) + " x " + std::to_string(f.height) + ", " + std::to_string(f.fps) + " fps";
    }
    post_(opened);
}

void Session::record(const std::optional<std::string>& title, const std::vector<std::string>& extraMicIds) {
    if (recording_) return;
    if (!camera_ || !mic_) {
        post_({{"type", "problem"}, {"message", !camera_ ? "No camera is open, so there is nothing to record." : "No microphone is open."}});
        return;
    }
    if (finisher_.joinable()) finisher_.join();
    auto take = std::make_unique<Take>();
    try {
        std::optional<fs::path> videoFolder;
        take->folder = vl::newRecordingFolder(recordingsRoot(), videoFolder, title);
        const auto started = vl::EventLog::Clock::now();
        take->t0 = MFGetSystemTime();
        take->log = std::make_unique<vl::EventLog>(take->folder / L"events.jsonl", started);
        take->camera = std::make_unique<capture::MovieWriter>(take->folder / L"camera.mov", camera_->format(),
                                                              capture::AudioFormat{capture::Mic::rate, 1, 192000});
        // Extra mics, each to its own file.
        auto mics = microphones();
        int n = 2;
        for (const auto& id : extraMicIds) {
            auto found = std::find_if(mics.begin(), mics.end(), [&](const auto& m) { return m["id"] == id; });
            if (found == mics.end()) continue;
            auto extra = std::make_unique<Take::Extra>();
            extra->file = "mic-" + std::to_string(n) + ".m4a";
            extra->name = (*found)["name"].get<std::string>();
            extra->writer = std::make_unique<capture::MovieWriter>(take->folder / vl::pathFromUtf8(extra->file), std::nullopt,
                                                                   capture::AudioFormat{capture::Mic::rate, 1, 192000});
            Take::Extra* raw = extra.get();
            Take* takeRaw = take.get();
            extra->mic = std::make_unique<capture::Mic>(wide(id), false, [this, raw, takeRaw](const int16_t* s, UINT32 frames, LONGLONG t, bool) {
                std::lock_guard lock(takeMutex_);
                if (!recording_ || !raw->writer) return;
                if (!raw->started) {
                    raw->started = true;
                    takeRaw->log->write({{"type", "mic-start"}, {"file", raw->file},
                                         {"at", std::round(std::max(0.0, double(t - takeRaw->t0) / second) * 1000) / 1000}});
                }
                try {
                    placeSound(*raw->writer, raw->written, s, frames, t, takeRaw->t0);
                } catch (...) {
                }
            });
            take->extras.push_back(std::move(extra));
            n++;
        }

        nlohmann::json extraMics = nlohmann::json::array();
        for (const auto& extra : take->extras) extraMics.push_back({{"file", extra->file}, {"name", extra->name}, {"connection", "Windows"}});
        take->log->write({{"type", "start"}, {"wall", vl::wallClock()}, {"title", title.value_or("Untitled")}, {"camera", "camera.mov"},
                          {"screen", ""}, {"cameraName", cameraName_}, {"micName", micName_}, {"screenName", ""},
                          {"extraCameras", nlohmann::json::array()}, {"extraMics", extraMics}, {"videoMic", ""},
                          {"computer", "Windows"}, {"cameraClock", camera_->clockSource()}},
                         started);
        take->log->write({{"type", "show"}, {"what", "camera"}}, started);
    } catch (const std::exception& error) {
        post_({{"type", "problem"}, {"message", std::string("The take could not start: ") + error.what()}});
        return;
    }
    lastTake_ = take->folder;
    {
        std::lock_guard lock(takeMutex_);
        take_ = std::move(take);
        recording_ = true;
    }
    post_({{"type", "recording"}, {"folder", vl::utf8(lastTake_)}});
    post_(takeState());
}

void Session::onFrame(IMFSample* sample, LONGLONG time) {
    // The panel's preview, about 15 pictures a second, and the stage and bubble while they show her.
    const LONGLONG now = MFGetSystemTime();
    const bool preview = previewReady_ && now - lastPreview_ >= second / 15 && !sharingScreen_;
    const bool stage = overlay_->wantsCamera();
    if (previewReady_ && (preview || stage)) {
        ComPtr<IMFMediaBuffer> buffer;
        if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
            ComPtr<IMF2DBuffer> flat;
            BYTE* data = nullptr;
            LONG pitch = 0;
            DWORD length = 0;
            const bool twoD = SUCCEEDED(buffer.As(&flat)) && SUCCEEDED(flat->Lock2D(&data, &pitch));
            const bool locked = twoD || SUCCEEDED(buffer->Lock(&data, nullptr, &length));
            if (locked) {
                if (!twoD) pitch = static_cast<LONG>(format_.width);
                if (stage) overlay_->camera(data, pitch, format_.width, format_.height);
                if (preview) {
                    lastPreview_ = now;
                    sendPreview(data, pitch);
                }
                if (twoD) {
                    flat->Unlock2D();
                } else {
                    buffer->Unlock();
                }
            }
        }
    }
    std::lock_guard lock(takeMutex_);
    if (!recording_ || !take_ || !take_->camera) return;
    const LONGLONG at = time - take_->t0;
    if (at < 0) return;
    sample->SetSampleTime(at);
    sample->SetSampleDuration(second / std::max<UINT32>(1, take_->camera->video().fps));
    try {
        take_->camera->writeVideo(sample);
        take_->sawPicture = true;
    } catch (const std::exception& error) {
        take_->log->write({{"type", "camera-error"}, {"file", "camera.mov"}, {"message", error.what()}});
    }
}

void Session::onSound(const int16_t* samples, UINT32 frames, LONGLONG time, bool) {
    std::lock_guard lock(takeMutex_);
    if (!recording_ || !take_ || !take_->camera) return;
    try {
        placeSound(*take_->camera, take_->soundWritten, samples, frames, time, take_->t0);
    } catch (...) {
    }
    // The same mic goes into screen.mov's first sound track: that is how the two files line up.
    if (take_->screen) take_->screen->addMic(samples, frames, time);
}

void Session::sendPreview(const BYTE* data, LONG pitch) {
    const auto f = format_;
    const UINT32 outW = 640, outH = std::max<UINT32>(2, 640 * f.height / std::max<UINT32>(1, f.width)) & ~1u;
    auto bgra = smallBGRA(data, pitch, f.width, f.height, outW, outH);
    std::string picture = jpegBase64(bgra, outW, outH);
    if (!picture.empty()) post_({{"type", "preview"}, {"jpeg", picture}});
}

nlohmann::json Session::takeState() {
    nlohmann::json state = {{"type", "take"}, {"recording", recording_.load()}, {"bubble", bubbleOn_}};
    std::lock_guard lock(takeMutex_);
    if (recording_ && take_) {
        state["sharing"] = take_->sharing;
        state["hasScreen"] = take_->screen != nullptr;
        state["showing"] = take_->showingScreen ? "screen" : "camera";
        state["sound"] = take_->computerSound;
        state["hearsComputer"] = take_->screen ? take_->screen->hearsComputer() : true;
    }
    return state;
}

void Session::shareScreen(const nlohmann::json& target, bool computerSound) {
    Take* take = nullptr;
    {
        std::lock_guard lock(takeMutex_);
        if (!recording_ || !take_ || take_->screen || take_->sharing) return;
        take = take_.get();
    }
    // What to record: a whole screen, or one window cut out of the screen it is on.
    HWND window = nullptr;
    HMONITOR monitor = nullptr;
    std::string name;
    const std::string kind = target.value("kind", "screen"), id = target.value("id", "");
    if (kind == "window") {
        try {
            window = reinterpret_cast<HWND>(static_cast<uintptr_t>(std::stoull(id)));
        } catch (...) {
            window = nullptr;
        }
        if (!window || !IsWindow(window)) {
            post_({{"type", "share-failed"}, {"message", "That window is not open any more. Open it, or share the entire screen."}});
            return;
        }
        if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
        SetForegroundWindow(window);
        monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
        name = windowName(window);
    } else {
        monitor = monitorById(id);
        name = screenName(monitor);
    }
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    RECT area = info.rcMonitor;
    if (window) {
        if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &area, sizeof area))) GetWindowRect(window, &area);
    }
    {
        std::lock_guard lock(takeMutex_);
        take->sharing = true;
        take->computerSound = computerSound;
        take->sharedWindow = window;
        take->work = info.rcWork;
        sharingScreen_ = true;
    }
    post_({{"type", "sharing"}, {"name", name}, {"work", {info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom}}});
    post_(takeState());

    // Her camera across the screen first, so screen.mov opens on her and the finished video can change
    // from camera.mov to it without a jump.
    overlay_->setBubble(bubbleOn_);
    overlay_->cover(area, info.rcWork);
    overlay_->showMe(false);

    if (sharer_.joinable()) sharer_.join();
    sharer_ = std::thread([this, take, monitor, window, name, computerSound] { startScreen(take, monitor, window, name, computerSound); });
}

void Session::startScreen(Take* take, HMONITOR monitor, HWND window, std::string name, bool computerSound) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    // At most a second for the stage to show her camera.
    for (int i = 0; i < 50 && !overlay_->ready(); i++) Sleep(20);
    take->log->write({{"type", "screen-start"}, {"screen", "screen.mov"}, {"screenName", name}, {"macSound", computerSound}});
    std::unique_ptr<capture::ScreenRecorder> recorder;
    std::string problem;
    try {
        capture::ScreenRecorder::Options options;
        options.file = take->folder / L"screen.mov";
        options.monitor = monitor;
        options.window = window;
        options.sound = computerSound;
        recorder = std::make_unique<capture::ScreenRecorder>(options);
    } catch (const std::exception& error) {
        problem = error.what();
    }
    if (recorder) {
        if (!recorder->hearsComputer()) take->log->write({{"type", "screen-error"}, {"message", "sound: " + recorder->problem()}});
        std::lock_guard lock(takeMutex_);
        take->screen = std::move(recorder);
        take->sharing = false;
        take->screenAt = GetTickCount64() + 600;
        take->log->write({{"type", "sound"}, {"on", computerSound}, {"from", "every app"}});
        take->log->write({{"type", "bubble"}, {"visible", bubbleOn_}});
    } else {
        take->log->write({{"type", "screen-error"}, {"message", problem}});
        std::lock_guard lock(takeMutex_);
        take->sharing = false;
        sharingScreen_ = false;
    }
    CoUninitialize();
    if (problem.empty()) {
        post_({{"type", "shared"}, {"name", name}});
    } else {
        onWindowThread_([this] { overlay_->hide(); });
        post_({{"type", "share-failed"}, {"message", "The screen could not be recorded: " + problem}});
    }
    post_(takeState());
}

void Session::show(bool screen) {
    {
        std::lock_guard lock(takeMutex_);
        if (!recording_ || !take_ || !take_->screen || take_->showingScreen == screen) return;
        take_->showingScreen = screen;
        take_->screenAt = 0;
        take_->log->write({{"type", "show"}, {"what", screen ? "screen" : "camera"}});
    }
    if (screen) {
        overlay_->showScreen(true);
    } else {
        overlay_->showMe(true);
    }
    post_(takeState());
}

void Session::setSound(bool on) {
    {
        std::lock_guard lock(takeMutex_);
        if (!recording_ || !take_ || !take_->screen || take_->computerSound == on) return;
        take_->computerSound = on;
        take_->screen->setSound(on);
        take_->log->write({{"type", "sound"}, {"on", on}, {"from", "every app"}});
    }
    post_(takeState());
}

void Session::setBubble(bool on) {
    if (bubbleOn_ == on) return;
    bubbleOn_ = on;
    overlay_->setBubble(on);
    {
        std::lock_guard lock(takeMutex_);
        if (recording_ && take_ && take_->screen) take_->log->write({{"type", "bubble"}, {"visible", on}});
    }
    post_(takeState());
}

void Session::tick() {
    // Sharing has shown her camera across the screen for a moment: now the screen, as the Mac does.
    bool switchToScreen = false;
    HWND follow = nullptr;
    RECT work{};
    {
        std::lock_guard lock(takeMutex_);
        if (recording_ && take_ && take_->screen) {
            const ULONGLONG now = GetTickCount64();
            if (take_->screenAt && now >= take_->screenAt) switchToScreen = true;
            // One shared window: the stage and bubble follow it, twice a second.
            if (take_->sharedWindow && now - take_->lastFollow >= 500) {
                take_->lastFollow = now;
                follow = take_->sharedWindow;
                work = take_->work;
            }
        }
    }
    if (switchToScreen) show(true);
    if (follow) {
        RECT area{};
        {
            std::lock_guard lock(takeMutex_);
            if (take_ && take_->screen) area = take_->screen->area();
        }
        if (!IsRectEmpty(&area)) overlay_->cover(area, work);
    }

    nlohmann::json message = {{"type", "tick"}};
    if (mic_) {
        message["level"] = mic_->levelDb();
        message["peak"] = mic_->peakDb();
    }
    message["cameraOk"] = camera_ && camera_->running();
    if (recording_) {
        std::lock_guard lock(takeMutex_);
        if (take_) message["seconds"] = double(MFGetSystemTime() - take_->t0) / second;
    }
    post_(message);
}

void Session::stop() {
    // A screen still starting finishes starting first, so it is stopped with the rest.
    if (sharer_.joinable()) sharer_.join();
    std::unique_ptr<Take> take;
    {
        std::lock_guard lock(takeMutex_);
        if (!recording_) return;
        recording_ = false;
        sharingScreen_ = false;
        take = std::move(take_);
    }
    // Extra mics stop first, outside the lock their own callbacks take.
    for (auto& extra : take->extras) extra->mic.reset();
    take->log->write({{"type", "stop"}});
    if (take->screen) {
        take->screen->stop();
        if (!take->screen->problem().empty() && take->screen->hearsComputer()) {
            take->log->write({{"type", "screen-error"}, {"message", take->screen->problem()}});
        }
        take->screen.reset();
    }
    overlay_->hide();
    try {
        take->camera->finish();
        for (auto& extra : take->extras) extra->writer->finish();
    } catch (const std::exception& error) {
        take->log->write({{"type", "camera-error"}, {"file", "camera.mov"}, {"message", error.what()}});
    }
    const fs::path folder = take->folder;
    take.reset();
    post_({{"type", "stopped"}, {"folder", vl::utf8(folder)}});
    post_(takeState());
    if (finisher_.joinable()) finisher_.join();
    finisher_ = std::thread([this, folder] { runFinisher(folder); });
}

void Session::runFinisher(fs::path folder) {
    const fs::path tool = exeDir() / L"vidlark-finish.exe";
    std::wstring command = L"\"" + tool.wstring() + L"\" \"" + folder.wstring() + L"\"";
    // Without the speech model there is no transcript to write, so the take finishes without one.
    const bool transcribe = vl::findModel(std::nullopt).path.has_value();
    if (!transcribe) command += L" --no-transcribe";
    SECURITY_ATTRIBUTES inherit{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE readEnd = nullptr, writeEnd = nullptr;
    CreatePipe(&readEnd, &writeEnd, &inherit, 0);
    SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW startup{sizeof startup};
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = writeEnd;
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(tool.c_str(), command.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        CloseHandle(readEnd);
        CloseHandle(writeEnd);
        post_({{"type", "finished"}, {"ok", false}, {"message", "vidlark-finish.exe could not start"}, {"folder", vl::utf8(folder)}});
        return;
    }
    CloseHandle(writeEnd);
    std::string pending, last;
    char buffer[4096];
    DWORD got = 0;
    while (ReadFile(readEnd, buffer, sizeof buffer, &got, nullptr) && got > 0) {
        pending.append(buffer, got);
        for (size_t at; (at = pending.find('\n')) != std::string::npos;) {
            std::string line = vl::trim(pending.substr(0, at));
            pending.erase(0, at + 1);
            if (line.rfind("STEP ", 0) == 0) post_({{"type", "finishing"}, {"line", line.substr(5)}});
            if (!line.empty()) last = line;
        }
    }
    if (!vl::trim(pending).empty()) last = vl::trim(pending);
    WaitForSingleObject(process.hProcess, INFINITE);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    CloseHandle(readEnd);
    const bool ok = last.rfind("DONE", 0) == 0;
    std::string message = ok ? "Every file is ready." : last.rfind("FAIL ", 0) == 0 ? last.substr(5) : last;
    if (ok && !transcribe) message += " There is no transcript yet: the speech model is not downloaded.";
    post_({{"type", "finished"}, {"ok", ok}, {"message", message}, {"folder", vl::utf8(folder)}});
}

}  // namespace app
