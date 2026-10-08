// Tests for the transcript, retakes and report.
// The expected text was checked against the Swift originals (Transcript.swift, Report.swift) on a Mac.
#include "check.h"
#include "report.h"
#include "transcript.h"

#include <ctime>
#include <fstream>
#include <random>

namespace {

using nlohmann::json;

// Two segments as whisper-cli -ojf writes them, with t_dtw on every token.
const json whisperSegments = json::parse(R"([
  {"offsets": {"from": 0, "to": 3000}, "text": " Hello world, retake.",
   "tokens": [
     {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "id": 50364, "p": 0.9, "t_dtw": -1},
     {"text": " Hello", "offsets": {"from": 0, "to": 500}, "id": 2425, "p": 0.9, "t_dtw": 40},
     {"text": " world", "offsets": {"from": 500, "to": 900}, "id": 1002, "p": 0.9, "t_dtw": 85},
     {"text": ",", "offsets": {"from": 900, "to": 950}, "id": 11, "p": 0.9, "t_dtw": 90},
     {"text": " re", "offsets": {"from": 1200, "to": 1400}, "id": 319, "p": 0.9, "t_dtw": 135},
     {"text": "take", "offsets": {"from": 1400, "to": 1700}, "id": 1691, "p": 0.9, "t_dtw": 160},
     {"text": ".", "offsets": {"from": 1700, "to": 1750}, "id": 13, "p": 0.9, "t_dtw": 170},
     {"text": "[_TT_150]", "offsets": {"from": 3000, "to": 3000}, "id": 50514, "p": 0.9, "t_dtw": -1}]},
  {"offsets": {"from": 3000, "to": 6000}, "text": " [BLANK_AUDIO] So",
   "tokens": [
     {"text": " [BLANK_AUDIO]", "offsets": {"from": 3000, "to": 4000}, "id": 1, "p": 0.9, "t_dtw": 200},
     {"text": " So", "offsets": {"from": 5000, "to": 5300}, "id": 407, "p": 0.9, "t_dtw": 528}]}
])");

const char* const wordsWithoutDTW =
    "[\n"
    "{\"word\":\"Hello\",\"start\":0.000,\"end\":0.500},\n"
    "{\"word\":\"world,\",\"start\":0.500,\"end\":0.900},\n"
    "{\"word\":\"retake.\",\"start\":1.200,\"end\":1.700},\n"
    "{\"word\":\"So\",\"start\":5.000,\"end\":5.300}\n"
    "]\n";

// With DTW, "So" soaks up the pause after [BLANK_AUDIO] and is cut back to twice the median word length.
const char* const wordsWithDTW =
    "[\n"
    "{\"word\":\"Hello\",\"start\":0.000,\"end\":0.400},\n"
    "{\"word\":\"world,\",\"start\":0.400,\"end\":0.850},\n"
    "{\"word\":\"retake.\",\"start\":0.900,\"end\":1.600},\n"
    "{\"word\":\"So\",\"start\":3.880,\"end\":5.280}\n"
    "]\n";

std::vector<vl::Word> wordsOf(std::initializer_list<const char*> texts) {
    std::vector<vl::Word> words;
    double t = 0;
    for (const char* text : texts) {
        words.push_back({text, t, t + 0.5});
        t += 1;
    }
    return words;
}

fs::path makeTempFolder(const std::string& name) {
    std::random_device random;
    fs::path folder = fs::temp_directory_path() / (name + "-" + std::to_string(random()));
    fs::create_directories(folder);
    return folder;
}

void writeBytes(const fs::path& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

bool hasLine(const std::string& text, const std::string& line) {
    const auto lines = vl::splitLines(text);
    return std::find(lines.begin(), lines.end(), line) != lines.end();
}

// The line the report should print for a UTC time: en_GB "d MMM yyyy 'at' HH:mm" in the local zone.
std::string recordedLine(std::time_t t) {
    std::tm local{};
#ifdef _WIN32
    localtime_s(&local, &t);
#else
    localtime_r(&t, &local);
#endif
    static const char* const months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    return vl::format("Recorded %d %s %04d at %02d:%02d.", local.tm_mday, months[local.tm_mon], local.tm_year + 1900,
                      local.tm_hour, local.tm_min);
}

const std::string emDash = "\xE2\x80\x94";

}  // namespace

