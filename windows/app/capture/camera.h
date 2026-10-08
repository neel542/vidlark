#pragma once
// One camera through Media Foundation: opens it at the size and frame rate closest to what was asked,
// and hands every picture over as NV12 with its time on the PC's clock (QPC, 100 ns units).

#include "writer.h"

#include <atomic>
#include <functional>
#include <string>
#include <thread>

namespace capture {

class Camera {
public:
    using Frame = std::function<void(IMFSample* nv12, LONGLONG time)>;
    // `link` is the camera's symbolic link from devices.cpp. Throws std::runtime_error when it cannot open.
    Camera(const std::wstring& link, VideoFormat wanted, Frame onFrame);
    ~Camera();
    Camera(const Camera&) = delete;
    Camera& operator=(const Camera&) = delete;

    // The size and rate the camera actually gives.
    const VideoFormat& format() const { return format_; }
    // False once the camera stopped sending pictures (unplugged, or taken by another app).
    bool running() const { return running_; }
    // How the camera's times relate to the PC's clock, for the log: "pc" or "arrival".
    const char* clockSource() const { return clockSource_; }
    void stop();

private:
    void run();
    Microsoft::WRL::ComPtr<IMFMediaSource> source_;
    Microsoft::WRL::ComPtr<IMFSourceReader> reader_;
    VideoFormat format_;
    Frame onFrame_;
    std::thread thread_;
    std::atomic<bool> running_{true};
    std::atomic<bool> stopping_{false};
    const char* clockSource_ = "pc";
};

}  // namespace capture
