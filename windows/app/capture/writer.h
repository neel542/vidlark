#pragma once
// Writes a movie the way the Mac app does: H.264 picture (hardware encoder when the PC has one) and
// AAC sound, in a fragmented MP4 cut every 2 seconds, so a crash keeps everything up to the last piece.
// Used for camera.mov (picture and the main mic), screen.mov (picture, the main mic, then the
// computer's sound as a second sound track) and mic-N.m4a (sound only).

#include <windows.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

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
    // With several sound tracks, in this order in the file (screen.mov: the mic, then the computer's sound).
    MovieWriter(const std::filesystem::path& path, std::optional<VideoFormat> video, const std::vector<AudioFormat>& audio);
    ~MovieWriter();
    MovieWriter(const MovieWriter&) = delete;
    MovieWriter& operator=(const MovieWriter&) = delete;

    // One NV12 picture (width x height, rows `stride` bytes apart), at `time` in 100 ns units from the take's start.
    void writeVideo(const BYTE* nv12, LONG stride, LONGLONG time);
    // An NV12 picture already in a Media Foundation sample (from the camera), with its own time.
    void writeVideo(IMFSample* sample);
    // Interleaved 16-bit samples at `time`, on sound track `track` (0 is the first).
    void writeAudio(const int16_t* samples, UINT32 frames, LONGLONG time, size_t track = 0);
    // Silence of `frames` samples at `time`, so the sound track has no holes.
    void writeSilence(UINT32 frames, LONGLONG time, size_t track = 0);
    // Ends the file properly. Called by the destructor if not called before.
    void finish();

    const VideoFormat& video() const { return videoFormat_; }
    bool hasVideo() const { return videoStream_ != kNone; }
    bool hasAudio() const { return !audioStreams_.empty(); }
    size_t audioTracks() const { return audioStreams_.size(); }

private:
    static constexpr DWORD kNone = 0xFFFFFFFF;
    Microsoft::WRL::ComPtr<IMFMediaSink> sink_;
    Microsoft::WRL::ComPtr<IMFSinkWriter> writer_;
    DWORD videoStream_ = kNone;
    std::vector<DWORD> audioStreams_;
    VideoFormat videoFormat_;
    std::vector<AudioFormat> audioFormats_;
    LONGLONG frameDuration_ = 333333;
    bool finished_ = false;
};

// Writes sound at its place on a track, measured from `t0` (the PC's clock, 100 ns units), filling a gap
// of more than 10 ms with silence and never going back in time, so the track runs from 0 without holes.
// `written` counts the track's samples so far; `channels` is the track's.
void placeSound(MovieWriter& writer, size_t track, long long& written, const int16_t* samples, UINT32 frames,
                UINT32 channels, LONGLONG time, LONGLONG t0, UINT32 rate = 48000);
// Silence on the track until it holds `until` samples.
void padSound(MovieWriter& writer, size_t track, long long& written, long long until, UINT32 rate = 48000);

// Throws std::runtime_error naming `what` when a Media Foundation call fails.
void check(HRESULT result, const char* what);

}  // namespace capture
