#pragma once
// The recordings library: where takes go and how their folders are named, and the events.jsonl log.
// Port of Library.swift, so a Windows take has the same folder and log as a Mac take.

#include "support.h"

#include <nlohmann/json.hpp>

#include <chrono>
#include <cstdio>
#include <optional>
#include <string>

namespace vl {

// A title made safe for a folder name: no / : \ ? % * | " < >, at most 60 letters, never empty.
// On Windows also no trailing dots or spaces, which Windows does not allow at the end of a name.
std::string safeName(const std::string& title);
// Adds " (2)", " (3)" and so on until nothing on disk has the name.
fs::path uniqueFolder(const fs::path& path);
// `<root>/<date> <title>/recording-N/`. `videoFolder` is the video's folder from an earlier take,
// if it still exists; it is set to the folder used. With no title: "Quick recording HH.mm".
fs::path newRecordingFolder(const fs::path& root, std::optional<fs::path>& videoFolder, const std::optional<std::string>& title);

// The local date as 2026-10-08, and the time now as an ISO 8601 string in UTC, as the Mac writes `wall`.
std::string today();
std::string wallClock();

// events.jsonl: one JSON object per line, keys sorted, each with "t", seconds since the take started,
// rounded to the millisecond. Each line is flushed at once, so a crash keeps every line written.
class EventLog {
public:
    using Clock = std::chrono::steady_clock;
    EventLog(const fs::path& path, Clock::time_point t0);
    ~EventLog();
    EventLog(const EventLog&) = delete;
    EventLog& operator=(const EventLog&) = delete;

    void write(nlohmann::json fields, Clock::time_point at = Clock::now());
    double seconds(Clock::time_point at) const;
    Clock::time_point t0() const { return t0_; }

private:
    std::FILE* file_ = nullptr;
    Clock::time_point t0_;
};

}  // namespace vl
