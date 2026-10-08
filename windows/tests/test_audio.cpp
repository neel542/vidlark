// Tests for audio, events and chapters.
#include "check.h"

#include "audio.h"
#include "chapters.h"
#include "events.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <random>

namespace {

// A folder of its own under the system temp folder, removed again at the end of the test.
struct TempDir {
    fs::path path;
    TempDir() {
        path = fs::temp_directory_path() / ("vidlark-test-audio-" + std::to_string(std::random_device{}()));
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

void writeBytes(const fs::path& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

std::string le16(unsigned value) {
    return {static_cast<char>(value & 0xFF), static_cast<char>((value >> 8) & 0xFF)};
}
std::string le32(std::uint32_t value) { return le16(value & 0xFFFF) + le16(value >> 16); }

std::string chunk(const std::string& id, const std::string& body) {
    std::string out = id + le32(static_cast<std::uint32_t>(body.size())) + body;
    if (body.size() % 2 == 1) out += '\0';
    return out;
}

struct WavShape {
    int rate = 16000;
    unsigned channels = 1;
    unsigned bits = 16;
    std::string before;            // chunks between fmt and data
    std::optional<std::uint32_t> dataSize;  // what the data chunk says its size is, when not the real one
};

std::string wavBytes(const std::vector<std::int16_t>& samples, const WavShape& shape = {}) {
    std::string pcm;
    for (std::int16_t s : samples) pcm += le16(static_cast<std::uint16_t>(s));
    const auto rate = static_cast<std::uint32_t>(shape.rate);
    std::string fmt = le16(1) + le16(shape.channels) + le32(rate) + le32(rate * shape.channels * shape.bits / 8) +
                      le16(shape.channels * shape.bits / 8) + le16(shape.bits);
    std::string data = "data" + le32(shape.dataSize ? *shape.dataSize : static_cast<std::uint32_t>(pcm.size())) + pcm;
    std::string body = "WAVE" + chunk("fmt ", fmt) + shape.before + data;
    return "RIFF" + le32(static_cast<std::uint32_t>(body.size())) + body;
}

std::vector<std::int16_t> toPcm(const std::vector<double>& signal) {
    std::vector<std::int16_t> out;
    for (double v : signal) out.push_back(static_cast<std::int16_t>(std::max(-1.0, std::min(1.0, v)) * 32767));
    return out;
}

template <class F>
std::string errorOf(F f) {
    try {
        f();
    } catch (const vl::FinishError& e) {
        return e.what();
    }
    return "";
}

// The same numbers on every platform (std's distributions are not).
struct Random {
    std::mt19937 gen;
    explicit Random(unsigned seed) : gen(seed) {}
    double next() { return double(gen()) / 4294967296.0; }  // 0..<1
    double signedNext() { return next() * 2 - 1; }
};

// Bursts of noise at uneven times over a quiet floor, like speech.
std::vector<double> bursts(Random& r, int rate, double seconds) {
    std::vector<double> out(static_cast<size_t>(rate * seconds));
    for (double& v : out) v = 0.01 * r.signedNext();
    for (double t = 0.1; t < seconds; t += 0.2 + 0.4 * r.next()) {
        const double length = 0.05 + 0.1 * r.next();
        const double level = 0.2 + 0.6 * r.next();
        for (auto i = static_cast<size_t>(t * rate); i < out.size() && i < static_cast<size_t>((t + length) * rate); i++) {
            out[i] = level * r.signedNext();
        }
    }
    return out;
}

std::string describe(const std::vector<vl::Chapter>& chapters) {
    std::string out;
    for (const auto& c : chapters) out += (out.empty() ? "" : " ") + vl::format("%g:", c.t) + c.title;
    return out;
}

}  // namespace

// MARK: WAV files

TEST("readWavInfo reads a 16-bit mono wav") {
    const auto info = vl::readWavInfo(wavBytes({0, 1, 2, 3}));
    CHECK(info.sampleRate == 16000);
    CHECK(info.dataOffset == 44);
    CHECK(info.sampleCount == 4);
    CHECK_NEAR(info.duration(), 4.0 / 16000, 1e-12);
}

TEST("readWavInfo walks past other chunks, odd sizes padded") {
    WavShape shape;
    shape.before = chunk("LIST", "abcde") + chunk("JUNK", "1234");  // 8+5+1 and 8+4 bytes
    const auto info = vl::readWavInfo(wavBytes({5, 6, 7}, shape));
    CHECK(info.dataOffset == 12 + 24 + 14 + 12 + 8);
    CHECK(info.sampleCount == 3);

    // A data size of 0 (still being written) or past the end means the rest of the file.
    shape = {};
    shape.dataSize = 0;
    CHECK(vl::readWavInfo(wavBytes({1, 2, 3, 4, 5}, shape)).sampleCount == 5);
    shape.dataSize = 1000;
    CHECK(vl::readWavInfo(wavBytes({1, 2, 3, 4, 5}, shape)).sampleCount == 5);
    CHECK(vl::readWavInfo(wavBytes({1, 2, 3, 4, 5}) + "x").sampleCount == 5);
}

TEST("readWavInfo throws on anything else") {
    CHECK(errorOf([] { vl::readWavInfo(""); }) == "not a wav file");
    CHECK(errorOf([] { vl::readWavInfo(std::string("RIFF\x04\0\0\0WAVX", 12)); }) == "not a wav file");
    CHECK(errorOf([] { vl::readWavInfo(std::string("RIFF\x04\0\0\0WAVE", 12)); }) == "wav file has no audio data");
    WavShape stereo;
    stereo.channels = 2;
    CHECK(errorOf([&] { vl::readWavInfo(wavBytes({1, 2}, stereo)); }) == "unexpected wav format");
    WavShape eightBit;
    eightBit.bits = 8;
    CHECK(errorOf([&] { vl::readWavInfo(wavBytes({1, 2}, eightBit)); }) == "unexpected wav format");
    // data before fmt: no rate yet
    std::string dataFirst = "WAVE" + chunk("data", "abcd") + chunk("fmt ", std::string(16, '\0'));
    CHECK(errorOf([&] { vl::readWavInfo("RIFF" + le32(0) + dataFirst); }) == "unexpected wav format");
}

TEST("readWav scales to -1...1 and stops at maxSeconds") {
    TempDir dir;
    WavShape shape;
    shape.rate = 8;
    shape.before = chunk("LIST", "abc");
    writeBytes(dir.path / "a.wav", wavBytes({0, 16384, -32768, 32767, 1, 2, 3, 4, 5, 6}, shape));
    const auto all = vl::readWav(dir.path / "a.wav");
    CHECK(all.samples.size() == 10);
    CHECK(all.info.sampleRate == 8);
    const auto half = vl::readWav(dir.path / "a.wav", 0.5);
    CHECK(half.samples.size() == 4);
    CHECK(half.samples[0] == 0.0f);
    CHECK(half.samples[1] == 0.5f);
    CHECK(half.samples[2] == -1.0f);
    CHECK(half.samples[3] == 32767.0f / 32768.0f);
    CHECK(vl::readWav(dir.path / "a.wav", 0.3).samples.size() == 2);  // Int(2.4)
    CHECK(vl::readWav(dir.path / "a.wav", 0).samples.empty());
    CHECK(!errorOf([&] { vl::readWav(dir.path / "missing.wav"); }).empty());
}

// MARK: Sync

TEST("loudnessEnvelope is the RMS of each whole frame") {
    const std::vector<float> samples = {1, 1, 1, 1, 0.5f, -0.5f, 0.5f, -0.5f, 3, 4, 0, 0, 0, 0, 0, 0, 7};
    const auto envelope = vl::loudnessEnvelope(samples, 4);
    CHECK(envelope.size() == 4);
    CHECK_NEAR(envelope[0], 1, 1e-7);
    CHECK_NEAR(envelope[1], 0.5, 1e-7);
    CHECK_NEAR(envelope[2], 2.5, 1e-7);
    CHECK(envelope[3] == 0);
    CHECK(vl::loudnessEnvelope(samples, 18).empty());
}

TEST("bestLag finds a known shift, with camera_t = screen_t + offset") {
    Random r(7);
    std::vector<double> screen(6000);
    for (double& v : screen) v = r.next();

    // The camera hears everything 350 frames later.
    std::vector<double> late(6000);
    for (size_t k = 0; k < late.size(); k++) late[k] = k >= 350 ? screen[k - 350] : r.next();
    auto lag = vl::bestLag(late, screen, 3000, 2000);
    CHECK(lag.has_value());
    if (lag) {
        CHECK_NEAR(lag->lag, 350, 0.05);
        CHECK_NEAR(lag->correlation, 1, 1e-9);
    }

    // And 200 frames early.
    std::vector<double> early(6000);
    for (size_t k = 0; k < early.size(); k++) early[k] = k + 200 < screen.size() ? screen[k + 200] : r.next();
    lag = vl::bestLag(early, screen, 3000, 2000);
    CHECK(lag.has_value());
    if (lag) CHECK_NEAR(lag->lag, -200, 0.05);
}

TEST("bestLag gives nothing without enough overlap or any change in level") {
    Random r(11);
    std::vector<double> a(1000), b(1000);
    for (double& v : a) v = r.next();
    for (double& v : b) v = r.next();
    CHECK(!vl::bestLag(a, b, 3000, 2000));
    CHECK(vl::bestLag(a, b, 100, 900).has_value());
    const std::vector<double> flat(5000, 0.25);
    CHECK(!vl::bestLag(flat, flat, 100, 2000));
}

TEST("measureSync lines up a noise-burst recording delayed by 0.35 s") {
    TempDir dir;
    Random r(3);
    const int rate = 16000;
    const auto screen = bursts(r, rate, 8);
    std::vector<double> camera(screen.size());
    const size_t delay = static_cast<size_t>(0.35 * rate);
    for (size_t k = 0; k < camera.size(); k++) {
        camera[k] = (k >= delay ? 0.6 * screen[k - delay] : 0.0) + 0.005 * r.signedNext();
    }
    writeBytes(dir.path / "screen.wav", wavBytes(toPcm(screen)));
    writeBytes(dir.path / "camera.wav", wavBytes(toPcm(camera)));

    auto sync = vl::measureSync(dir.path / "camera.wav", dir.path / "screen.wav");
    CHECK(sync.method == "audio");
    CHECK_NEAR(sync.offset, 0.35, 0.002);
    CHECK(sync.confidence > 0.8);
    CHECK(!sync.note);

    // Swapped round, the offset turns negative.
    sync = vl::measureSync(dir.path / "screen.wav", dir.path / "camera.wav");
    CHECK(sync.method == "audio");
    CHECK_NEAR(sync.offset, -0.35, 0.002);
}

TEST("measureSync on unrelated, silent or short sound") {
    TempDir dir;
    Random r(5);
    std::vector<double> a(16000 * 4), b(16000 * 4);
    for (double& v : a) v = 0.3 * r.signedNext();
    for (double& v : b) v = 0.3 * r.signedNext();
    writeBytes(dir.path / "a.wav", wavBytes(toPcm(a)));
    writeBytes(dir.path / "b.wav", wavBytes(toPcm(b)));
    // Swift still calls this "audio", just with a low confidence.
    auto sync = vl::measureSync(dir.path / "a.wav", dir.path / "b.wav");
    CHECK(sync.method == "audio");
    CHECK(sync.confidence < 0.2);

    writeBytes(dir.path / "silent.wav", wavBytes(std::vector<std::int16_t>(16000 * 4, 0)));
    sync = vl::measureSync(dir.path / "silent.wav", dir.path / "silent.wav");
    CHECK(sync.method == "none");
    CHECK(sync.offset == 0);
    CHECK(sync.confidence == 0);
    CHECK(sync.note == "the two sound tracks are silent or too short to match");

    writeBytes(dir.path / "short.wav", wavBytes(toPcm(std::vector<double>(a.begin(), a.begin() + 16000))));
    sync = vl::measureSync(dir.path / "short.wav", dir.path / "short.wav");
    CHECK(sync.method == "none");
}

// MARK: events.jsonl

TEST("readEvents reads every kind of line and skips a cut-off last one") {
    TempDir dir;
    writeBytes(dir.path / "events.jsonl",
               R"({"type":"start","t":0,"title":"  My\nfirst  take ","wall":"2026-10-08T10:00:00Z","screen":"",)"
               R"("extraMics":[{"file":"mic-2.m4a","name":"Phone"},{"file":"mic-3.m4a"}],"videoMic":"mic-2.m4a"})" "\n"
               R"({"type":"mic-start","t":1,"file":"mic-2.m4a","at":1.25})" "\n"
               R"({"type":"mic-start","t":1,"file":"mic-3.m4a"})" "\n"
               R"({"type":"mute","t":2.5,"file":"mic-2.m4a","on":true,"by":"phone"})" "\n"
               R"({"type":"mute","t":3,"file":"mic-2.m4a","on":false})" "\n"
               R"({"type":"screen-start","t":4})" "\n"
               R"({"type":"screen-start","t":9})" "\n"
               R"({"type":"sound","t":5,"on":true,"from":"Safari"})" "\n"
               R"({"type":"sound","t":6,"on":false})" "\n"
               R"({"type":"show","t":4,"what":"screen"})" "\n"
               R"({"type":"show","t":7,"what":"me"})" "\n"
               R"({"type":"card","t":10,"section":"Intro"})" "\n"
               R"({"type":"card","t":12,"section":" \n "})" "\n"
               R"({"type":"app","t":11,"name":"Safari"})" "\n"
               R"({"type":"something-new","t":1})" "\n"
               R"({"type":"stop","t":20})" "\n"
               "\n"
               " \t \n"
               R"({"type":"card","t":21,"sect)");
    const auto events = vl::readEvents(dir.path / "events.jsonl");
    CHECK(events.has_value());
    if (!events) return;
    CHECK(events->title == "My first  take");
    CHECK(events->wall == "2026-10-08T10:00:00Z");
    CHECK(events->cameraFirst);
    CHECK(events->micNames.size() == 2);
    CHECK(events->micNames.at("mic-2.m4a") == "Phone");
    CHECK(events->micNames.at("mic-3.m4a") == "mic-3.m4a");
    CHECK(events->videoMic == "mic-2.m4a");
    CHECK(events->micStarts.size() == 1);
    CHECK(events->micStarts.at("mic-2.m4a") == 1.25);
    CHECK(events->mutes.size() == 2);
    if (events->mutes.size() == 2) {
        CHECK(events->mutes[0].t == 2.5 && events->mutes[0].file == "mic-2.m4a");
        CHECK(events->mutes[0].on && events->mutes[0].byPhone);
        CHECK(!events->mutes[1].on && !events->mutes[1].byPhone);
    }
    CHECK(events->screenShared == 4.0);
    CHECK(events->sounds.size() == 2);
    if (events->sounds.size() == 2) {
        CHECK(events->sounds[0].t == 5 && events->sounds[0].on && events->sounds[0].from == "Safari");
        CHECK(!events->sounds[1].on && events->sounds[1].from == "every app");
    }
    CHECK(events->shows.size() == 2);
    if (events->shows.size() == 2) CHECK(events->shows[0].screen && events->shows[0].t == 4 && !events->shows[1].screen);
    CHECK(events->cards.size() == 1);
    if (!events->cards.empty()) CHECK(events->cards[0].t == 10 && events->cards[0].section == "Intro");
    CHECK(events->apps.size() == 1);
    if (!events->apps.empty()) CHECK(events->apps[0].t == 11 && events->apps[0].name == "Safari");
    CHECK(events->stopTime == 20.0);
    CHECK(events->skippedLines == 1);
}

TEST("readEvents: missing file, bad lines, CRLF, and Foundation's JSON quirks") {
    TempDir dir;
    CHECK(!vl::readEvents(dir.path / "missing.jsonl"));
    CHECK(!vl::readEvents(dir.path));

    writeBytes(dir.path / "events.jsonl",
               std::string(R"({"type":"start","title":"  Hello World 　","screen":"screen.mov",)"
                           R"("wall":"a\r\nb","extraMics":[{"file":"mic-2.m4a"},3]})" "\r\n"
                           R"({"t":3})" "\n"
                           "[1,2]\n"
                           R"({"type":5})" "\n"
                           "\"text\"\n"
                           R"({"type":"stop"} trailing)" "\n"
                           R"({"type":"card","t":1,"section":"First","section":"Second"})" "\n"
                           R"({"type":"sound","t":true,"on":1})" "\n"
                           R"({"type":"sound","t":2,"on":2})" "\n"
                           R"({"type":"sound","t":3,"on":"yes"})" "\n"
                           R"({"type":"mute","t":4.5,"file":" mic-2.m4a ","on":1.0,"by":" phone"})" "\n"
                           R"({"type":"app","name":"Keynote"})" "\n"
                           R"({"type":"stop","t":9})") +
                   std::string("\0\r\n", 3));
    const auto events = vl::readEvents(dir.path / "events.jsonl");
    CHECK(events.has_value());
    if (!events) return;
    CHECK(events->title == "Hello World");
    CHECK(events->wall == "a  b");
    CHECK(!events->cameraFirst);
    CHECK(events->micNames.empty());
    CHECK(events->skippedLines == 5);
    CHECK(events->cards.size() == 1);
    if (!events->cards.empty()) CHECK(events->cards[0].section == "First");
    CHECK(events->sounds.size() == 3);
    if (events->sounds.size() == 3) {
        CHECK(events->sounds[0].t == 1 && events->sounds[0].on);
        CHECK(!events->sounds[1].on);
        CHECK(!events->sounds[2].on);
    }
    CHECK(events->mutes.size() == 1);
    if (!events->mutes.empty()) CHECK(events->mutes[0].file == "mic-2.m4a" && events->mutes[0].on && events->mutes[0].byPhone);
    CHECK(events->apps.size() == 1);
    if (!events->apps.empty()) CHECK(events->apps[0].t == 0);
    CHECK(events->stopTime == 9.0);
    CHECK(!events->screenShared);
}

// MARK: Chapters

TEST("rawChapters: prompter cards when there are any, otherwise app switches") {
    vl::RecordingEvents events;
    events.apps = {{5, "Safari"}, {20, "Keynote"}, {25, "Keynote"}, {30, "Safari"}};
    auto raw = vl::rawChapters(events);
    CHECK(raw.source == "app switches");
    CHECK(describe(raw.chapters) == "5:Safari 20:Keynote 30:Safari");

    events.cards = {{30, "B"}, {0, "A"}, {40, "B"}, {50, "C"}, {50, "D"}};
    raw = vl::rawChapters(events);
    CHECK(raw.source == "prompter sections");
    CHECK(describe(raw.chapters) == "0:A 30:B 50:C 50:D");

    CHECK(vl::rawChapters(vl::RecordingEvents{}).chapters.empty());
}

TEST("youTubeChapters: 00:00 first, at least 3, each at least 10 s") {
    using C = std::vector<vl::Chapter>;
    CHECK(describe(vl::youTubeChapters(C{{5, "A"}, {30, "B"}, {60, "C"}}, 100)) == "0:A 30:B 60:C");
    CHECK(vl::youTubeChapters(C{{0, "A"}, {30, "B"}}, 100).empty());
    CHECK(vl::youTubeChapters(C{}, 100).empty());
    // Past the end: dropped.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {60, "C"}, {100, "D"}, {120, "E"}}, 100)) == "0:A 30:B 60:C");
    CHECK(vl::youTubeChapters(C{{200, "A"}}, 100).empty());
    // A short one folds into the one before it.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {35, "C"}, {60, "D"}}, 100)) == "0:A 35:C 60:D");
    // A detour between two parts of the same section disappears and the section joins back up.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {33, "A"}, {60, "C"}, {80, "D"}}, 100)) == "0:A 60:C 80:D");
    // A short first one folds into the one after it, which then starts at 00:00.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {5, "B"}, {40, "C"}, {70, "D"}}, 100)) == "0:B 40:C 70:D");
    // The shortest goes first, which can leave the next one long enough.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {20, "B"}, {28, "C"}, {31, "D"}, {50, "E"}}, 100)) == "0:A 20:B 31:D 50:E");
    // The last one is measured against the end, and only when there is an end.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {60, "C"}, {95, "D"}}, 100)) == "0:A 30:B 60:C");
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {60, "C"}, {95, "D"}}, std::nullopt)) == "0:A 30:B 60:C 95:D");
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {30, "B"}, {60, "C"}, {65, "D"}}, std::nullopt)) == "0:A 30:B 65:D");
    // Equal shortest: the earlier goes.
    CHECK(describe(vl::youTubeChapters(C{{0, "A"}, {20, "B"}, {25, "C"}, {40, "D"}, {45, "E"}, {70, "F"}}, 100)) ==
          "0:A 25:C 45:E 70:F");
}

TEST("chaptersText writes clock times and no em dashes") {
    const std::vector<vl::Chapter> chapters = {{0, "Intro"}, {75.9, "Part \xE2\x80\x94 two"}, {3661, "End\xE2\x80\x94game"}};
    CHECK(vl::chaptersText(chapters) == "00:00 Intro\n01:15 Part, two\n1:01:01 End, game\n");
    CHECK(vl::chaptersText({}).empty());
}
