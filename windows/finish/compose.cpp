#include "compose.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

// video.mp4: the finished video. During the take, Me fills the screen with the camera and Screen
// shrinks it back into the face bubble, and all of that is in screen.mov, so from the moment
// screen.mov has pictures the video is simply screen.mov. Before that (a camera-first take, until
// the screen is shared) it is camera.mov, cropped the same way the camera filled the screen.
// The sound is the mic from camera.mov, or another mic picked for the video (lined up by the
// finisher), plus the computer's sound when it was ticked.
//
// The Mac version builds this with AVFoundation. Here ffmpeg does the same work with one filter graph.

namespace vl {

namespace {

struct Stream {
    std::string type;
    int width = 0;
    int height = 0;
    double start = 0;
    std::optional<double> duration;
};

struct Probe {
    std::optional<double> duration;
    std::vector<Stream> video;
    std::vector<Stream> audio;
};

std::optional<double> number(const nlohmann::json& value) {
    try {
        if (value.is_string()) return std::stod(value.get<std::string>());
        if (value.is_number()) return value.get<double>();
    } catch (...) {
    }
    return std::nullopt;
}

Probe probe(const fs::path& ffprobe, const fs::path& file) {
    auto result = runTool(ffprobe, {"-v", "error", "-show_entries",
                                    "format=duration:stream=codec_type,width,height,start_time,duration:stream_side_data=rotation",
                                    "-of", "json", utf8(file)});
    auto json = result.status == 0 ? nlohmann::json::parse(result.out, nullptr, false) : nlohmann::json();
    if (result.status != 0 || json.is_discarded() || !json.is_object()) {
        throw FinishError(utf8(file.filename()) + " could not be read: " + result.lastErrorLine());
    }
    Probe p;
    if (json.contains("format") && json["format"].contains("duration")) p.duration = number(json["format"]["duration"]);
    for (const auto& s : json.value("streams", nlohmann::json::array())) {
        Stream stream;
        stream.type = s.value("codec_type", "");
        stream.width = s.value("width", 0);
        stream.height = s.value("height", 0);
        if (s.contains("start_time")) stream.start = number(s["start_time"]).value_or(0);
        if (s.contains("duration")) stream.duration = number(s["duration"]);
        // A picture turned a quarter round is stored on its side: its upright size swaps.
        for (const auto& side : s.value("side_data_list", nlohmann::json::array())) {
            if (side.contains("rotation")) {
                int rotation = static_cast<int>(std::lround(number(side["rotation"]).value_or(0)));
                if (std::abs(rotation) % 180 == 90) std::swap(stream.width, stream.height);
            }
        }
        if (stream.type == "video") p.video.push_back(stream);
        if (stream.type == "audio") p.audio.push_back(stream);
    }
    return p;
}

// The best H.264 encoder this ffmpeg has. H.264 plays everywhere; HEVC needs a paid add-on on Windows.
std::vector<std::string> videoEncoder(const fs::path& ffmpeg) {
    static std::vector<std::string> chosen;
    if (!chosen.empty()) return chosen;
    auto list = runTool(ffmpeg, {"-hide_banner", "-v", "error", "-encoders"}).out;
    auto has = [&](const std::string& name) { return list.find(" " + name + " ") != std::string::npos; };
    if (has("libx264")) {
        chosen = {"-c:v", "libx264", "-preset", "veryfast", "-crf", "20"};
    } else if (has("h264_mf")) {
        chosen = {"-c:v", "h264_mf", "-b:v", "10M", "-hw_encoding", "1"};
    } else if (has("h264_videotoolbox")) {
        chosen = {"-c:v", "h264_videotoolbox", "-b:v", "10M"};
    } else {
        throw FinishError("this ffmpeg has no H.264 encoder");
    }
    return chosen;
}

std::string seconds(double value) { return format("%.4f", value); }

// One sound placed in camera time (camera time = file time + offset), nothing before the camera
// started and nothing after it stopped, as stereo 48 kHz.
std::string placedSound(const std::string& input, double offset, double end, const std::string& label) {
    return "[" + input + "]asetpts=PTS+" + seconds(offset) + "/TB,atrim=start=0,aresample=48000:async=1:first_pts=0,"
           "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,apad,atrim=end=" + seconds(end) +
           "[" + label + "]";
}

// Whether a sound file placed at `offset` overlaps the camera by more than a moment.
bool overlaps(const Probe& sound, double offset, double end) {
    if (sound.audio.empty()) return false;
    const auto& track = sound.audio.front();
    double length = track.duration.value_or(sound.duration.value_or(0));
    double from = std::max(track.start, -offset);
    double to = std::min(track.start + length, end - offset);
    return to > from + 0.05;
}

void run(const fs::path& ffmpeg, const std::vector<std::string>& args, const fs::path& out) {
    std::error_code ec;
    fs::remove(out, ec);
    auto result = runTool(ffmpeg, args);
    if (result.status != 0) {
        fs::remove(out, ec);
        throw FinishError("ffmpeg could not make the video: " + result.lastErrorLine());
    }
}

}  // namespace

ComposeResult composeVideo(const fs::path& ffmpeg, const fs::path& ffprobe, const fs::path& camera, const fs::path& screen,
                           double screenOffset, bool sharedLate, const std::optional<SoundSource>& sound,
                           const fs::path& out, const fs::path& workDir) {
    auto cameraInfo = probe(ffprobe, camera);
    auto screenInfo = probe(ffprobe, screen);
    if (cameraInfo.video.empty()) throw FinishError("camera.mov has no picture");
    if (screenInfo.video.empty()) throw FinishError("screen.mov has no picture");
    const Stream& cameraVideo = cameraInfo.video.front();
    const Stream& screenVideo = screenInfo.video.front();
    const double end = cameraInfo.duration.value_or(cameraVideo.duration.value_or(0));
    if (end <= 0) throw FinishError("camera.mov has no picture");

    // Where the screen has pictures, in camera time.
    const double screenLength = screenVideo.duration.value_or(screenInfo.duration.value_or(0));
    const double screenFrom = std::max(0.0, screenVideo.start + screenOffset);
    const double screenTo = std::min(end, screenVideo.start + screenLength + screenOffset);
    if (screenTo <= screenFrom + 0.05) throw FinishError("screen.mov does not overlap the camera");
    // A screen that starts within a moment of the camera is the screen from the start.
    const double cut = screenFrom < 1 ? 0 : screenFrom + (sharedLate ? 0.3 : 0);

    // The canvas has the screen's shape, at most 1920 wide, so the screen fills it without bars.
    const double scale = std::min(1.0, 1920.0 / std::max(screenVideo.width, 1));
    const int cw = static_cast<int>(screenVideo.width * scale) & ~1;
    const int ch = static_cast<int>(screenVideo.height * scale) & ~1;

    // The camera covers the canvas. Filling, keep a little more of the top than the bottom: faces sit in the upper half.
    const double fill = std::max(double(cw) / std::max(cameraVideo.width, 1), double(ch) / std::max(cameraVideo.height, 1));
    const int sw = std::max(cw, static_cast<int>(std::ceil(cameraVideo.width * fill)) & ~1);
    const int sh = std::max(ch, static_cast<int>(std::ceil(cameraVideo.height * fill)) & ~1);
    const int cropX = (sw - cw) / 2;
    const int cropY = static_cast<int>((sh - ch) * 0.4);

    std::string graph = format("color=c=black:s=%dx%d:r=30:d=%s[bg];", cw, ch, seconds(end).c_str());
    graph += format("[0:v:0]setpts=PTS-STARTPTS,scale=%d:%d,crop=%d:%d:%d:%d,setsar=1,fps=30[cam];", sw, sh, cw, ch, cropX, cropY);
    // Before the screen has faded in, and after it stops, the camera shows. With no camera-first part,
    // the camera only covers a screen that stops a moment early.
    const bool screenStopsEarly = screenTo < end - 0.05;
    if (cut > 0) {
        graph += "[bg][cam]overlay=eof_action=pass[base];";
    } else if (screenStopsEarly) {
        graph += "[bg][cam]overlay=eof_action=pass:enable='gte(t," + seconds(screenTo) + ")'[base];";
    } else {
        graph += "[bg]null[base];[cam]nullsink;";
    }
    // The screen in camera time, fitted to the canvas; when there is a camera-first part it fades in over it.
    graph += "[1:v:0]setpts=PTS+" + seconds(screenOffset) + "/TB,trim=start=0:end=" + seconds(end) +
             format(",scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuva420p",
                    cw, ch, cw, ch);
    if (cut > 0) graph += ",fade=t=in:st=" + seconds(cut) + ":d=" + seconds(handoverSeconds) + ":alpha=1";
    graph += "[scr];[base][scr]overlay=eof_action=pass,format=yuv420p,trim=end=" + seconds(end) + "[v]";

    // The sound: the picked mic when it lines up, otherwise camera.mov's mic; plus the computer's sound,
    // the second sound track of screen.mov. The first is the mic again, which would echo, so it is left out.
    std::vector<std::string> inputs = {"-i", utf8(camera), "-i", utf8(screen)};
    std::vector<std::string> voices;
    bool pickedUsed = false;
    if (sound) {
        auto soundInfo = probe(ffprobe, sound->path);
        if (overlaps(soundInfo, sound->offset, end)) {
            inputs.insert(inputs.end(), {"-i", utf8(sound->path)});
            graph += ";" + placedSound("2:a:0", sound->offset, end, "voice");
            voices.push_back("[voice]");
            pickedUsed = true;
        }
    }
    if (!pickedUsed && !cameraInfo.audio.empty()) {
        graph += ";" + placedSound("0:a:0", 0, end, "voice");
        voices.push_back("[voice]");
    }
    if (screenInfo.audio.size() > 1 && overlaps(Probe{screenInfo.duration, {}, {screenInfo.audio[1]}}, screenOffset, end)) {
        graph += ";" + placedSound("1:a:1", screenOffset, end, "mac");
        voices.push_back("[mac]");
    }
    if (voices.size() == 2) {
        graph += ";[voice][mac]amix=inputs=2:normalize=0:duration=longest,atrim=end=" + seconds(end) + "[a]";
    } else if (voices.size() == 1) {
        graph += ";" + voices.front() + "anull[a]";
    }

    // The graph goes in a file: a long take with many parts would not fit on a Windows command line.
    fs::path script = workDir / "compose.txt";
    writeText(graph, script);

    std::vector<std::string> args = {"-nostdin", "-v", "error", "-y"};
    args.insert(args.end(), inputs.begin(), inputs.end());
    args.insert(args.end(), {"-/filter_complex", utf8(script), "-map", "[v]"});
    if (!voices.empty()) args.insert(args.end(), {"-map", "[a]", "-c:a", "aac", "-b:a", "192k"});
    auto encoder = videoEncoder(ffmpeg);
    args.insert(args.end(), encoder.begin(), encoder.end());
    args.insert(args.end(), {"-pix_fmt", "yuv420p", "-r", "30", "-t", seconds(end), "-movflags", "+faststart", utf8(out)});
    run(ffmpeg, args, out);

    ComposeResult result;
    result.seconds = end;
    result.width = cw;
    result.height = ch;
    if (cut > 0) result.cameraUntil = cut;
    return result;
}

ComposeResult cameraWithSound(const fs::path& ffmpeg, const fs::path& ffprobe, const fs::path& camera,
                              const SoundSource& sound, const fs::path& out) {
    auto cameraInfo = probe(ffprobe, camera);
    if (cameraInfo.video.empty()) throw FinishError("camera.mov has no picture");
    auto soundInfo = probe(ffprobe, sound.path);
    if (soundInfo.audio.empty()) throw FinishError(utf8(sound.path.filename()) + " has no sound");
    const double end = cameraInfo.duration.value_or(cameraInfo.video.front().duration.value_or(0));

    // camera.mov's picture as it is, with the other mic's sound lined up under it. The picture is not compressed again.
    std::vector<std::string> args = {"-nostdin", "-v", "error", "-y", "-i", utf8(camera), "-i", utf8(sound.path),
                                     "-filter_complex", placedSound("1:a:0", sound.offset, end, "a"),
                                     "-map", "0:v:0", "-map", "[a]", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                                     "-t", seconds(end), "-movflags", "+faststart", utf8(out)};
    run(ffmpeg, args, out);

    ComposeResult result;
    result.seconds = end;
    result.width = cameraInfo.video.front().width;
    result.height = cameraInfo.video.front().height;
    return result;
}

}  // namespace vl
