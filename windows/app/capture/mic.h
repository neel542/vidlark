#pragma once
// One microphone through WASAPI, as 48 kHz mono 16-bit sound with each packet's time on the PC's clock
// (QPC, 100 ns units), and its level for the meter. Also the computer's own sound (loopback).

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>

namespace capture {

class Mic {
public:
    using Sound = std::function<void(const int16_t* samples, UINT32 frames, LONGLONG time, bool silent)>;
    static constexpr UINT32 rate = 48000;

    // `id` from devices.cpp, or empty for Windows' default microphone. `loopback` records what the
    // speakers play instead (the default output). Throws std::runtime_error when it cannot open.
    Mic(const std::wstring& id, bool loopback, Sound onSound);
    ~Mic();
    Mic(const Mic&) = delete;
    Mic& operator=(const Mic&) = delete;

    UINT32 channels() const { return channels_; }
    // Loudness of the last 50 ms: RMS and peak in dB, -160 for silence.
    float levelDb() const { return level_; }
    float peakDb() const { return peak_; }
    bool running() const { return running_; }
    void stop();

private:
    void run();
    Microsoft::WRL::ComPtr<IAudioClient> client_;
    Microsoft::WRL::ComPtr<IAudioCaptureClient> capture_;
    HANDLE ready_ = nullptr;
    UINT32 channels_ = 1;
    Sound onSound_;
    std::thread thread_;
    std::atomic<bool> stopping_{false};
    std::atomic<bool> running_{true};
    std::atomic<float> level_{-160};
    std::atomic<float> peak_{-160};
};

}  // namespace capture
