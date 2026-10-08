#pragma once
// YouTube chapters from the prompter's sections (or app switches). Port of Chapters.swift.

#include "events.h"

#include <optional>
#include <string>
#include <vector>

namespace vl {

struct Chapter {
    double t = 0;
    std::string title;
};

struct RawChapters {
    std::vector<Chapter> chapters;
    std::string source;
};
RawChapters rawChapters(const RecordingEvents& events);
std::vector<Chapter> youTubeChapters(std::vector<Chapter> input, std::optional<double> end);
std::string chaptersText(const std::vector<Chapter>& chapters);

}  // namespace vl
