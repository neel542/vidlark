#pragma once
// events.jsonl, the log the app writes during a take. Port of RecordingEvents in Chapters.swift.

#include "support.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

namespace vl {

/// One click of Me or Screen, in camera time.
struct ShowChange {
    double t = 0;
    bool screen = false;
};

struct Card { double t; std::string section; };
struct AppSwitch { double t; std::string name; };
struct SoundChange { double t; bool on; std::string from; };
struct Mute { double t; std::string file; bool on; bool byPhone; };

struct RecordingEvents {
    std::optional<std::string> title;
    std::optional<std::string> wall;
    std::vector<Card> cards;
    std::vector<AppSwitch> apps;
    std::optional<double> stopTime;
    /// The take started with the camera only (its start line names no screen file).
    bool cameraFirst = false;
    /// When the screen was shared in a camera-first take, in camera time.
    std::optional<double> screenShared;
    /// Each click of Me or Screen, in camera time. The first is where the take started.
    std::vector<ShowChange> shows;
    /// Each change of the computer's sound: on or off, and from where.
    std::vector<SoundChange> sounds;
    /// The extra mics, by file: their names, and where each file starts in camera time.
    std::map<std::string, std::string> micNames;
    std::map<std::string, double> micStarts;
    /// Each mute or unmute of a phone's mic, by file, in camera time.
    std::vector<Mute> mutes;
    /// The mic file the video's sound comes from, or none for the main mic.
    std::optional<std::string> videoMic;
    int skippedLines = 0;
};

// Reads events.jsonl line by line. A crash can leave a cut-off last line or no stop line,
// so any line that is not a whole JSON object is counted and skipped. Nothing when the file is missing.
std::optional<RecordingEvents> readEvents(const fs::path& path);

}  // namespace vl
