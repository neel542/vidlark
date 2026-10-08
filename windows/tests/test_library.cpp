// Tests for the library's folder naming and the events.jsonl log.
#include "check.h"
#include "events.h"
#include "library.h"

#include <random>
#include <thread>

namespace {
fs::path tempDir(const char* name) {
    fs::path dir = fs::temp_directory_path() / (std::string(name) + "-" + std::to_string(std::random_device{}()));
    fs::create_directories(dir);
    return dir;
}
}  // namespace

TEST("safeName swaps the characters folders cannot have, trims, and keeps 60 letters") {
    CHECK(vl::safeName("Fix a listing: part 1/2") == "Fix a listing- part 1-2");
    CHECK(vl::safeName("   ") == "Untitled");
    CHECK(vl::safeName("  Brand Registry \n") == "Brand Registry");
    std::string long70(70, 'a');
    CHECK(vl::safeName(long70).size() == 60);
    std::string accents;
    for (int i = 0; i < 70; i++) accents += "\xC3\xA9";  // e with an accent, two bytes each
    CHECK(vl::safeName(accents).size() == 120);
}

TEST("newRecordingFolder makes <date> <title>/recording-N and counts on") {
    fs::path root = tempDir("vidlark-library");
    std::optional<fs::path> video;
    fs::path first = vl::newRecordingFolder(root, video, std::string("Fix a listing"));
    CHECK(video.has_value());
    CHECK(vl::utf8(first.filename()) == "recording-1");
    CHECK(vl::utf8(first.parent_path().filename()) == vl::today() + " Fix a listing");
    fs::path second = vl::newRecordingFolder(root, video, std::string("Fix a listing"));
    CHECK(vl::utf8(second.filename()) == "recording-2");
    std::optional<fs::path> other;
    fs::path third = vl::newRecordingFolder(root, other, std::string("Fix a listing"));
    CHECK(vl::utf8(third.parent_path().filename()) == vl::today() + " Fix a listing (2)");
    std::optional<fs::path> quick;
    fs::path fourth = vl::newRecordingFolder(root, quick, std::nullopt);
    CHECK(vl::utf8(fourth.parent_path().filename()).find("Quick recording ") != std::string::npos);
    fs::remove_all(root);
}

TEST("EventLog writes lines readEvents reads back") {
    fs::path dir = tempDir("vidlark-events");
    fs::path file = dir / "events.jsonl";
    auto t0 = vl::EventLog::Clock::now();
    {
        vl::EventLog log(file, t0);
        log.write({{"type", "start"}, {"wall", vl::wallClock()}, {"title", "Fix a listing"}, {"screen", ""},
                   {"extraMics", {{{"file", "mic-2.m4a"}, {"name", "Yeti"}}}}, {"videoMic", "mic-2.m4a"}}, t0);
        log.write({{"type", "mic-start"}, {"file", "mic-2.m4a"}, {"at", 0.042}}, t0 + std::chrono::milliseconds(42));
        log.write({{"type", "card"}, {"index", 1}, {"section", "Hook"}}, t0 + std::chrono::milliseconds(1500));
        log.write({{"type", "stop"}}, t0 + std::chrono::milliseconds(12345));
    }
    auto events = vl::readEvents(file);
    CHECK(events.has_value());
    if (events) {
        CHECK(events->title == std::optional<std::string>("Fix a listing"));
        CHECK(events->cameraFirst);
        CHECK(events->videoMic == std::optional<std::string>("mic-2.m4a"));
        CHECK(events->micNames.at("mic-2.m4a") == "Yeti");
        CHECK_NEAR(events->micStarts.at("mic-2.m4a"), 0.042, 1e-9);
        CHECK(events->cards.size() == 1);
        CHECK_NEAR(events->stopTime.value_or(0), 12.345, 1e-9);
        CHECK(events->skippedLines == 0);
    }
    std::string text = vl::readFile(file);
    CHECK(text.find("\"t\":12.345") != std::string::npos);
    CHECK(text.find("{\"index\":1,\"section\":\"Hook\",\"t\":1.5,\"type\":\"card\"}") != std::string::npos);
    fs::remove_all(dir);
}
