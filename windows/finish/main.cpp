// vidlark-finish <recording folder> [--no-transcribe] [--no-chapters] [--no-video] [--model <path to ggml model>]
// stdout carries only progress for the app: "STEP n/total ...", then "DONE <report.md>" or "FAIL <reason>".
// Port of Sources/vidlark-finish/main.swift. The camera files need no tidying here: the Windows app
// writes them without the padding AVCaptureMovieFileOutput adds on a Mac.

#include "audio.h"
#include "chapters.h"
#include "compose.h"
#include "events.h"
#include "report.h"
#include "support.h"
#include "transcript.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <random>

#ifdef _WIN32
#include <windows.h>
#endif

using namespace vl;

namespace {

fs::path workDir;

[[noreturn]] void finish(int code) {
    std::fflush(stdout);
    if (!workDir.empty()) {
        std::error_code ec;
        fs::remove_all(workDir, ec);
    }
    std::exit(code);
}

[[noreturn]] void fail(const std::string& reason) {
    std::printf("FAIL %s\n", noEmDash(reason).c_str());
    finish(1);
}

const char* usage = "usage: vidlark-finish <recording folder> [--no-transcribe] [--no-chapters] [--no-video] [--model <path>]";

bool present(const fs::path& path) {
    std::error_code ec;
    return fs::exists(path, ec);
}

std::optional<SyncResult> trySync(const fs::path& cameraWav, const fs::path& otherWav, double maxLagSeconds = 3) {
    try {
        return measureSync(cameraWav, otherWav, maxLagSeconds);
    } catch (...) {
        return std::nullopt;
    }
}

SyncResult none(const std::string& note) { return SyncResult{0, "none", 0, note}; }

std::vector<std::string> arguments(int argc, char** argv) {
    std::vector<std::string> args;
#ifdef _WIN32
    // The narrow argv is in the old code page; folder names can hold any letter, so read the wide one.
    int count = 0;
    LPWSTR* wide = CommandLineToArgvW(GetCommandLineW(), &count);
    for (int i = 0; i < count; i++) args.push_back(utf8(fs::path(wide[i])));
    LocalFree(wide);
    (void)argc;
    (void)argv;
#else
    for (int i = 0; i < argc; i++) args.push_back(argv[i]);
#endif
    return args;
}

}  // namespace

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IOLBF, 4096);
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
    std::setvbuf(stdout, nullptr, _IONBF, 0);  // Windows has no line buffering: write each line at once
