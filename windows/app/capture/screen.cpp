#include "screen.h"

#include <unknwn.h>
#include <inspectable.h>
#include <dwmapi.h>
#include <dxgi.h>
#include <mfapi.h>

#include "support.h"

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>

using Microsoft::WRL::ComPtr;
namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;

namespace capture {

namespace {

constexpr LONGLONG second = 10'000'000;
constexpr LONGLONG frameTime = second / 30;
constexpr UINT32 rate = Mic::rate;

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

std::string plain(const winrt::hresult_error& error) {
    char code[16];
    std::snprintf(code, sizeof code, "0x%08X", static_cast<unsigned>(static_cast<int32_t>(error.code())));
    return winrt::to_string(error.message()) + " (" + code + ")";
}

RECT windowArea(HWND window) {
    RECT r{};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r))) GetWindowRect(window, &r);
    return r;
}

}  // namespace

// Windows.Graphics.Capture's side: the capture item, its frame pool and session, and the newest frame.
struct ScreenRecorder::Capture {
    wgd::Direct3D11::IDirect3DDevice device{nullptr};
    wgc::GraphicsCaptureItem item{nullptr};
    wgc::Direct3D11CaptureFramePool pool{nullptr};
    wgc::GraphicsCaptureSession session{nullptr};
    winrt::event_token arrived{};
    winrt::Windows::Graphics::SizeInt32 poolSize{};
    std::mutex lock;
    wgc::Direct3D11CaptureFrame latest{nullptr};
    ComPtr<ID3D11Texture2D> copy;  // the newest frame, copied out so the frame goes back to the pool at once
    LONGLONG clockShift = 0;
    bool clockChecked = false;

    ~Capture() { close(); }

    void close() {
        try {
            if (pool) pool.FrameArrived(arrived);
            if (session) session.Close();
            if (pool) pool.Close();
            std::lock_guard guard(lock);
            if (latest) latest.Close();
        } catch (...) {
        }
        latest = nullptr;
        session = nullptr;
        pool = nullptr;
    }

    // The newest frame since the last call, or nothing.
    wgc::Direct3D11CaptureFrame take() {
        std::lock_guard guard(lock);
        auto frame = latest;
        latest = nullptr;
        return frame;
    }
};

std::filesystem::path ScreenRecorder::soundFile(const std::filesystem::path& screen) {
    return screen.parent_path() / (screen.stem().wstring() + L"-sound.m4a");
}

