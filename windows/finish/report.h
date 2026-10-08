#pragma once
// report.md, the plain summary of a take. Port of Report.swift.

#include "audio.h"
#include "chapters.h"
#include "compose.h"
#include "events.h"
#include "transcript.h"

#include <optional>
#include <string>
#include <vector>

namespace vl {

struct TranscriptOutcome {
    enum class Kind { skipped, done, failed } kind = Kind::skipped;
    int wordCount = 0;
    double seconds = 0;
    std::string reason;
};

struct ReportInput {
    fs::path folder;
    std::string title;
    std::optional<std::string> wall;
    std::optional<double> cameraDuration;
    std::optional<double> screenDuration;
    std::optional<std::string> screenNote;
    SyncResult sync;
    std::vector<ExtraCameraSync> extraCameras;
    std::vector<ExtraMicSync> extraMics;
    std::optional<std::string> videoMic;
    std::optional<std::string> videoSoundNote;
    TranscriptOutcome transcript;
    std::optional<std::vector<Retake>> retakes;
    std::vector<Chapter> chapters;
    std::string chapterSource;
    int candidateChapters = 0;
    bool chaptersWanted = true;
    std::optional<RecordingEvents> events;
    std::optional<ComposeResult> video;
    std::optional<std::string> videoProblem;
    bool videoWanted = false;
};

std::string buildReport(const ReportInput& r);

}  // namespace vl