#endif

    std::optional<std::string> folderArg;
    bool transcribeWanted = true, chaptersWanted = true, videoAllowed = true;
    std::optional<std::string> modelOverride;
    auto argv8 = arguments(argc, argv);
    for (size_t i = 1; i < argv8.size(); i++) {
        const std::string& arg = argv8[i];
        if (arg == "--no-transcribe") {
            transcribeWanted = false;
        } else if (arg == "--no-chapters") {
            chaptersWanted = false;
        } else if (arg == "--no-video") {
            videoAllowed = false;
        } else if (arg == "--model") {
            if (++i >= argv8.size()) fail(usage);
            modelOverride = argv8[i];
        } else if (arg == "-h" || arg == "--help") {
            std::cerr << usage << "\n";
            return 0;
        } else {
            if ((!arg.empty() && arg[0] == '-') || folderArg) fail(usage);
            folderArg = arg;
        }
    }
    if (!folderArg) fail(usage);

    const fs::path folder = fs::absolute(pathFromUtf8(*folderArg)).lexically_normal();
    auto file = [&](const std::string& name) { return folder / pathFromUtf8(name); };

    // video.mp4 is made whenever there is a screen to switch to, or another mic was picked for its sound.
    const auto earlyEvents = readEvents(file("events.jsonl"));
    std::optional<std::string> pickedMic;
    if (earlyEvents && earlyEvents->videoMic && present(file(*earlyEvents->videoMic))) pickedMic = earlyEvents->videoMic;
    const bool hasScreen = present(file("screen.mov"));
    const bool videoWanted = videoAllowed && (hasScreen || pickedMic);
    const int totalSteps = (transcribeWanted ? 6 : 4) - (chaptersWanted ? 0 : 1) + (videoWanted ? 1 : 0);
    int stepNumber = 0;
    auto step = [&](const std::string& words) {
        stepNumber++;
        std::printf("STEP %d/%d %s\n", stepNumber, totalSteps, words.c_str());
        std::fflush(stdout);
    };

    try {
        std::error_code ec;
        if (!fs::is_directory(folder, ec)) throw FinishError("folder not found: " + utf8(folder));
        const fs::path cameraPath = file("camera.mov");
        const fs::path screenPath = file("screen.mov");
        if (!present(cameraPath)) throw FinishError("camera.mov not found in " + utf8(folder));
        const fs::path ffmpeg = tools::require("ffmpeg");
        const fs::path ffprobe = tools::require("ffprobe");
        std::mt19937_64 random{std::random_device{}()};
        const fs::path work = fs::temp_directory_path() / pathFromUtf8(format("vidlark-finish-%016llx", (unsigned long long)random()));
        fs::create_directories(work);
        workDir = work;

        const auto events = readEvents(file("events.jsonl"));

        // 1. Audio
        step("Taking the sound out of the videos");
        MediaInfo camera;
        try {
            camera = probeMedia(ffprobe, cameraPath);
        } catch (const FinishError& error) {
            throw FinishError(std::string("camera.mov could not be read: ") + error.what());
        }
        if (!camera.hasAudio) throw FinishError("camera.mov has no sound track, so there is nothing to sync or transcribe");
        const fs::path camera16k = work / "camera16k.wav";
        try {
            extractAudio(ffmpeg, cameraPath, {{file("mic.wav"), 48000}, {camera16k, 16000}});
        } catch (const FinishError& error) {
            throw FinishError(std::string("could not take the sound out of camera.mov: ") + error.what());
        }
        const WavInfo cameraWavInfo = readWavInfo(readFile(camera16k));
        const double cameraDuration = camera.duration.value_or(cameraWavInfo.duration());

        std::optional<double> screenDuration;
        std::optional<std::string> screenNote;
        std::string screenProblem = "screen.mov was not found";
        std::optional<fs::path> screen16k;
        if (!present(screenPath)) {
            screenNote = "not found";
            if (events && events->cameraFirst) {
                screenNote = "none, the screen was not shared in this take";
                screenProblem = "the screen was not shared in this take";
            }
        } else {
            try {
                auto screen = probeMedia(ffprobe, screenPath);
                screenDuration = screen.duration;
                if (screen.hasAudio) {
                    fs::path wav = work / "screen16k.wav";
                    extractAudio(ffmpeg, screenPath, {{wav, 16000}}, std::nullopt, 130);
                    screen16k = wav;
                } else {
                    screenNote = clock(screen.duration.value_or(0)) + ", with no sound track";
                    screenProblem = "screen.mov has no sound track";
                }
            } catch (const FinishError& error) {
                screenNote = std::string("could not be read (") + error.what() + ")";
                screenProblem = "screen.mov could not be read";
            }
        }

        // 2. Sync
        step("Lining up the camera and the screen");
        SyncResult sync = none(screenProblem);
        if (screen16k && events && events->screenShared && *events->screenShared > 3) {
            // Shared in the middle of the take: match the screen against the camera's sound from just
            // before the share, then count back to the start of camera.mov.
            const double shared = *events->screenShared;
            const double from = std::max(0.0, shared - 2.5);
            const fs::path part = work / "camera16k-shared.wav";
            try {
                extractAudio(ffmpeg, cameraPath, {{part, 16000}}, from, 130);
                auto found = measureSync(part, *screen16k, 5);
                sync = SyncResult{found.method == "audio" ? found.offset + from : shared, found.method, found.confidence, found.note};
            } catch (...) {
                sync = SyncResult{shared, "none", 0, "the screen sound could not be read"};
            }
        } else if (screen16k) {
            sync = trySync(camera16k, *screen16k).value_or(none("the screen sound could not be read"));
        }

        // Extra cameras carry the same mic, so each lines up with camera.mov by sound.
        std::vector<ExtraCameraSync> extraCameras;
        for (int n = 2; n <= 9; n++) {
            const std::string name = format("camera-%d.mov", n);
            const fs::path path = file(name);
            if (!present(path)) continue;
            ExtraCameraSync entry{name, std::nullopt, none(name + " could not be read")};
            try {
                auto info = probeMedia(ffprobe, path);
                entry.duration = info.duration;
                if (!info.hasAudio) {
                    entry.sync = none(name + " has no sound track");
                } else {
                    const fs::path wav = work / pathFromUtf8(format("camera%d-16k.wav", n));
                    try {
                        extractAudio(ffmpeg, path, {{wav, 16000}}, std::nullopt, 130);
                        entry.sync = trySync(camera16k, wav).value_or(none("the sound in " + name + " could not be read"));
                    } catch (...) {
                        entry.sync = none("the sound in " + name + " could not be read");
                    }
                }
            } catch (...) {
            }
            extraCameras.push_back(entry);
        }

        // Extra mics: each lines up with camera.mov by sound when its sound matches the main mic's well,
        // and otherwise (a phone far from the main mic, a mic muted most of the take) by the computer's
        // clock, from when its file began.
        std::vector<ExtraMicSync> extraMics;
        for (int n = 2; n <= 9; n++) {
            const std::string name = format("mic-%d.m4a", n);
            const fs::path path = file(name);
            if (!present(path)) continue;
            std::optional<SyncResult> byClock;
            if (events) {
                if (auto it = events->micStarts.find(name); it != events->micStarts.end()) {
                    byClock = SyncResult{it->second, "clock", 0,
                                         std::string("its sound did not match the main mic's closely enough, so it is lined up by the ") + computerName + "'s clock"};
                }
            }
            std::optional<std::string> micName;
            if (events) {
                if (auto it = events->micNames.find(name); it != events->micNames.end()) micName = it->second;
            }
            ExtraMicSync entry{name, micName, std::nullopt, byClock.value_or(none(name + " could not be read"))};
            try {
                auto info = probeMedia(ffprobe, path);
                entry.duration = info.duration;
                const fs::path wav = work / pathFromUtf8(format("mic%d-16k.wav", n));
                try {
                    extractAudio(ffmpeg, path, {{wav, 16000}}, std::nullopt, 130);
                    if (auto found = trySync(camera16k, wav);
                        found && found->method == "audio" && (found->confidence >= 0.6 || !byClock)) {
                        entry.sync = *found;
                    }
                } catch (...) {
                }
            } catch (...) {
            }
            extraMics.push_back(entry);
        }
        // A mic lined up by sound shows how far the clock's word is from the truth on this computer (the
        // camera's first frame is noted a moment off). That correction goes to the ones lined up by clock.
        std::vector<double> gaps;
        for (const auto& mic : extraMics) {
            if (mic.sync.method != "audio" || mic.sync.confidence < 0.8 || !events) continue;
            if (auto it = events->micStarts.find(mic.file); it != events->micStarts.end()) gaps.push_back(mic.sync.offset - it->second);
        }
        std::sort(gaps.begin(), gaps.end());
        if (!gaps.empty() && std::fabs(gaps[gaps.size() / 2]) < 0.5) {
            const double correction = gaps[gaps.size() / 2];
            for (auto& mic : extraMics) {
                if (mic.sync.method == "clock") mic.sync.offset += correction;
            }
        }

        std::string syncJSON = "{\"screenOffsetSec\":" + jsonNumber(sync.offset, 4) + ",\"method\":" + jsonString(sync.method) +
                               ",\"confidence\":" + jsonNumber(sync.confidence);
        auto syncItems = [](const auto& list) {
            std::string items;
            for (const auto& entry : list) {
                if (!items.empty()) items += ",";
                items += "{\"file\":" + jsonString(entry.file) + ",\"offsetSec\":" + jsonNumber(entry.sync.offset, 4) +
                         ",\"method\":" + jsonString(entry.sync.method) + ",\"confidence\":" + jsonNumber(entry.sync.confidence) + "}";
            }
            return items;
        };
        if (!extraCameras.empty()) syncJSON += ",\"cameras\":[" + syncItems(extraCameras) + "]";
        if (!extraMics.empty()) syncJSON += ",\"mics\":[" + syncItems(extraMics) + "]";
        writeText(syncJSON + "}\n", file("sync.json"));

        // 3 and 4. Transcript and retakes
        TranscriptOutcome transcript;
        std::optional<std::vector<Retake>> retakes;
        if (transcribeWanted) {
            step("Writing the transcript");
            fs::remove(file("words.json"), ec);
            fs::remove(file("retakes.json"), ec);
            std::optional<std::vector<Word>> words;
            const auto model = findModel(modelOverride);
            const auto whisper = tools::find("whisper-cli");
            if (whisper && model.path) {
                const auto started = std::chrono::steady_clock::now();
                try {
                    auto result = transcribe(*whisper, *model.path, camera16k, work);
                    writeText(wordsJSON(result), file("words.json"));
                    transcript.kind = TranscriptOutcome::Kind::done;
                    transcript.wordCount = static_cast<int>(result.size());
                    transcript.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
                    words = result;
                } catch (const FinishError& error) {
                    transcript.kind = TranscriptOutcome::Kind::failed;
                    transcript.reason = error.what();
                }
            } else if (!whisper) {
                transcript.kind = TranscriptOutcome::Kind::failed;
                transcript.reason = "whisper-cli not found (looked in " + tools::searchDirsText() + " and PATH)";
            } else {
                std::string searched;
                for (const auto& place : model.searched) searched += (searched.empty() ? "" : ", ") + place;
                transcript.kind = TranscriptOutcome::Kind::failed;
                transcript.reason = "the whisper model was not found, looked for " + searched;
            }

            step("Looking for retakes");
            if (words) {
                auto found = findRetakes(*words);
                writeText(retakesJSON(found), file("retakes.json"));
                retakes = found;
            }
        }

        // 5. Chapters
        std::vector<Chapter> chapters;
        std::string chapterSource = "prompter sections";
        int candidates = 0;
        if (chaptersWanted) step("Making chapters");
        if (chaptersWanted && events) {
            auto raw = rawChapters(*events);
            chapterSource = raw.source;
            candidates = static_cast<int>(raw.chapters.size());
            chapters = youTubeChapters(raw.chapters, cameraDuration);
        }
        if (chaptersWanted) writeText(chaptersText(chapters), file("chapters.txt"));

        // 6. The finished video, following each click of Me or Screen
        std::optional<ComposeResult> composed;
        std::optional<std::string> composeProblem;
        // The sound of the video: the mic picked before the take, when it could be lined up.
        std::optional<SoundSource> videoSound;
        std::optional<std::string> videoSoundNote;
        if (pickedMic) {
            auto mic = std::find_if(extraMics.begin(), extraMics.end(), [&](const auto& m) { return m.file == *pickedMic; });
            if (mic != extraMics.end() && mic->sync.method != "none") {
                videoSound = SoundSource{file(*pickedMic), mic->sync.offset};
            } else {
                videoSoundNote = *pickedMic + " could not be lined up with the camera, so the video has the main mic's sound";
            }
        }
        if (videoWanted) {
            step("Making the video");
            const bool late = events && events->cameraFirst;
            try {
                if (hasScreen) {
                    composed = composeVideo(ffmpeg, ffprobe, cameraPath, screenPath, sync.offset, late, videoSound, file("video.mp4"), work);
                } else if (videoSound) {
                    composed = cameraWithSound(ffmpeg, ffprobe, cameraPath, *videoSound, file("video.mp4"));
                }
            } catch (const std::exception& error) {
                composeProblem = error.what();
            }
        }

        // 7. Report
        step("Writing the report");
        std::string title = events && events->title ? *events->title : utf8(folder.filename());
        if (!(events && events->title) && utf8(folder.filename()).rfind("recording-", 0) == 0) {
            title = utf8(folder.parent_path().filename()) + ", " + utf8(folder.filename());
        }
        ReportInput input;
        input.folder = folder;
        input.title = title;
        if (events) input.wall = events->wall;
        input.cameraDuration = cameraDuration;
        input.screenDuration = screenDuration;
        input.screenNote = screenNote;
        input.sync = sync;
        input.extraCameras = extraCameras;
        input.extraMics = extraMics;
        if (videoSound) input.videoMic = pickedMic;
        input.videoSoundNote = videoSoundNote;
        input.transcript = transcript;
        input.retakes = retakes;
        input.chapters = chapters;
        input.chapterSource = chapterSource;
        input.candidateChapters = candidates;
        input.chaptersWanted = chaptersWanted;
        input.events = events;
        input.video = composed;
        input.videoProblem = composeProblem;
        input.videoWanted = videoWanted;
        writeText(buildReport(input), file("report.md"));

        if (transcript.kind == TranscriptOutcome::Kind::failed) {
            fail("transcript failed: " + transcript.reason + ". The other files and report.md were written.");
        }
        std::printf("DONE %s\n", utf8(file("report.md")).c_str());
        finish(0);
    } catch (const std::exception& error) {
        fail(error.what());
    }
}