TEST("buildWords joins tokens into words, using the token offsets without DTW") {
    const auto words = vl::buildWords(whisperSegments, false);
    CHECK(words.size() == 4);
    CHECK(vl::wordsJSON(words) == wordsWithoutDTW);
}

TEST("buildWords uses t_dtw for word ends and caps a word stretched by a pause") {
    const auto words = vl::buildWords(whisperSegments, true);
    CHECK(vl::wordsJSON(words) == wordsWithDTW);
    CHECK(words.size() == 4 && words[3].word == "So");
    if (words.size() == 4) {
        CHECK_NEAR(words[3].start, 3.88, 1e-9);
        CHECK_NEAR(words[3].end, 5.28, 1e-9);
    }
}

TEST("buildWords follows Swift's Character rules for replacement characters and punctuation") {
    // A U+FFFD on its own goes; one followed by a combining mark is one Character to Swift and stays.
    // Punctuation-only tokens join the word before; bracketed words go.
    const auto token = [](const char* text, int from, int to) {
        return json{{"text", text}, {"offsets", {{"from", from}, {"to", to}}}};
    };
    const json tokens = json::array({token(" Hello", 0, 500), token("\xEF\xBF\xBD", 500, 600),
                                     token("\xEF\xBF\xBD\xCC\x81", 600, 700), token(" caf\xEF\xBF\xBD", 700, 900),
                                     token(" \xE2\x80\x93", 900, 1000), token(" \xE2\x80\xA6", 1000, 1100),
                                     token(" (laughs)", 1100, 1500), token(" ok", 1500, 1700)});
    const json segments = json::array({json{{"offsets", {{"from", 0}, {"to", 3000}}}, {"tokens", tokens}}});
    CHECK(vl::wordsJSON(vl::buildWords(segments, false)) ==
          "[\n"
          "{\"word\":\"Hello\xEF\xBF\xBD\xCC\x81\",\"start\":0.300,\"end\":0.700},\n"
          "{\"word\":\"caf\xE2\x80\x93\xE2\x80\xA6\",\"start\":0.700,\"end\":0.900},\n"
          "{\"word\":\"ok\",\"start\":1.500,\"end\":1.700}\n"
          "]\n");
}

TEST("buildWords reads whisper's fields the way the Swift casts them") {
    CHECK(vl::buildWords(json::array(), true).empty());
    // tokens that are not all dictionaries count as no tokens; a missing "to" falls back to "from".
    const json segments = json::parse(R"([
        {"offsets": {"from": 1000}, "tokens": [{"text": " lost"}, 5]},
        {"offsets": {"from": 2000}, "tokens": [{"text": " kept", "offsets": {"from": 2500}}, {"text": " too"}]}])");
    CHECK(vl::wordsJSON(vl::buildWords(segments, false)) ==
          "[\n{\"word\":\"kept\",\"start\":2.500,\"end\":2.500},\n{\"word\":\"too\",\"start\":2.500,\"end\":2.500}\n]\n");
}

TEST("wordsJSON and retakesJSON write the exact text") {
    CHECK(vl::wordsJSON({}) == "[]\n");
    CHECK(vl::retakesJSON({}) == "[]\n");
    CHECK(vl::wordsJSON({{"caf\xC3\xA9", -0.0001, 1.23456}, {"say \"hi\"", 2, 2.5}}) ==
          "[\n{\"word\":\"caf\xC3\xA9\",\"start\":0.000,\"end\":1.235},\n{\"word\":\"say \\\"hi\\\"\",\"start\":2.000,\"end\":2.500}\n]\n");
    CHECK(vl::retakesJSON({{1.25, "so \"this\" [RETAKE]"}, {61, "[RETAKE]"}}) ==
          "[\n{\"t\":1.250,\"context\":\"so \\\"this\\\" [RETAKE]\"},\n{\"t\":61.000,\"context\":\"[RETAKE]\"}\n]\n");
}

