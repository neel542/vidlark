#pragma once
// video.mp4, the finished video, made with ffmpeg. Port of Compose.swift, which used AVFoundation.

#include "support.h"

#include <optional>

namespace vl {

struct ComposeResult {
    double seconds = 0;
    int width = 0;
    int height = 0;
    /// When the video changes from camera.mov to screen.mov, if it starts on camera.mov.
    std::optional<double> cameraUntil;
};

/// How long the change from camera.mov to screen.mov takes.
constexpr double handoverSeconds = 0.25;

struct SoundSource {
    fs::path path;
    double offset;  // camera time = file time + offset
};

ComposeResult composeVideo(const fs::path& ffmpeg, const fs::path& ffprobe, const fs::path& camera, const fs::path& screen,
                           double screenOffset, bool sharedLate, const std::optional<SoundSource>& sound,
                           const fs::path& out, const fs::path& workDir);
ComposeResult cameraWithSound(const fs::path& ffmpeg, const fs::path& ffprobe, const fs::path& camera,
                              const SoundSource& sound, const fs::path& out);

}  // namespace vl
