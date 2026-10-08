#include "mic.h"

#include "writer.h"

#include <avrt.h>

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace capture {

Mic::Mic(const std::wstring& id, bool loopback, Sound onSound) : onSound_(std::move(onSound)) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    check(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)), "listing sound devices");
    ComPtr<IMMDevice> device;
    if (loopback) {
        check(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device), "finding the speakers");
    } else if (id.empty()) {
        check(enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device), "finding the microphone");
    } else {
        check(enumerator->GetDevice(id.c_str(), &device), "finding the microphone");
    }
    check(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_), "opening the microphone");

    // The computer's sound keeps its two channels; a mic is one.
    channels_ = loopback ? 2 : 1;
    WAVEFORMATEX format{};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = static_cast<WORD>(channels_);
    format.nSamplesPerSec = rate;
    format.wBitsPerSample = 16;
    format.nBlockAlign = static_cast<WORD>(channels_ * 2);
    format.nAvgBytesPerSec = rate * format.nBlockAlign;
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    if (loopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
    check(client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 200'000 /* 20 ms */, 0, &format, nullptr), "starting the microphone");
    ready_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    check(client_->SetEventHandle(ready_), "listening to the microphone");
    check(client_->GetService(IID_PPV_ARGS(&capture_)), "reading the microphone");
    check(client_->Start(), "starting the microphone");
    thread_ = std::thread([this] { run(); });
}

Mic::~Mic() {
    stop();
    if (ready_) CloseHandle(ready_);
}

void Mic::stop() {
    stopping_ = true;
    if (thread_.joinable()) thread_.join();
    if (client_) client_->Stop();
    running_ = false;
}

void Mic::run() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DWORD task = 0;
    HANDLE priority = AvSetMmThreadCharacteristicsW(L"Audio", &task);
    std::vector<int16_t> silence;
    double sumSquares = 0, peak = 0;
    UINT32 counted = 0;
    while (!stopping_) {
        // Loopback sends nothing while nothing plays, so wake up anyway to keep the time moving.
        if (WaitForSingleObject(ready_, 100) != WAIT_OBJECT_0 && stopping_) break;
        UINT32 packet = 0;
        while (SUCCEEDED(capture_->GetNextPacketSize(&packet)) && packet > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD bufferFlags = 0;
            UINT64 position = 0, time = 0;
            if (FAILED(capture_->GetBuffer(&data, &frames, &bufferFlags, &position, &time))) break;
            const bool silent = (bufferFlags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            const int16_t* samples = reinterpret_cast<const int16_t*>(data);
            if (silent) {
                silence.assign(static_cast<size_t>(frames) * channels_, 0);
                samples = silence.data();
            }
            for (UINT32 i = 0; i < frames * channels_; i++) {
                const double s = samples[i] / 32768.0;
                sumSquares += s * s;
                peak = std::max(peak, std::fabs(s));
            }
            counted += frames * channels_;
            if (counted >= rate * channels_ / 20) {
                const double rms = std::sqrt(sumSquares / counted);
                level_ = rms > 0 ? static_cast<float>(20 * std::log10(rms)) : -160.0f;
                peak_ = peak > 0 ? static_cast<float>(20 * std::log10(peak)) : -160.0f;
                sumSquares = 0;
                peak = 0;
                counted = 0;
            }
            if (onSound_) onSound_(samples, frames, static_cast<LONGLONG>(time), silent);
            capture_->ReleaseBuffer(frames);
        }
    }
    if (priority) AvRevertMmThreadCharacteristics(priority);
    running_ = false;
    CoUninitialize();
}

}  // namespace capture