TEST("findRetakes hears retake and re take, ignoring case and punctuation") {
    auto found = vl::findRetakes(wordsOf({"So", "RE-TAKE!", "then", "Re,", "take.", "and", "retake"}));
    CHECK(found.size() == 3);
    if (found.size() == 3) {
        CHECK(found[0].t == 1 && found[0].context == "So [RETAKE]");
        CHECK(found[1].t == 3 && found[1].context == "So RE-TAKE! then [RETAKE]");
        CHECK(found[2].t == 6 && found[2].context == "So RE-TAKE! then Re, take. and [RETAKE]");
    }
    // At the very start there is nothing before it.
    found = vl::findRetakes(wordsOf({"Retake", "now"}));
    CHECK(found.size() == 1 && found[0].context == "[RETAKE]");
    // Swift lowercases the Kelvin sign to k, so this counts too.
    CHECK(vl::findRetakes(wordsOf({"RETA\xE2\x84\xAA" "E"})).size() == 1);
}

TEST("findRetakes leaves ordinary words alone") {
    CHECK(vl::findRetakes(wordsOf({"retaken", "retakes", "take", "re", "remake", "Re", "takes", "re", "retake2"})).size() == 1);
    CHECK(vl::findRetakes(wordsOf({"retaken", "retakes", "take", "re", "remake", "Re", "takes", "re"})).empty());
    CHECK(vl::findRetakes(wordsOf({"re", "\xC3\xA9take"})).empty());
}

TEST("findRetakes keeps the 12 words before as context") {
    auto words = wordsOf({"w1", "w2", "w3", "w4", "w5", "w6", "w7", "w8", "w9", "w10", "w11", "w12", "w13", "w14", "retake"});
    auto found = vl::findRetakes(words);
    CHECK(found.size() == 1);
    if (!found.empty()) {
        CHECK(found[0].context == "w3 w4 w5 w6 w7 w8 w9 w10 w11 w12 w13 w14 [RETAKE]");
        CHECK(found[0].t == 14);
    }
}

TEST("dtwPreset matches whisper.cpp's alignment heads from the model name") {
    CHECK(vl::dtwPreset("/x/ggml-large-v3-turbo-q5_0.bin") == std::optional<std::string>("large.v3.turbo"));
    CHECK(vl::dtwPreset("ggml-large-v3-turbo.bin") == std::optional<std::string>("large.v3.turbo"));
    CHECK(vl::dtwPreset("ggml-base.en.bin") == std::optional<std::string>("base.en"));
    CHECK(vl::dtwPreset("ggml-small.en-q5_1.bin") == std::optional<std::string>("small.en"));
    CHECK(vl::dtwPreset("ggml-medium-q8_0.bin") == std::optional<std::string>("medium"));
    CHECK(vl::dtwPreset("/a/b/ggml-tiny.en") == std::optional<std::string>("tiny"));
    CHECK(vl::dtwPreset("ggml-small.bin//") == std::optional<std::string>("small"));
    CHECK(vl::dtwPreset("ggml-tiny-q5-q8") == std::optional<std::string>("tiny"));
    CHECK(!vl::dtwPreset("ggml-large.bin"));
    CHECK(!vl::dtwPreset("model.bin"));
    CHECK(!vl::dtwPreset("GGML-tiny.bin"));
    CHECK(!vl::dtwPreset("ggml-tiny."));
    CHECK(!vl::dtwPreset("ggml-tiny-qx5"));
    CHECK(!vl::dtwPreset(""));
}

