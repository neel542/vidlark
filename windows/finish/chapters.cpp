#include "chapters.h"

#include <algorithm>

namespace vl {

// Sections from prompter cards when there are any, otherwise app switches.
RawChapters rawChapters(const RecordingEvents& events) {
    auto changes = [](std::vector<Chapter> items) {
        std::stable_sort(items.begin(), items.end(), [](const Chapter& a, const Chapter& b) { return a.t < b.t; });
        std::vector<Chapter> result;
        for (auto& item : items) {
            if (result.empty() || result.back().title != item.title) result.push_back(std::move(item));
        }
        return result;
    };
    if (!events.cards.empty()) {
        std::vector<Chapter> items;
        for (const auto& card : events.cards) items.push_back({card.t, card.section});
        return {changes(std::move(items)), "prompter sections"};
    }
    std::vector<Chapter> items;
    for (const auto& app : events.apps) items.push_back({app.t, app.name});
    return {changes(std::move(items)), "app switches"};
}

// YouTube rules: the first chapter at 00:00, at least 3 chapters, each at least 10 seconds.
// The shortest chapter under 10 seconds is folded into the one before it (the first one into
// the one after it), then repeated, so a brief detour between two parts of the same section
// disappears and the section joins back up.
std::vector<Chapter> youTubeChapters(std::vector<Chapter> input, std::optional<double> end) {
    const double minimum = 10.0;
    std::vector<Chapter> chapters;
    for (auto& chapter : input) {
        if (!end || chapter.t < *end) chapters.push_back(std::move(chapter));
    }
    if (chapters.empty()) return {};
    chapters[0].t = 0;
    for (;;) {
        for (size_t i = 1; i < chapters.size();) {
            if (chapters[i].title == chapters[i - 1].title) {
                chapters.erase(chapters.begin() + static_cast<std::ptrdiff_t>(i));
            } else {
                i += 1;
            }
        }
        std::optional<size_t> shortIndex;
        double shortest = minimum;
        for (size_t index = 0; index < chapters.size(); index++) {
            const std::optional<double> next = index + 1 < chapters.size() ? chapters[index + 1].t : end;
            if (!next) continue;
            const double duration = *next - chapters[index].t;
            if (duration < shortest) {
                shortest = duration;
                shortIndex = index;
            }
        }
        if (!shortIndex || chapters.size() <= 1) break;
        if (*shortIndex == 0) {
            chapters.erase(chapters.begin());
            chapters[0].t = 0;
        } else {
            chapters.erase(chapters.begin() + static_cast<std::ptrdiff_t>(*shortIndex));
        }
    }
    return chapters.size() >= 3 ? chapters : std::vector<Chapter>{};
}

std::string chaptersText(const std::vector<Chapter>& chapters) {
    std::string out;
    for (const auto& chapter : chapters) out += clock(chapter.t) + " " + noEmDash(chapter.title) + "\n";
    return out;
}

}  // namespace vl
