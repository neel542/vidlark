#include "camera.h"

#include <mfapi.h>
#include <mferror.h>

#include <cmath>
#include <cstdlib>
#include <stdexcept>

using Microsoft::WRL::ComPtr;

namespace capture {

namespace {

// How much a camera format is wanted: 0 for none, higher is better. NV12 needs no converting; YUY2 is
// cheap; MJPG is common at 1080p on USB cameras and is decoded by Media Foundation.
int subtypeRank(const GUID& subtype) {
    if (subtype == MFVideoFormat_NV12) return 4;
    if (subtype == MFVideoFormat_YUY2) return 3;
    if (subtype == MFVideoFormat_MJPG) return 2;
    if (subtype == MFVideoFormat_RGB32 || subtype == MFVideoFormat_I420) return 1;
    return 0;
}

}  // namespace

Camera::Camera(const std::wstring& link, VideoFormat wanted, Frame onFrame) : onFrame_(std::move(onFrame)) {
    ComPtr<IMFAttributes> deviceAttributes;
    check(MFCreateAttributes(&deviceAttributes, 2), "making the camera's settings");
    deviceAttributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    deviceAttributes->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, link.c_str());
    check(MFCreateDeviceSource(deviceAttributes.Get(), &source_), "opening the camera");

    ComPtr<IMFAttributes> readerAttributes;
    check(MFCreateAttributes(&readerAttributes, 2), "making the reader's settings");
    // Converts YUY2 or MJPG to NV12, in hardware where it can.
    readerAttributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
    check(MFCreateSourceReaderFromMediaSource(source_.Get(), readerAttributes.Get(), &reader_), "reading the camera");

    // Pick the camera's own format nearest the wanted size, at the wanted frame rate or faster.
    const DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);
    ComPtr<IMFMediaType> best;
    double bestScore = -1;
    for (DWORD i = 0;; i++) {
        ComPtr<IMFMediaType> type;
        if (FAILED(reader_->GetNativeMediaType(stream, i, &type))) break;
        GUID subtype{};
        type->GetGUID(MF_MT_SUBTYPE, &subtype);
        UINT32 w = 0, h = 0, num = 0, den = 1;
        MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h);
        MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &num, &den);
        const int rank = subtypeRank(subtype);
        if (rank == 0 || w == 0 || h == 0 || den == 0) continue;
        const double fps = double(num) / den;
        const double area = double(w) * h, wantArea = double(wanted.width) * wanted.height;
        // Sizes at or under the wanted one score by how close they come; bigger ones score lower.
        double score = area <= wantArea ? 1000.0 * area / wantArea : 1000.0 * wantArea / area - 100;
        if (fps + 0.5 < wanted.fps) score -= 500;
        if (fps > wanted.fps + 1) score -= 5;  // a faster mode than needed costs a little
        score += rank;
        if (score > bestScore) {
            bestScore = score;
            best = type;
        }
    }
    if (!best) throw std::runtime_error("this camera offers no picture format Vidlark can use");
    check(reader_->SetCurrentMediaType(stream, nullptr, best.Get()), "setting the camera's format");

    ComPtr<IMFMediaType> nv12;
    check(MFCreateMediaType(&nv12), "making the picture's format");
    nv12->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    nv12->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    check(reader_->SetCurrentMediaType(stream, nullptr, nv12.Get()), "asking the camera for NV12 pictures");

    ComPtr<IMFMediaType> current;
    check(reader_->GetCurrentMediaType(stream, &current), "reading the camera's format");
    UINT32 num = 30, den = 1;
    MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &format_.width, &format_.height);
    MFGetAttributeRatio(current.Get(), MF_MT_FRAME_RATE, &num, &den);
    format_.fps = den ? static_cast<UINT32>(std::lround(double(num) / den)) : 30;
    if (format_.fps == 0) format_.fps = 30;

    thread_ = std::thread([this] { run(); });
}

Camera::~Camera() { stop(); }

void Camera::stop() {
    stopping_ = true;
    if (thread_.joinable()) thread_.join();
    if (source_) source_->Shutdown();
    running_ = false;
}

void Camera::run() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    // Camera times are usually on the PC's clock already. If the first one is far from it, the times
    // are counted from when the pictures arrive instead.
    bool first = true;
    LONGLONG shift = 0;
    while (!stopping_) {
        DWORD index = 0, flags = 0;
        LONGLONG timestamp = 0;
        ComPtr<IMFSample> sample;
        HRESULT result = reader_->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &index, &flags,
                                             &timestamp, &sample);
        if (FAILED(result) || (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM))) break;
        if (!sample) continue;
        if (first) {
            const LONGLONG now = MFGetSystemTime();
            if (std::llabs(now - timestamp) > 10'000'000) {
                shift = now - timestamp;
                clockSource_ = "arrival";
            }
            first = false;
        }
        const LONGLONG time = timestamp + shift;
        sample->SetSampleTime(time);
        if (onFrame_) onFrame_(sample.Get(), time);
    }
    running_ = false;
    CoUninitialize();
}

}  // namespace capture