bool ScreenRecorder::mergeSound(const std::filesystem::path& screen, std::string* problem) {
    namespace fs = std::filesystem;
    const fs::path sound = soundFile(screen);
    std::error_code ec;
    if (!fs::exists(sound, ec) || !fs::exists(screen, ec)) return true;
    const auto ffmpeg = vl::tools::find("ffmpeg");
    if (!ffmpeg) {
        if (problem) *problem = "ffmpeg is missing, so the computer's sound stays in " + vl::utf8(sound.filename());
        return false;
    }
    const fs::path merged = screen.parent_path() / (screen.stem().wstring() + L"-merging.mov");
    const auto result = vl::runTool(*ffmpeg, {"-nostdin", "-v", "error", "-y", "-i", vl::utf8(screen), "-i", vl::utf8(sound),
                                              "-map", "0:v", "-map", "0:a", "-map", "1:a", "-c", "copy", "-f", "mp4", vl::utf8(merged)});
    if (result.status != 0) {
        fs::remove(merged, ec);
        if (problem) *problem = "the computer's sound could not go into screen.mov: " + result.lastErrorLine();
        return false;
    }
    if (!MoveFileExW(merged.c_str(), screen.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        fs::remove(merged, ec);
        if (problem) *problem = "screen.mov could not be replaced, so the computer's sound stays in " + vl::utf8(sound.filename());
        return false;
    }
    fs::remove(sound, ec);
    return true;
}

bool ScreenRecorder::supported(std::string* why) {
    try {
        if (wgc::GraphicsCaptureSession::IsSupported()) return true;
        if (why) *why = "this version of Windows cannot record the screen (Windows.Graphics.Capture is not supported)";
    } catch (const winrt::hresult_error& error) {
        if (why) *why = "Windows.Graphics.Capture is missing: " + plain(error);
    }
    return false;
}

ScreenRecorder::ScreenRecorder(const Options& options) : options_(options) {
    soundOn_ = options.sound;
    device_ = makeDevice();

    MONITORINFO info{sizeof info};
    if (!options.testPattern) {
        if (!options.monitor || !GetMonitorInfoW(options.monitor, &info)) throw std::runtime_error("the screen to record is not connected");
        monitorRect_ = info.rcMonitor;
    }

    // The part recorded, and so the file's size.
    LONG w = 1280, h = 720;
    if (options.testPattern) {
        kind_ = "test pattern";
        area_ = RECT{0, 0, w, h};
    } else if (options.window) {
        if (!IsWindow(options.window)) throw std::runtime_error("the window to share is not open");
        kind_ = "window";
        area_ = windowArea(options.window);
        w = area_.right - area_.left;
        h = area_.bottom - area_.top;
    } else {
        area_ = monitorRect_;
        w = area_.right - area_.left;
        h = area_.bottom - area_.top;
    }
    UINT outW = 0, outH = 0;
    recordingSize(w, h, outW, outH);
    format_ = VideoFormat{outW, outH, 30, 0};
    converter_ = std::make_unique<Nv12Converter>(device_.Get(), outW, outH);

    if (!options.testPattern) {
        std::string why;
        if (!supported(&why)) throw std::runtime_error(why);
        capture_ = std::make_unique<Capture>();
        try {
            ComPtr<IDXGIDevice> dxgi;
            check(device_.As(&dxgi), "reaching the graphics chip");
            winrt::com_ptr<::IInspectable> inspectable;
            winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.Get(), inspectable.put()));
            capture_->device = inspectable.as<wgd::Direct3D11::IDirect3DDevice>();

            // The whole screen is captured, also for one window: Vidlark's camera windows (the stage and
            // the bubble) sit over the window and belong in the video, and capturing the window alone
            // would leave them out. The window is cut out of the screen's picture instead.
            auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
            winrt::check_hresult(interop->CreateForMonitor(options.monitor, winrt::guid_of<wgc::GraphicsCaptureItem>(),
                                                           winrt::put_abi(capture_->item)));
            capture_->poolSize = capture_->item.Size();
            capture_->pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
                capture_->device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 3, capture_->poolSize);
            Capture* c = capture_.get();
            capture_->arrived = capture_->pool.FrameArrived([c](const wgc::Direct3D11CaptureFramePool& pool, const auto&) {
                auto frame = pool.TryGetNextFrame();
                if (!frame) return;
                std::lock_guard guard(c->lock);
                if (c->latest) c->latest.Close();  // an older one nobody took: back to the pool
                c->latest = frame;
            });
            capture_->session = capture_->pool.CreateCaptureSession(capture_->item);
            using winrt::Windows::Foundation::Metadata::ApiInformation;
            if (ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsCursorCaptureEnabled")) {
                capture_->session.IsCursorCaptureEnabled(true);
            }
            // Windows 11 can leave out the yellow frame it draws round the screen while it is recorded.
            // The frame is never in the recording either way.
            if (ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsBorderRequired")) {
                try {
                    capture_->session.IsBorderRequired(false);
                } catch (...) {
                }
            }
        } catch (const winrt::hresult_error& error) {
            capture_.reset();
            throw std::runtime_error("the screen could not be recorded: " + plain(error));
        }
    } else {
        pattern_.resize(static_cast<size_t>(w) * h * 4);
    }

    // The computer's sound, always listened to, so it can be switched on at any moment.
    try {
        loopback_ = std::make_unique<Mic>(L"", true, [this](const int16_t* s, UINT32 n, LONGLONG t, bool q) { onComputerSound(s, n, t, q); });
    } catch (const std::exception& error) {
        loopback_.reset();
        note(std::string("the computer's sound cannot be recorded on this PC (") + error.what() + "), so its track is silent");
    }

    writer_ = std::make_unique<MovieWriter>(options.file, format_, AudioFormat{rate, 1, 192000});
    soundWriter_ = std::make_unique<MovieWriter>(soundFile(options.file), std::nullopt, AudioFormat{rate, 2, 192000});
    t0_ = MFGetSystemTime();
    lastSoundPacket_ = t0_;
    if (capture_) {
        try {
            capture_->session.StartCapture();
        } catch (const winrt::hresult_error& error) {
            loopback_.reset();
            capture_.reset();
            writer_.reset();
            soundWriter_.reset();
            std::error_code ec;
            std::filesystem::remove(options.file, ec);
            std::filesystem::remove(soundFile(options.file), ec);
            throw std::runtime_error("the screen could not be recorded: " + plain(error));
        }
    }
    thread_ = std::thread([this] { run(); });
}

ScreenRecorder::~ScreenRecorder() {
    try {
        stop();
    } catch (...) {
    }
}

RECT ScreenRecorder::area() const {
    std::lock_guard guard(areaLock_);
    return area_;
}

std::string ScreenRecorder::problem() const {
    std::lock_guard guard(problemLock_);
    return problem_;
}

