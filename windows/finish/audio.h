#pragma once
// Sound: taking it out of the videos with ffmpeg, reading WAV files, and lining two recordings up by
// their sound. Port of Audio.swift (vDSP replaced by plain loops).

#include "support.h"

#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace vl {

struct AudioOutput {
    fs::path path;
    int rate;
};

/// Mono 16-bit WAV files at the given rates from the first sound track of `input`.
void extractAudio(const fs::path& ffmpeg, const fs::path& input, const std::vector<AudioOutput>& outputs,
                  std::optional<double> startSeconds = std::nullopt, std::optional<double> maxSeconds = std::nullopt);

struct WavInfo {
    int sampleRate = 0;
    size_t dataOffset = 0;
    size_t sampleCount = 0;
    double duration() const { return sampleRate > 0 ? double(sampleCount) / double(sampleRate) : 0; }
};
WavInfo readWavInfo(const std::string& data);  // throws FinishError
struct Wav {
    std::vector<float> samples;
    WavInfo info;
};
Wav readWav(const fs::path& path, std::optional<double> maxSeconds = std::nullopt);

struct SyncResult {
    double offset = 0;           // camera_t = screen_t + offset
    std::string method = "none";  // "audio", "clock" or "none"
    double confidence = 0;        // 0...1
    std::optional<std::string> note;
};

struct ExtraCameraSync {
    std::string file;
    std::optional<double> duration;
    SyncResult sync;
};

struct ExtraMicSync {
    std::string file;
    std::optional<std::string> name;
    std::optional<double> duration;
    SyncResult sync;
};

std::vector<double> loudnessEnvelope(const std::vector<float>& samples, int frameLength);
struct Lag {
    double lag;
    double correlation;
};
std::optional<Lag> bestLag(const std::vector<double>& camera, const std::vector<double>& screen, int maxLag, int minOverlap);
SyncResult measureSync(const fs::path& cameraWav, const fs::path& screenWav, double maxLagSeconds = 3);

}  // namespace vl
