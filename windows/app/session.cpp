#include "session.h"

#include "devices.h"
#include "transcript.h"

#include <mfapi.h>
#include <shlobj.h>
#include <wincodec.h>

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

std::string base64(const BYTE* data, size_t size) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((size + 2) / 3 * 4);
    for (size_t i = 0; i < size; i += 3) {
        const UINT32 n = (UINT32(data[i]) << 16) | (i + 1 < size ? UINT32(data[i + 1]) << 8 : 0) | (i + 2 < size ? data[i + 2] : 0);
        out += table[(n >> 18) & 63];
        out += table[(n >> 12) & 63];
        out += i + 1 < size ? table[(n >> 6) & 63] : '=';
        out += i + 2 < size ? table[n & 63] : '=';
    }
    return out;
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

std::string jpeg(const std::vector<BYTE>& bgra, UINT32 w, UINT32 h) {
    static thread_local ComPtr<IWICImagingFactory> factory;
    if (!factory && FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return {};
    ComPtr<IWICBitmap> bitmap;
    if (FAILED(factory->CreateBitmapFromMemory(w, h, GUID_WICPixelFormat32bppBGRA, w * 4, static_cast<UINT>(bgra.size()),
                                               const_cast<BYTE*>(bgra.data()), &bitmap))) return {};
    ComPtr<IStream> stream;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
    ComPtr<IWICBitmapEncoder> encoder;
    if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder))) return {};
    encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> options;
    if (FAILED(encoder->CreateNewFrame(&frame, &options))) return {};
    PROPBAG2 quality{};
    quality.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = 0.72f;
    options->Write(1, &quality, &value);
    frame->Initialize(options.Get());
    frame->SetSize(w, h);
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    frame->SetPixelFormat(&format);
    if (FAILED(frame->WriteSource(bitmap.Get(), nullptr)) || FAILED(frame->Commit()) || FAILED(encoder->Commit())) return {};
    STATSTG stat{};
    stream->Stat(&stat, STATFLAG_NONAME);
    HGLOBAL memory = nullptr;
    GetHGlobalFromStream(stream.Get(), &memory);
    const BYTE* bytes = static_cast<const BYTE*>(GlobalLock(memory));
    std::string out = base64(bytes, static_cast<size_t>(stat.cbSize.QuadPart));
    GlobalUnlock(memory);
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

Session::Session(Post post) : post_(std::move(post)) {}

Session::~Session() {
    if (recording_) stop();
    if (finisher_.joinable()) finisher_.join();
    camera_.reset();
    mic_.reset();
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
        take->log->write({{"type", "show"}, {"what", "me"}}, started);
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
}

void Session::onFrame(IMFSample* sample, LONGLONG time) {
    sendPreview(sample);
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
}

void Session::sendPreview(IMFSample* sample) {
    // About 15 pictures a second is plenty for the panel.
    if (!previewReady_) return;
    const LONGLONG now = MFGetSystemTime();
    if (now - lastPreview_ < second / 15) return;
    lastPreview_ = now;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return;
    ComPtr<IMF2DBuffer> flat;
    BYTE* data = nullptr;
    LONG pitch = 0;
    DWORD length = 0;
    const bool twoD = SUCCEEDED(buffer.As(&flat)) && SUCCEEDED(flat->Lock2D(&data, &pitch));
    if (!twoD) {
        if (FAILED(buffer->Lock(&data, nullptr, &length))) return;
    }
    const auto f = format_;
    if (!twoD) pitch = static_cast<LONG>(f.width);
    const UINT32 outW = 640, outH = std::max<UINT32>(2, 640 * f.height / std::max<UINT32>(1, f.width)) & ~1u;
    auto bgra = smallBGRA(data, pitch, f.width, f.height, outW, outH);
    if (twoD) {
        flat->Unlock2D();
    } else {
        buffer->Unlock();
    }
    std::string picture = jpeg(bgra, outW, outH);
    if (!picture.empty()) post_({{"type", "preview"}, {"jpeg", picture}});
}

void Session::tick() {
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
    std::unique_ptr<Take> take;
    {
        std::lock_guard lock(takeMutex_);
        if (!recording_) return;
        recording_ = false;
        take = std::move(take_);
    }
    // Extra mics stop first, outside the lock their own callbacks take.
    for (auto& extra : take->extras) extra->mic.reset();
    take->log->write({{"type", "stop"}});
    try {
        take->camera->finish();
        for (auto& extra : take->extras) extra->writer->finish();
    } catch (const std::exception& error) {
        take->log->write({{"type", "camera-error"}, {"file", "camera.mov"}, {"message", error.what()}});
    }
    const fs::path folder = take->folder;
    take.reset();
    post_({{"type", "stopped"}, {"folder", vl::utf8(folder)}});
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