void ScreenRecorder::note(const std::string& problem) {
    std::lock_guard guard(problemLock_);
    if (problem_.empty()) problem_ = problem;
}

void ScreenRecorder::run() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    // A timer that wakes within a millisecond, so the pictures are evenly spaced.
    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!timer) timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    LONGLONG next = t0_;
    while (!stopping_) {
        const LONGLONG wait = next - MFGetSystemTime();
        if (wait > 0 && timer) {
            LARGE_INTEGER due;
            due.QuadPart = -wait;
            SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
            WaitForSingleObject(timer, 100);
        }
        if (stopping_) break;
        const LONGLONG now = MFGetSystemTime();
        try {
            step(now);
        } catch (const std::exception& error) {
            note(error.what());
        } catch (const winrt::hresult_error& error) {
            note(plain(error));
        }
        next += frameTime;
        if (next < now - second) next = now;  // fell far behind (the PC was busy): carry on from now
    }
    if (timer) CloseHandle(timer);
    winrt::uninit_apartment();
}

void ScreenRecorder::step(LONGLONG now) {
    tick_++;
    // The shared window, followed twice a second as it moves or changes size.
    if (options_.window && tick_ % 15 == 0 && IsWindow(options_.window) && !IsIconic(options_.window)) {
        RECT r = windowArea(options_.window);
        if (r.right - r.left > 50 && r.bottom - r.top > 50) {
            std::lock_guard guard(areaLock_);
            area_ = r;
        }
    }

    bool fresh = false;
    LONGLONG at = now;
    if (capture_) {
        auto frame = capture_->take();
        if (frame) {
            const auto size = frame.ContentSize();
            const LONGLONG captured = frame.SystemRelativeTime().count();
            if (!capture_->clockChecked) {
                // The frame's time should be on the same clock as everything else; if it is far off, the
                // time it arrived is used instead.
                capture_->clockChecked = true;
                if (std::llabs(captured - now) > second) capture_->clockShift = now - captured;
            }
            at = captured + capture_->clockShift;

            winrt::com_ptr<ID3D11Texture2D> texture;
            auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), texture.put_void()));
            D3D11_TEXTURE2D_DESC desc{};
            texture->GetDesc(&desc);
            if (!capture_->copy || [&] {
                    D3D11_TEXTURE2D_DESC have{};
                    capture_->copy->GetDesc(&have);
                    return have.Width != desc.Width || have.Height != desc.Height;
                }()) {
                D3D11_TEXTURE2D_DESC made = desc;
                made.Usage = D3D11_USAGE_DEFAULT;
                made.BindFlags = D3D11_BIND_SHADER_RESOURCE;
                made.CPUAccessFlags = 0;
                made.MiscFlags = 0;
                made.MipLevels = 1;
                made.ArraySize = 1;
                made.SampleDesc = {1, 0};
                capture_->copy.Reset();
                check(device_->CreateTexture2D(&made, nullptr, &capture_->copy), "keeping the screen picture");
            }
            ComPtr<ID3D11DeviceContext> context;
            device_->GetImmediateContext(&context);
            context->CopyResource(capture_->copy.Get(), texture.get());
            frame.Close();

            // The part shown: the whole screen, or the window's place on it.
            const LONG cw = std::min<LONG>(size.Width, static_cast<LONG>(desc.Width));
            const LONG ch = std::min<LONG>(size.Height, static_cast<LONG>(desc.Height));
            RECT from{0, 0, cw, ch};
            if (options_.window) {
                RECT r = area();
                RECT shifted{r.left - monitorRect_.left, r.top - monitorRect_.top, r.right - monitorRect_.left, r.bottom - monitorRect_.top};
                RECT inside{};
                if (IntersectRect(&inside, &shifted, &from) && inside.right - inside.left > 8 && inside.bottom - inside.top > 8) from = inside;
            }
            converter_->convert(capture_->copy.Get(), from, picture_);
            fresh = true;

            // The screen changed size (a new resolution): the pool follows.
            if (size.Width != capture_->poolSize.Width || size.Height != capture_->poolSize.Height) {
                capture_->poolSize = size;
                capture_->pool.Recreate(capture_->device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 3, size);
                if (!options_.window) {
                    std::lock_guard guard(areaLock_);
                    area_ = RECT{monitorRect_.left, monitorRect_.top, monitorRect_.left + size.Width, monitorRect_.top + size.Height};
                }
            }
        }
    } else {
        // The test pattern: grey, colour bars along the top, and a white square crossing the picture.
        const LONG w = 1280, h = 720;
        static const BYTE bars[7][3] = {{192, 192, 192}, {0, 192, 192}, {192, 192, 0}, {0, 192, 0}, {192, 0, 192}, {0, 0, 192}, {192, 0, 0}};
        const LONG x0 = (tick_ * 12) % (w - 160);
        for (LONG y = 0; y < h; y++) {
            BYTE* row = &pattern_[static_cast<size_t>(y) * w * 4];
            for (LONG x = 0; x < w; x++) {
                BYTE* p = row + x * 4;
                if (y < 200) {
                    const BYTE* bar = bars[x * 7 / w];
                    p[0] = bar[0];
                    p[1] = bar[1];
                    p[2] = bar[2];
                } else if (y >= 320 && y < 480 && x >= x0 && x < x0 + 160) {
                    p[0] = p[1] = p[2] = 240;
                } else {
                    p[0] = p[1] = p[2] = 70;
                }
                p[3] = 255;
            }
        }
        if (!patternTexture_) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = w;
            desc.Height = h;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            check(device_->CreateTexture2D(&desc, nullptr, &patternTexture_), "making the test pattern");
        }
        ComPtr<ID3D11DeviceContext> context;
        device_->GetImmediateContext(&context);
        context->UpdateSubresource(patternTexture_.Get(), 0, nullptr, pattern_.data(), w * 4, 0);
        converter_->convert(patternTexture_.Get(), RECT{0, 0, w, h}, picture_);
        fresh = true;
    }

    std::lock_guard guard(writeLock_);
    if (stopped_) return;
    if (fresh) havePicture_ = true;
    if (havePicture_) {
        // A new picture at the moment it was captured; a still screen repeats its last picture, so the
        // file keeps a steady 30 frames a second and a key frame every 2 seconds.
        LONGLONG t = at - t0_;
        if (!fresh) t = now - t0_;
        if (lastPicture_ >= 0) t = std::max(t, lastPicture_ + second / 1000);
        if (t >= 0 && (fresh || t - lastPicture_ >= frameTime - second / 200)) {
            writer_->writeVideo(picture_.data(), static_cast<LONG>(format_.width), t);
            lastPicture_ = t;
            pictures_++;
            if (fresh) newPictures_++;
        }
    }
    keepComputerSoundGoing(now);
}

