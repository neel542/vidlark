#include "audio.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdint>
#include <fstream>

namespace vl {

// MARK: Extraction

// aresample with first_pts=0 pads any late audio start with silence, so sample 0 of each
// wav is time 0 of its movie, and async=1 fills gaps the same way.
void extractAudio(const fs::path& ffmpeg, const fs::path& input, const std::vector<AudioOutput>& outputs,
                  std::optional<double> startSeconds, std::optional<double> maxSeconds) {
    std::vector<std::string> args = {"-nostdin", "-v", "error", "-y"};
    if (startSeconds) args.insert(args.end(), {"-ss", format("%.3f", *startSeconds)});
    if (maxSeconds) args.insert(args.end(), {"-t", format("%.1f", *maxSeconds)});
    args.insert(args.end(), {"-i", utf8(input)});
    for (const auto& output : outputs) {
        const std::string rate = std::to_string(output.rate);
        args.insert(args.end(), {
            "-map", "0:a:0", "-vn",
            "-af", "aresample=" + rate + ":async=1:first_pts=0",
            "-ac", "1", "-ar", rate, "-c:a", "pcm_s16le",
            utf8(output.path),
        });
    }
    const ProcessResult result = runTool(ffmpeg, args);
    for (const auto& output : outputs) {
        std::error_code ec;
        std::uintmax_t size = fs::file_size(output.path, ec);
        if (ec) size = 0;
        if (result.status != 0 || size <= 44u) throw FinishError(result.lastErrorLine());
    }
}

// MARK: WAV reading (16-bit mono PCM, as written by extractAudio)

namespace {

std::uint64_t u16(const std::string& bytes, size_t at) {
    auto byte = [&](size_t i) { return std::uint64_t(static_cast<unsigned char>(bytes[i])); };
    return byte(at) | byte(at + 1) << 8;
}

std::uint64_t u32(const std::string& bytes, size_t at) {
    auto byte = [&](size_t i) { return std::uint64_t(static_cast<unsigned char>(bytes[i])); };
    return byte(at) | byte(at + 1) << 8 | byte(at + 2) << 16 | byte(at + 3) << 24;
}

bool tag(const std::string& bytes, size_t at, const char* name) { return bytes.compare(at, 4, name) == 0; }

// The chunk walk of readWavInfo over a file of `count` bytes, reading through `read(at, length)`, so
// readWav can look at the headers without loading the whole file (the Swift maps it instead).
template <class Read>
WavInfo walkWav(std::uint64_t count, const Read& read) {
    if (count < 12) throw FinishError("not a wav file");
    const std::string head = read(0, 12);
    if (!tag(head, 0, "RIFF") || !tag(head, 8, "WAVE")) throw FinishError("not a wav file");
    std::uint64_t position = 12;
    std::uint64_t rate = 0;
    std::uint64_t channels = 0;
    std::uint64_t bits = 0;
    while (position + 8 <= count) {
        // The chunk's 8-byte header, and the 16 bytes of a fmt chunk's body when there are that many.
        const std::string chunk = read(position, static_cast<size_t>(std::min<std::uint64_t>(24, count - position)));
        const std::uint64_t size = u32(chunk, 4);
        const std::uint64_t body = position + 8;
        if (tag(chunk, 0, "fmt ") && body + 16 <= count) {
            channels = u16(chunk, 8 + 2);
            rate = u32(chunk, 8 + 4);
            bits = u16(chunk, 8 + 14);
        } else if (tag(chunk, 0, "data")) {
            if (rate == 0 || rate > std::uint64_t(INT_MAX) || channels != 1 || bits != 16) {
                throw FinishError("unexpected wav format");
            }
            const std::uint64_t available = count - body;
            const std::uint64_t bytes = (size == 0 || size > available) ? available : size;
            WavInfo info;
            info.sampleRate = static_cast<int>(rate);
            info.dataOffset = static_cast<size_t>(body);
            info.sampleCount = static_cast<size_t>(bytes / 2);
            return info;
        }
        position = body + size + (size & 1);
    }
    throw FinishError("wav file has no audio data");
}

}  // namespace

WavInfo readWavInfo(const std::string& data) {
    return walkWav(data.size(), [&](std::uint64_t at, size_t length) { return data.substr(static_cast<size_t>(at), length); });
}

Wav readWav(const fs::path& path, std::optional<double> maxSeconds) {
    std::ifstream in(path, std::ios::binary);
    std::error_code ec;
    const std::uintmax_t fileSize = fs::file_size(path, ec);
    if (!in || ec) throw FinishError("could not read " + utf8(path));
    auto read = [&](std::uint64_t at, size_t length) {
        std::string bytes(length, '\0');
        in.seekg(static_cast<std::streamoff>(at));
        in.read(bytes.data(), static_cast<std::streamsize>(length));
        if (!in) throw FinishError("could not read " + utf8(path));
        return bytes;
    };

    Wav wav;
    wav.info = walkWav(fileSize, read);
    size_t count = wav.info.sampleCount;
    if (maxSeconds) {
        const double limit = *maxSeconds * double(wav.info.sampleRate);
        if (limit < double(count)) count = limit > 0 ? static_cast<size_t>(limit) : 0;
    }
    const std::string data = count > 0 ? read(wav.info.dataOffset, count * 2) : std::string();
    wav.samples.resize(count);
    const float scale = 1.0f / 32768.0f;
    for (size_t i = 0; i < count; i++) {
        const auto lo = static_cast<unsigned char>(data[2 * i]);
        const auto hi = static_cast<unsigned char>(data[2 * i + 1]);
        const auto value = static_cast<std::int16_t>(static_cast<std::uint16_t>(lo | hi << 8));
        wav.samples[i] = static_cast<float>(value) * scale;
    }
    return wav;
}

// MARK: Sync

// RMS loudness of consecutive frames, returned as double for the correlation sums.
std::vector<double> loudnessEnvelope(const std::vector<float>& samples, int frameLength) {
    if (frameLength <= 0) return {};
    const size_t length = static_cast<size_t>(frameLength);
    const size_t frames = samples.size() / length;
    std::vector<double> envelope(frames, 0.0);
    for (size_t i = 0; i < frames; i++) {
        const float* frame = samples.data() + i * length;
        float sum = 0;
        for (size_t k = 0; k < length; k++) sum += frame[k] * frame[k];
        envelope[i] = double(std::sqrt(sum / static_cast<float>(frameLength)));
    }
    return envelope;
}

// Finds lag d (in frames) where camera[k] best matches screen[k - d], using the Pearson
// correlation over the overlap at each lag. Returns the lag in frames (with sub-frame
// refinement) and the peak correlation.
std::optional<Lag> bestLag(const std::vector<double>& camera, const std::vector<double>& screen, int maxLag, int minOverlap) {
    if (maxLag < 0) return std::nullopt;
    struct PrefixSums {
        std::vector<double> sum, sq;
    };
    auto prefixSums = [](const std::vector<double>& x) {
        PrefixSums p{std::vector<double>(x.size() + 1, 0.0), std::vector<double>(x.size() + 1, 0.0)};
        for (size_t i = 0; i < x.size(); i++) {
            p.sum[i + 1] = p.sum[i] + x[i];
            p.sq[i + 1] = p.sq[i] + x[i] * x[i];
        }
        return p;
    };
    auto mean = [](const std::vector<double>& x) {
        double total = 0;
        for (double v : x) total += v;
        return x.empty() ? 0.0 : total / double(x.size());
    };
    // Centre both signals so the sums stay well conditioned.
    const double cMean = mean(camera);
    const double sMean = mean(screen);
    std::vector<double> c(camera.size()), s(screen.size());
    for (size_t i = 0; i < camera.size(); i++) c[i] = -cMean + camera[i];
    for (size_t i = 0; i < screen.size(); i++) s[i] = -sMean + screen[i];
    const PrefixSums cp = prefixSums(c);
    const PrefixSums sp = prefixSums(s);

    const long long cCount = static_cast<long long>(c.size());
    const long long sCount = static_cast<long long>(s.size());
    auto at = [](long long i) { return static_cast<size_t>(i); };
    std::vector<double> scores(at(2LL * maxLag + 1), -2.0);
    for (long long d = -maxLag; d <= maxLag; d++) {
        const long long start = std::max(0LL, d);
        const long long end = std::min(cCount, sCount + d);
        const long long n = end - start;
        if (n < minOverlap || n < 1) continue;
        double dot = 0;
        for (long long k = 0; k < n; k++) dot += c[at(start + k)] * s[at(start - d + k)];
        const double count = double(n);
        const double sumC = cp.sum[at(end)] - cp.sum[at(start)];
        const double sumC2 = cp.sq[at(end)] - cp.sq[at(start)];
        const double sumS = sp.sum[at(end - d)] - sp.sum[at(start - d)];
        const double sumS2 = sp.sq[at(end - d)] - sp.sq[at(start - d)];
        const double varC = sumC2 - sumC * sumC / count;
        const double varS = sumS2 - sumS * sumS / count;
        if (varC <= 1e-12 || varS <= 1e-12) continue;
        scores[at(d + maxLag)] = (dot - sumC * sumS / count) / std::sqrt(varC * varS);
    }
    // The first of equal peaks, as Swift's max(by:) picks.
    size_t bestIndex = 0;
    for (size_t i = 1; i < scores.size(); i++) {
        if (scores[bestIndex] < scores[i]) bestIndex = i;
    }
    if (!(scores[bestIndex] > -2)) return std::nullopt;
    double refined = double(bestIndex);
    if (bestIndex > 0 && bestIndex < scores.size() - 1 && scores[bestIndex - 1] > -2 && scores[bestIndex + 1] > -2) {
        const double a = scores[bestIndex - 1], b = scores[bestIndex], cc = scores[bestIndex + 1];
        const double denominator = a - 2 * b + cc;
        if (denominator < 0) refined += 0.5 * (a - cc) / denominator;
    }
    return Lag{refined - double(maxLag), scores[bestIndex]};
}

SyncResult measureSync(const fs::path& cameraWav, const fs::path& screenWav, double maxLagSeconds) {
    const double window = 120.0;
    const Wav camera = readWav(cameraWav, window);
    const Wav screen = readWav(screenWav, window + maxLagSeconds);
    const int frameLength = std::max(1, camera.info.sampleRate / 1000);  // 1 ms frames
    const double frameSeconds = double(frameLength) / double(camera.info.sampleRate);
    const std::vector<double> cameraEnvelope = loudnessEnvelope(camera.samples, frameLength);
    const std::vector<double> screenEnvelope = loudnessEnvelope(screen.samples, frameLength);
    const int maxLag = static_cast<int>(maxLagSeconds / frameSeconds);
    const int minOverlap = static_cast<int>(2.0 / frameSeconds);
    SyncResult result;
    const auto match = bestLag(cameraEnvelope, screenEnvelope, maxLag, minOverlap);
    if (!match) {
        result.offset = 0;
        result.method = "none";
        result.confidence = 0;
        result.note = "the two sound tracks are silent or too short to match";
        return result;
    }
    result.offset = match->lag * frameSeconds;
    result.method = "audio";
    result.confidence = std::min(1.0, std::max(0.0, match->correlation));
    return result;
}

}  // namespace vl