TEST("findModel uses an override as it is, and otherwise looks in the fixed folders") {
    auto search = vl::findModel(std::string("/no/such/model.bin"));
    CHECK(!search.path && search.searched == std::vector<std::string>{"/no/such/model.bin"});

    const fs::path folder = makeTempFolder("vidlark-model");
    const fs::path model = folder / "ggml-base.en.bin";
    writeBytes(model, "model");
    search = vl::findModel(vl::utf8(model));
    CHECK(search.path && *search.path == model);
    fs::remove_all(folder);

    search = vl::findModel(std::nullopt);
    const fs::path models = vl::recordingsRoot() / ".models";
#ifdef _WIN32
    CHECK(vl::utf8(vl::recordingsRoot()).find("Vidlark Recordings") != std::string::npos);
    CHECK(search.searched.size() == 4 || search.searched.size() == 2);
#else
    CHECK(vl::recordingsRoot() == "/Users/Shared/Vidlark Recordings");
    CHECK(search.searched.size() == 4);
    if (search.searched.size() == 4) {
        const std::string tail = "/.cache/whisper/ggml-large-v3-turbo-q5_0.bin";
        CHECK(search.searched[0].size() > tail.size() && search.searched[0].substr(search.searched[0].size() - tail.size()) == tail);
        CHECK(search.searched[1] == "/Users/Shared/Vidlark Recordings/.models/ggml-large-v3-turbo-q5_0.bin");
        CHECK(search.searched[3] == "/Users/Shared/Vidlark Recordings/.models/ggml-large-v3-turbo.bin");
    }
#endif
    CHECK(!search.searched.empty() && search.searched.back() == vl::utf8(models / "ggml-large-v3-turbo.bin"));
}

#ifndef _WIN32
TEST("transcribe runs whisper-cli with the Swift's arguments and reads its JSON") {
    const fs::path folder = makeTempFolder("vidlark-whisper");
    const fs::path fake = folder / "whisper-cli";
    writeBytes(fake,
               "#!/bin/sh\n"
               "dir=$(dirname \"$0\")\n"
               "printf '%s\\n' \"$@\" > \"$dir/args.txt\"\n"
               "while [ $# -gt 0 ]; do [ \"$1\" = \"-of\" ] && of=\"$2\"; shift; done\n"
               "[ -f \"$dir/out.json\" ] && cp \"$dir/out.json\" \"$of.json\"\n"
               "echo 'whisper_init: loading model' >&2\n"
               "echo 'error: the model could not be read' >&2\n"
               "exit \"$(cat \"$dir/status\")\"\n");
    fs::permissions(fake, fs::perms::owner_all);
    const fs::path work = folder / "work";
    fs::create_directories(work);
    const fs::path model = folder / "ggml-base.en.bin";
    const fs::path wav = folder / "camera16k.wav";

    // A split multi-byte character in a token, which the Swift repairs before parsing.
    std::string output = json{{"transcription", whisperSegments}}.dump();
    output.replace(output.find("\" So\""), 5, "\" So\xE2\x80\"");
    writeBytes(folder / "out.json", output);
    writeBytes(folder / "status", "0");
    const auto words = vl::transcribe(fake, model, wav, work);
    CHECK(vl::wordsJSON(words) == wordsWithDTW);
    const int threads = std::min(8, std::max(1, vl::processorCount()));
    const std::vector<std::string> expected = {"-m", vl::utf8(model), "-f", vl::utf8(wav), "-l", "en", "-ojf", "-of",
                                               vl::utf8(work / "whisper"), "-t", std::to_string(threads), "-dtw", "base.en", "-nfa"};
    CHECK(vl::splitLines(vl::readFile(folder / "args.txt")) == expected);

    // No DTW for a model whisper.cpp has no preset for.
    fs::remove(work / "whisper.json");
    CHECK(vl::wordsJSON(vl::transcribe(fake, folder / "model.bin", wav, work)) == wordsWithoutDTW);
    CHECK(vl::splitLines(vl::readFile(folder / "args.txt")).size() == 11);

    const auto failure = [&] {
        try {
            vl::transcribe(fake, model, wav, work);
        } catch (const vl::FinishError& error) {
            return std::string(error.what());
        }
        return std::string("no error");
    };
    writeBytes(folder / "status", "1");
    CHECK(failure() == "whisper-cli failed: error: the model could not be read");
    writeBytes(folder / "status", "0");
    fs::remove(work / "whisper.json");
    fs::remove(folder / "out.json");
    CHECK(failure() == "whisper-cli failed: error: the model could not be read");
    writeBytes(folder / "out.json", "{\"transcription\": [1]}");
    CHECK(failure() == "could not read whisper-cli output");
    writeBytes(folder / "out.json", "not json");
    CHECK(failure() == "could not read whisper-cli output");
    fs::remove_all(folder);
}
#endif

