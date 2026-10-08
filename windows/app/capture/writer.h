#pragma once
// Writes a movie the way the Mac app does: H.264 picture (hardware encoder when the PC has one) and
// AAC sound, in a fragmented MP4 cut every 2 seconds, so a crash keeps everything up to the last piece.
// Used for camera.mov (picture and the main mic), screen.mov and mic-N.m4a (sound only).

#include <windows.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace capture {

struct VideoFormat {
    UINT32 width = 1920;
    UINT32 height = 1080;
    UINT32 fps = 30;
    UINT32 bitrate = 0;  // 0: about 0.12 bits per pixel, the H.264 match for the Mac's HEVC at 0.08
};

struct AudioFormat {
    UINT32 rate = 48000;
    UINT32 channels = 1;
    UINT32 bitrate = 192000;  // AAC: 96000, 128000, 160000 or 192000
};

class MovieWriter {
public:
    // Throws std::runtime_error with a plain sentence when the file cannot be made.
    MovieWriter(const std::filesystem::path& path, std::optional<VideoFormat> video, std::optional<AudioFormat> audio);
    ~MovieWriter();
    MovieWriter(const MovieWriter&) = delete;
    MovieWriter& operator=(const MovieWriter&) = delete;

    // One NV12 picture (width x height, rows `stride` bytes apart), at `time` in 100 ns units from the take's start.
    void writeVideo(const BYTE* nv12, LONG stride, LONGLONG time);
    // An NV12 picture already in a Media Foundation sample (from the camera), with its own time.
    void writeVideo(IMFSample* sample);
    // Interleaved 16-bit samples at `time`.
    void writeAudio(const int16_t* samples, UINT32 frames, LONGLONG time);
    // Silence of `frames` samples at `time`, so the sound track has no holes.
    void writeSilence(UINT32 frames, LONGLONG time);
    // Ends the file properly. Called by the destructor if not called before.
    void finish();

    const VideoFormat& video() const { return videoFormat_; }
    bool hasVideo() const { return videoStream_ != kNone; }
    bool hasAudio() const { return audioStream_ != kNone; }

private:
    static constexpr DWORD kNone = 0xFFFFFFFF;
    Microsoft::WRL::ComPtr<IMFSinkWriter> writer_;
    DWORD videoStream_ = kNone;
    DWORD audioStream_ = kNone;
    VideoFormat videoFormat_;
    AudioFormat audioFormat_;
    LONGLONG frameDuration_ = 333333;
    bool finished_ = false;
};

// Throws std::runtime_error naming `what` when a Media Foundation call fails.
void check(HRESULT result, const char* what);

}  // namespace capture