void ScreenRecorder::addMic(const int16_t* samples, UINT32 frames, LONGLONG time) {
    std::lock_guard guard(writeLock_);
    if (stopped_ || !writer_) return;
    try {
        placeSound(*writer_, micWritten_, samples, frames, 1, time, t0_, rate);
    } catch (const std::exception& error) {
        note(error.what());
    }
}

void ScreenRecorder::onComputerSound(const int16_t* samples, UINT32 frames, LONGLONG time, bool silent) {
    lastSoundPacket_ = MFGetSystemTime();
    static thread_local std::vector<int16_t> quiet;
    if (!soundOn_ || silent) {
        quiet.assign(static_cast<size_t>(frames) * 2, 0);
        samples = quiet.data();
    }
    std::lock_guard guard(writeLock_);
    if (stopped_ || !soundWriter_) return;
    try {
        placeSound(*soundWriter_, soundWritten_, samples, frames, 2, time, t0_, rate);
    } catch (const std::exception& error) {
        note(error.what());
    }
}

// Windows sends nothing from the speakers while nothing plays. The track is kept up to time with
// silence, a moment behind, so the sound that comes next still lands in its place.
void ScreenRecorder::keepComputerSoundGoing(LONGLONG now) {
    if (now - lastSoundPacket_ < second * 3 / 10) return;
    const long long until = (now - t0_ - second / 10) * rate / second;
    if (until > soundWritten_ + rate / 5) padSound(*soundWriter_, soundWritten_, until, rate);
}

void ScreenRecorder::stop() {
    if (stopping_.exchange(true)) return;
    if (thread_.joinable()) thread_.join();
    loopback_.reset();  // its thread writes through writeLock_, so it stops outside it
    if (capture_) capture_->close();
    const LONGLONG end = MFGetSystemTime() - t0_;
    std::lock_guard guard(writeLock_);
    stopped_ = true;
    if (!writer_) return;
    try {
        // Every track runs to the moment of Stop: the last picture once more, and silence after the last sound.
        if (havePicture_ && end > lastPicture_ + second / 1000) writer_->writeVideo(picture_.data(), static_cast<LONG>(format_.width), end);
        padSound(*writer_, micWritten_, end * rate / second, rate);
        padSound(*soundWriter_, soundWritten_, end * rate / second, rate);
        writer_->finish();
        soundWriter_->finish();
    } catch (const std::exception& error) {
        note(error.what());
    }
}

}  // namespace capture