TEST("buildReport writes every section as the Swift does") {
    const fs::path folder = makeTempFolder("vidlark-report");
    writeBytes(folder / "camera.mov", std::string(2'500'000, 'x'));
    writeBytes(folder / "chapters.txt", std::string(999, 'x'));
    writeBytes(folder / "sync.json", std::string(1600, 'x'));
    writeBytes(folder / "report.md", "old");
    writeBytes(folder / ".hidden", "x");

    vl::ReportInput r;
    r.folder = folder;
    r.title = "Amazon PPC basics";
    r.wall = "2026-10-07T12:00:00Z";
    r.cameraDuration = 125.3;
    r.screenDuration = 100.04;
    r.sync = {1.2345, "audio", 0.91, std::nullopt};
    r.extraCameras = {{"camera-2.mov", 120.5, {-0.75, "audio", 0.62, std::nullopt}}};
    r.extraMics = {{"mic-2.m4a", std::string("iPhone"), 118.0, {0.25, "audio", 0.85, std::nullopt}}};
    r.videoMic = "mic-2.m4a";
    r.transcript.kind = vl::TranscriptOutcome::Kind::done;
    r.transcript.wordCount = 321;
    r.transcript.seconds = 42.4;
    r.retakes = std::vector<vl::Retake>{{61.3, "so the next step is [RETAKE]"}};
    r.chapters = {{0, "Intro"}, {10, "Setting up " + emDash + " bids"}, {25, "Bids"}};
    r.chapterSource = "prompter sections";
    r.candidateChapters = 3;
    vl::RecordingEvents events;
    events.stopTime = 125.0;
    events.screenShared = 19.7;
    events.shows = {{0, false}, {10.2, true}, {25.9, false}};
    events.sounds = {{5, true, "Safari"}, {30, false, ""}};
    events.mutes = {{40, "mic-2.m4a", true, true}, {50.5, "mic-2.m4a", false, false}, {60, "mic-9.m4a", true, true}};
    r.events = events;
    r.video = vl::ComposeResult{125.25, 1920, 1080, 19.7};
    r.videoWanted = true;

    const std::string expected = "# Amazon PPC basics\n"
                                 "\n" +
                                 recordedLine(1791374400) + "\n" +
                                 "Folder: `" + vl::utf8(folder) + "`\n"
                                 "\n"
                                 "## Length\n"
                                 "\n"
                                 "- Camera (camera.mov): 02:05 (125.3 seconds)\n"
                                 "- Screen (screen.mov): 01:40 (100.0 seconds), shared 00:19 into the take\n"
                                 "- Extra camera (camera-2.mov): 02:00 (120.5 seconds)\n"
                                 "- Extra mic (mic-2.m4a, iPhone): 01:58 (118.0 seconds)\n"
                                 "\n"
                                 "## Sync\n"
                                 "\n"
                                 "The screen recording started 1.234 seconds after the camera.\n"
                                 "\n"
                                 "- Offset: 1.234 seconds (camera time = screen time + offset), saved in sync.json\n"
                                 "- Confidence: 0.91 (high)\n"
                                 "\n"
                                 "- camera-2.mov: offset -0.750 seconds (camera time = camera-2.mov time + offset), confidence 0.62 "
                                 "(medium, worth a quick check by eye), saved in sync.json\n"
                                 "\n"
                                 "## Microphones\n"
                                 "\n"
                                 "The video's sound is iPhone (mic-2.m4a). Every mic's file is in the folder, so another can be used in editing.\n"
                                 "\n"
                                 "- mic-2.m4a (iPhone): lined up by sound, offset 0.250 seconds (camera time = mic time + offset), "
                                 "confidence 0.85 (high)\n"
                                 "  - Muted at 00:40, on the phone: the file is silent until it was unmuted\n"
                                 "  - Unmuted at 00:50, from the " + std::string(vl::computerName) + "\n"
                                 "\n"
                                 "## Transcript\n"
                                 "\n"
                                 "321 words, saved in words.json (transcribed in 42 seconds).\n"
                                 "\n"
                                 "## Chapters\n"
                                 "\n"
                                 "Made from the prompter sections. Paste this into the YouTube description:\n"
                                 "\n"
                                 "```\n"
                                 "00:00 Intro\n"
                                 "00:10 Setting up, bids\n"
                                 "00:25 Bids\n"
                                 "```\n"
                                 "\n"
                                 "## Retakes\n"
                                 "\n"
                                 "\"Retake\" was said 1 time. Cut back to before each one:\n"
                                 "\n"
                                 "- 01:01 (61.3 s): so the next step is [RETAKE]\n"
                                 "\n"
                                 "## " + std::string(vl::computerName) + " sound\n"
                                 "\n"
                                 "The second sound track of screen.mov. Off means silence there.\n"
                                 "\n"
                                 "- 00:05 on, from Safari\n"
                                 "- 00:30 off\n"
                                 "\n"
                                 "## Video\n"
                                 "\n"
                                 "video.mp4 is the finished video: 02:05, 1920 by 1080. It is what was on the screen, with her camera "
                                 "across the whole screen for Me, and the sound from iPhone (mic-2.m4a).\n"
                                 "\n"
                                 "Until 00:19, before the screen was shared, it is camera.mov.\n"
                                 "\n"
                                 "- 00:00 Me\n"
                                 "- 00:10 Screen\n"
                                 "- 00:25 Me\n"
                                 "\n"
                                 "## Files\n"
                                 "\n"
                                 "- camera.mov (2.5 MB)\n"
                                 "- chapters.txt (999 bytes)\n"
                                 "- sync.json (2 KB)\n"
                                 "- report.md (this file)\n";
    const std::string report = vl::buildReport(r);
    CHECK(report == expected);
    CHECK(report.find(emDash) == std::string::npos);
    // The lines Tests/run_tests.sh greps for.
    CHECK(hasLine(report, "- 00:10 Screen"));
    CHECK(report.find("shared 00:19 into the take") != std::string::npos);

    // An extra camera that could not be matched, and a mic lined up by the clock.
    r.extraCameras = {{"camera-2.mov", std::nullopt, {0, "none", 0, std::nullopt}}};
    r.extraMics[0].sync = {1.5, "clock", 0, std::string("its sound was too quiet")};
    r.sync = {-0.0003, "audio", 0.42, std::nullopt};
    const std::string other = vl::buildReport(r);
    CHECK(hasLine(other, "- Extra camera (camera-2.mov): unknown"));
    CHECK(hasLine(other, "- camera-2.mov: not measured, because it has no sound to match. sync.json says offset 0."));
    CHECK(hasLine(other, "- mic-2.m4a (iPhone): lined up by the " + std::string(vl::computerName) + "'s clock, offset 1.500 seconds, because its sound was too quiet. "
                         "Check the lip sync by eye."));
    CHECK(hasLine(other, "The camera and the screen started at the same moment."));
    CHECK(hasLine(other, "- Offset: 0.000 seconds (camera time = screen time + offset), saved in sync.json"));
    CHECK(hasLine(other, "- Confidence: 0.42 (low, check the sync by eye before editing)"));
    fs::remove_all(folder);
}

TEST("buildReport says what was skipped when the transcript and chapters were not wanted") {
    const fs::path folder = makeTempFolder("vidlark-skipped");
    vl::ReportInput r;
    r.folder = folder;
    r.title = "Take";
    r.wall = "not a date";
    r.cameraDuration = 30.5;
    r.screenNote = "none, the screen was not shared in this take";
    r.chaptersWanted = false;
    vl::RecordingEvents events;
    events.skippedLines = 1;
    r.events = events;
    const std::string report = vl::buildReport(r);
    CHECK(hasLine(report, "Recorded not a date."));
    CHECK(hasLine(report, "The events log has no stop line, so the app probably closed or crashed during this take. "
                          "Everything saved up to that moment is used."));
    CHECK(hasLine(report, "1 damaged line was skipped in events.jsonl."));
    CHECK(hasLine(report, "- Screen (screen.mov): none, the screen was not shared in this take"));
    CHECK(hasLine(report, "Not measured, because there is no screen sound to match. sync.json says offset 0."));
    CHECK(hasLine(report, "Skipped (run without `--no-transcribe` to make words.json and retakes.json)."));
    CHECK(hasLine(report, "Skipped (the take was recorded with the transcript and chapters box unticked)."));
    CHECK(hasLine(report, "Not checked, because there is no transcript."));
    CHECK(hasLine(report, "No screen in this take, so camera.mov is the video."));
    CHECK(report.size() > 26 && report.substr(report.size() - 26) == "\n\n- report.md (this file)\n");
    CHECK(report.find(emDash) == std::string::npos);

    // Chapters wanted but none made, and a failed transcript.
    r.chaptersWanted = true;
    r.chapterSource = "app switches";
    r.transcript.kind = vl::TranscriptOutcome::Kind::failed;
    r.transcript.reason = "whisper-cli failed: out of memory";
    r.retakes = std::vector<vl::Retake>{};
    r.events.reset();
    r.videoWanted = true;
    std::string again = vl::buildReport(r);
    CHECK(hasLine(again, "There is no readable events.jsonl, so there are no chapters."));
    CHECK(hasLine(again, "Failed: whisper-cli failed: out of memory"));
    CHECK(hasLine(again, "None: there were no app switches to build chapters from. chapters.txt is empty."));
    CHECK(hasLine(again, "The word \"retake\" was not said."));
    CHECK(hasLine(again, "Not made (finished with --no-video)."));
    r.candidateChapters = 2;
    r.videoProblem = "ffmpeg failed";
    again = vl::buildReport(r);
    CHECK(hasLine(again, "None: YouTube needs at least 3 chapters of 10 seconds or more, and the app switches did not give that. "
                         "chapters.txt is empty."));
    CHECK(hasLine(again, "Not made, because ffmpeg failed. camera.mov and screen.mov are whole, so the video can still be edited from them."));
    fs::remove_all(folder);
}

TEST("buildReport reads the take's date in every form ISO8601DateFormatter takes") {
    vl::ReportInput r;
    r.folder = fs::path("no-such-folder-for-vidlark-tests");
    const auto recorded = [&](const std::string& wall) {
        r.wall = wall;
        return vl::splitLines(vl::buildReport(r))[2];
    };
    const std::string noon = recordedLine(1791374400);
    CHECK(recorded("2026-10-07T12:00:00Z") == noon);
    CHECK(recorded("2026-10-07T12:00:00.123Z") == noon);
    CHECK(recorded("2026-10-07T12:00:00.1234567Z") == noon);
    CHECK(recorded("2026-10-07T13:00:00+01:00") == noon);
    CHECK(recorded("2026-10-07T17:30:59.999+0530") == noon);
    CHECK(recorded("2026-10-07T07:00:00-05") == noon);
    CHECK(recorded(" 2026-10-07T12:00:00z junk") == noon);
    CHECK(recorded("2026-10-07T12:00:00 GMT") == noon);
    CHECK(recorded("2026-9-15T12:0:0Z") == recordedLine(1789473600));
    CHECK(recorded("2026-09-15T12:00:00Z").find(" Sep 2026 at ") != std::string::npos);  // en_GB on macOS says Sep, not Sept
    CHECK(recorded("2026-10-07 12:00:00Z") == "Recorded 2026-10-07 12:00:00Z.");
    CHECK(recorded("2026-10-07T12:00:00") == "Recorded 2026-10-07T12:00:00.");
    CHECK(recorded("2026-10-07T12:00Z") == "Recorded 2026-10-07T12:00Z.");
    CHECK(recorded("2026-13-07T12:00:00Z") == "Recorded 2026-13-07T12:00:00Z.");
    CHECK(recorded("2026-10-07T12:00:00.Z") == "Recorded 2026-10-07T12:00:00.Z.");
    CHECK(recorded("") == "Recorded .");
    CHECK(vl::splitLines(vl::buildReport(r))[3] == "Folder: `no-such-folder-for-vidlark-tests`");
}
