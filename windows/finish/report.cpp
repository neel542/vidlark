// report.md, the plain summary of a take. Port of Report.swift.

#include "report.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <system_error>

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace vl {

namespace {

std::string length(const std::optional<double>& seconds) {
    if (!seconds) return "unknown";
    return clock(*seconds) + " (" + format("%.1f", *seconds) + " seconds)";
}

// MARK: The date

// Days from 1970-01-01, proleptic Gregorian. A day past the end of its month runs on into the next,
// as ISO8601DateFormatter lets 30 February through as 2 March.
long long daysFromCivil(int y, int m, int d) {
    y -= m <= 2 ? 1 : 0;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const int yearOfEra = y - era * 400;
    const int dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    const int dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return static_cast<long long>(era) * 146097 + dayOfEra - 719468;
}

bool readNumber(const std::string& s, size_t& i, size_t minDigits, size_t maxDigits, int& value) {
    size_t count = 0;
    int n = 0;
    while (i < s.size() && count < maxDigits && s[i] >= '0' && s[i] <= '9') {
        n = n * 10 + (s[i] - '0');
        i++;
        count++;
    }
    value = n;
    return count >= minDigits;
}

bool readChar(const std::string& s, size_t& i, char c) {
    if (i < s.size() && s[i] == c) {
        i++;
        return true;
    }
    return false;
}

// The length of the white space ISO8601DateFormatter skips at s[i], or 0: ASCII spaces and controls,
// U+0085, U+00A0, U+1680, U+2000 to U+200A, U+200E, U+200F, U+2028, U+2029, U+202F, U+205F and U+3000.
// At the very start it also skips the bidi controls U+061C, U+202A to U+202E and U+2066 to U+2069.
size_t spaceAt(const std::string& s, size_t i, bool atStart) {
    const auto byte = [&](size_t k) -> unsigned char { return i + k < s.size() ? static_cast<unsigned char>(s[i + k]) : 0; };
    const unsigned char b0 = byte(0), b1 = byte(1), b2 = byte(2);
    if (b0 == ' ' || (b0 >= 0x09 && b0 <= 0x0D)) return 1;
    if (b0 == 0xC2 && (b1 == 0x85 || b1 == 0xA0)) return 2;
    if (atStart && b0 == 0xD8 && b1 == 0x9C) return 2;
    if (b0 == 0xE1 && b1 == 0x9A && b2 == 0x80) return 3;
    if (b0 == 0xE3 && b1 == 0x80 && b2 == 0x80) return 3;
    if (b0 == 0xE2 && b1 == 0x80) {
        if ((b2 >= 0x80 && b2 <= 0x8A) || b2 == 0x8E || b2 == 0x8F || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF) return 3;
        if (atStart && b2 >= 0xAA && b2 <= 0xAE) return 3;
    }
    if (b0 == 0xE2 && b1 == 0x81) {
        if (b2 == 0x9F) return 3;
        if (atStart && b2 >= 0xA6 && b2 <= 0xA9) return 3;
    }
    return 0;
}

void skipSpaces(const std::string& s, size_t& i, bool atStart) {
    while (size_t n = spaceAt(s, i, atStart)) i += n;
}

// What ISO8601DateFormatter reads, first plain and then with .withFractionalSeconds:
// yyyy-MM-ddTHH:mm:ss, an optional fraction, then Z, GMT, UTC or an offset (+HH:MM, +HHMM, +HH).
// Seconds since 1970 in UTC.
std::optional<long long> parseWall(const std::string& s) {
    size_t i = 0;
    int year, month, day, hour, minute, second;
    skipSpaces(s, i, true);
    if (!readNumber(s, i, 1, 4, year) || !readChar(s, i, '-')) return std::nullopt;
    if (!readNumber(s, i, 1, 2, month) || month < 1 || month > 12 || !readChar(s, i, '-')) return std::nullopt;
    if (!readNumber(s, i, 1, 2, day) || day < 1 || day > 31 || !readChar(s, i, 'T')) return std::nullopt;
    if (!readNumber(s, i, 1, 2, hour) || hour > 24 || !readChar(s, i, ':')) return std::nullopt;
    if (!readNumber(s, i, 1, 2, minute) || minute > 59 || !readChar(s, i, ':')) return std::nullopt;
    if (!readNumber(s, i, 1, 2, second) || second > 59) return std::nullopt;
    if (readChar(s, i, '.')) {
        // Only the minute is shown, so the fraction is read and dropped.
        int ignored;
        if (!readNumber(s, i, 1, 1, ignored)) return std::nullopt;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') i++;
    }
    skipSpaces(s, i, false);
    long long offset = 0;
    if (readChar(s, i, 'Z') || readChar(s, i, 'z')) {
    } else if (s.compare(i, 3, "GMT") == 0 || s.compare(i, 3, "UTC") == 0) {
        i += 3;
    } else if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
        const int sign = s[i] == '-' ? -1 : 1;
        i++;
        int offsetHours = 0, offsetMinutes = 0, offsetSeconds = 0;
        const size_t hourStart = i;
        if (!readNumber(s, i, 1, 2, offsetHours)) return std::nullopt;
        if (i - hourStart == 2) {
            const size_t mark = i;
            const bool colon = readChar(s, i, ':');
            if (!readNumber(s, i, 2, 2, offsetMinutes)) {
                i = mark;
                offsetMinutes = 0;
            } else if (colon) {
                const size_t secondsMark = i;
                if (!readChar(s, i, ':') || !readNumber(s, i, 2, 2, offsetSeconds)) {
                    i = secondsMark;
                    offsetSeconds = 0;
                }
            }
        }
        if (offsetHours > 23 || offsetMinutes > 59 || offsetSeconds > 59) return std::nullopt;
        offset = sign * (offsetHours * 3600LL + offsetMinutes * 60LL + offsetSeconds);
    } else {
        return std::nullopt;
    }
    return daysFromCivil(year, month, day) * 86400 + hour * 3600LL + minute * 60LL + second - offset;
}

// "7 Oct 2026 at 14:03" in the computer's time zone: the Swift's DateFormatter with the en_GB locale
// and "d MMM yyyy 'at' HH:mm". A wall time that cannot be read is shown as it is.
std::string friendlyDate(const std::string& wall) {
    const auto seconds = parseWall(wall);
    if (!seconds) return wall;
    const std::time_t t = static_cast<std::time_t>(*seconds);
    std::tm local{};
#ifdef _WIN32
    if (localtime_s(&local, &t) != 0) return wall;
#else
    if (!localtime_r(&t, &local)) return wall;
#endif
    static const char* const months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    if (local.tm_mon < 0 || local.tm_mon > 11) return wall;
    return format("%d %s %04d at %02d:%02d", local.tm_mday, months[local.tm_mon], local.tm_year + 1900, local.tm_hour,
                  local.tm_min);
}

// MARK: Files

std::string fileSize(long long bytes) {
    if (bytes >= 1'000'000) return format("%.1f MB", static_cast<double>(bytes) / 1'000'000);
    if (bytes >= 1'000) return format("%.0f KB", static_cast<double>(bytes) / 1'000);
    return std::to_string(bytes) + " bytes";
}

// FileManager's attributesOfItem size: of the item itself, not what a link points to. 0 when unreadable.
long long itemSize(const fs::path& path) {
#ifdef _WIN32
    std::error_code ec;
    const auto status = fs::symlink_status(path, ec);
    if (ec || !fs::is_regular_file(status)) return 0;
    const auto size = fs::file_size(path, ec);
    return ec ? 0 : static_cast<long long>(size);
#else
    struct stat info;
    if (lstat(path.c_str(), &info) != 0) return 0;
    return static_cast<long long>(info.st_size);
#endif
}

// URL.path, as the Swift prints the folder: no separator at the end, unless it is the root.
std::string folderText(const fs::path& folder) {
    std::string text = utf8(folder);
    const size_t rootLength = utf8(folder.root_path()).size();
    const auto isSeparator = [](char c) {
#ifdef _WIN32
        return c == '/' || c == '\\';
#else
        return c == '/';
#endif
    };
    while (text.size() > 1 && text.size() > rootLength && isSeparator(text.back())) text.pop_back();
    return text;
}

// trimmingCharacters(in: .newlines): U+000A to U+000D, U+0085, U+2028 and U+2029 at either end.
std::string trimNewlines(std::string text) {
    static const char* const newlines[] = {"\n", "\v", "\f", "\r", "\xC2\x85", "\xE2\x80\xA8", "\xE2\x80\xA9"};
    for (bool again = true; again;) {
        again = false;
        for (const std::string mark : newlines) {
            if (text.size() >= mark.size() && text.compare(text.size() - mark.size(), mark.size(), mark) == 0) {
                text.erase(text.size() - mark.size());
                again = true;
            }
        }
    }
    for (bool again = true; again;) {
        again = false;
        for (const std::string mark : newlines) {
            if (text.compare(0, mark.size(), mark) == 0) {
                text.erase(0, mark.size());
                again = true;
            }
        }
    }
    return text;
}

const char* syncVerdict(double c) {
    return c >= 0.8 ? "high" : c >= 0.5 ? "medium, worth a quick check by eye" : "low, check the sync by eye before editing";
}

// The first extra mic recorded to `file`, if any.
const ExtraMicSync* micForFile(const std::vector<ExtraMicSync>& mics, const std::string& file) {
    auto it = std::find_if(mics.begin(), mics.end(), [&](const ExtraMicSync& m) { return m.file == file; });
    return it == mics.end() ? nullptr : &*it;
}

}  // namespace

std::string buildReport(const ReportInput& r) {
    std::vector<std::string> out;
    const auto add = [&](std::string line) { out.push_back(std::move(line)); };

    add("# " + r.title);
    add("");
    if (r.wall) add("Recorded " + friendlyDate(*r.wall) + ".");
    add("Folder: `" + folderText(r.folder) + "`");
    if (r.events) {
        if (!r.events->stopTime) {
            add("");
            add("The events log has no stop line, so the app probably closed or crashed during this take. Everything saved up to that moment is used.");
        }
        if (r.events->skippedLines > 0) {
            add("");
            add(std::to_string(r.events->skippedLines) + " damaged line" + (r.events->skippedLines == 1 ? " was" : "s were") +
                " skipped in events.jsonl.");
        }
    } else {
        add("");
        add("There is no readable events.jsonl, so there are no chapters.");
    }

    add("");
    add("## Length");
    add("");
    add("- Camera (camera.mov): " + length(r.cameraDuration));
    if (r.screenNote) {
        add("- Screen (screen.mov): " + *r.screenNote);
    } else if (r.events && r.events->screenShared) {
        add("- Screen (screen.mov): " + length(r.screenDuration) + ", shared " + clock(*r.events->screenShared) + " into the take");
    } else {
        add("- Screen (screen.mov): " + length(r.screenDuration));
    }
    for (const auto& extra : r.extraCameras) {
        add("- Extra camera (" + extra.file + "): " + length(extra.duration));
    }
    for (const auto& mic : r.extraMics) {
        add("- Extra mic (" + mic.file + (mic.name ? ", " + *mic.name : "") + "): " + length(mic.duration));
    }

    add("");
    add("## Sync");
    add("");
    if (r.sync.method == "audio") {
        const double offset = r.sync.offset;
        const std::string amount = format("%.3f", std::fabs(offset));
        if (std::fabs(offset) < 0.0005) {
            add("The camera and the screen started at the same moment.");
        } else if (offset < 0) {
            add("The screen recording started " + amount + " seconds before the camera.");
        } else {
            add("The screen recording started " + amount + " seconds after the camera.");
        }
        add("");
        add("- Offset: " + jsonNumber(offset) + " seconds (camera time = screen time + offset), saved in sync.json");
        const double c = r.sync.confidence;
        add("- Confidence: " + format("%.2f", c) + " (" + syncVerdict(c) + ")");
    } else {
        const std::string offset = r.sync.offset == 0 ? "0" : jsonNumber(r.sync.offset) + ", the moment the screen was shared";
        add("Not measured, because " + r.sync.note.value_or("there is no screen sound to match") + ". sync.json says offset " +
            offset + ".");
    }
    for (const auto& extra : r.extraCameras) {
        add("");
        if (extra.sync.method == "audio") {
            const double c = extra.sync.confidence;
            add("- " + extra.file + ": offset " + jsonNumber(extra.sync.offset) + " seconds (camera time = " + extra.file +
                " time + offset), " + "confidence " + format("%.2f", c) + " (" + syncVerdict(c) + "), saved in sync.json");
        } else {
            add("- " + extra.file + ": not measured, because " + extra.sync.note.value_or("it has no sound to match") +
                ". sync.json says offset 0.");
        }
    }

    if (!r.extraMics.empty()) {
        add("");
        add("## Microphones");
        add("");
        if (r.videoMic) {
            const std::string& mic = *r.videoMic;
            const ExtraMicSync* found = micForFile(r.extraMics, mic);
            const std::string name = found && found->name ? *found->name : mic;
            add("The video's sound is " + name + " (" + mic + "). Every mic's file is in the folder, so another can be used in editing.");
        } else {
            add("The video's sound is the main mic, from camera.mov. Every mic's file is in the folder, so another can be used in editing.");
        }
        if (r.videoSoundNote) {
            add("");
            add("Note: " + *r.videoSoundNote + ".");
        }
        for (const auto& mic : r.extraMics) {
            add("");
            const std::string who = mic.name ? mic.file + " (" + *mic.name + ")" : mic.file;
            if (mic.sync.method == "audio") {
                const double c = mic.sync.confidence;
                const char* verdict = c >= 0.8 ? "high" : "medium, worth a quick listen";
                add("- " + who + ": lined up by sound, offset " + jsonNumber(mic.sync.offset) +
                    " seconds (camera time = mic time + offset), confidence " + format("%.2f", c) + " (" + verdict + ")");
            } else if (mic.sync.method == "clock") {
                add("- " + who + ": lined up by the " + std::string(computerName) + "'s clock, offset " + jsonNumber(mic.sync.offset) + " seconds, because " +
                    mic.sync.note.value_or("its sound did not match") + ". Check the lip sync by eye.");
            } else {
                add("- " + who + ": not lined up, because " + mic.sync.note.value_or("it could not be read") + ".");
            }
            if (r.events) {
                for (const auto& m : r.events->mutes) {
                    if (m.file != mic.file) continue;
                    add(std::string("  - ") + (m.on ? "Muted" : "Unmuted") + " at " + clock(m.t) + ", " +
                        (m.byPhone ? "on the phone" : std::string("from the ") + computerName) + (m.on ? ": the file is silent until it was unmuted" : ""));
                }
            }
        }
    }

    add("");
    add("## Transcript");
    add("");
    switch (r.transcript.kind) {
    case TranscriptOutcome::Kind::done:
        add(std::to_string(r.transcript.wordCount) + " words, saved in words.json (transcribed in " +
            format("%.0f", r.transcript.seconds) + " seconds).");
        break;
    case TranscriptOutcome::Kind::skipped:
        add("Skipped (run without `--no-transcribe` to make words.json and retakes.json).");
        break;
    case TranscriptOutcome::Kind::failed:
        add("Failed: " + r.transcript.reason);
        break;
    }

    add("");
    add("## Chapters");
    add("");
    if (!r.chaptersWanted) {
        add("Skipped (the take was recorded with the transcript and chapters box unticked).");
    } else if (r.chapters.empty()) {
        if (r.candidateChapters == 0) {
            add("None: there were no " + r.chapterSource + " to build chapters from. chapters.txt is empty.");
        } else {
            add("None: YouTube needs at least 3 chapters of 10 seconds or more, and the " + r.chapterSource +
                " did not give that. chapters.txt is empty.");
        }
    } else {
        add("Made from the " + r.chapterSource + ". Paste this into the YouTube description:");
        add("");
        add("```");
        add(trimNewlines(chaptersText(r.chapters)));
        add("```");
    }

    add("");
    add("## Retakes");
    add("");
    if (r.retakes) {
        if (r.retakes->empty()) {
            add("The word \"retake\" was not said.");
        } else {
            const size_t count = r.retakes->size();
            add("\"Retake\" was said " + std::to_string(count) + " time" + (count == 1 ? "" : "s") + ". Cut back to before each one:");
            add("");
            for (const auto& retake : *r.retakes) {
                add("- " + clock(retake.t) + " (" + format("%.1f", retake.t) + " s): " + retake.context);
            }
        }
    } else {
        add("Not checked, because there is no transcript.");
    }

    if (r.events && !r.events->sounds.empty()) {
        add("");
        add(std::string("## ") + computerName + " sound");
        add("");
        add("The second sound track of screen.mov. Off means silence there.");
        add("");
        for (const auto& change : r.events->sounds) {
            add("- " + clock(change.t) + " " + (change.on ? "on, from " + change.from : std::string("off")));
        }
    }

    add("");
    add("## Video");
    add("");
    std::optional<std::string> micWords;
    if (r.videoMic) {
        const ExtraMicSync* found = micForFile(r.extraMics, *r.videoMic);
        micWords = found && found->name ? *found->name + " (" + *r.videoMic + ")" : *r.videoMic;
    }
    const auto videoSize = [](const ComposeResult& video) {
        return "video.mp4 is the finished video: " + clock(video.seconds) + ", " + std::to_string(video.width) + " by " +
               std::to_string(video.height) + ".";
    };
    if (r.video && !r.screenDuration) {
        add(videoSize(*r.video) + " It is camera.mov's picture as it was, with the sound from " +
            micWords.value_or("the main mic") + ".");
    } else if (r.video) {
        add(videoSize(*r.video) + " It is what was on the screen, with her camera across the whole screen for Me" +
            (micWords ? ", and the sound from " + *micWords : "") + ".");
        if (r.video->cameraUntil) {
            add("");
            add("Until " + clock(*r.video->cameraUntil) + ", before the screen was shared, it is camera.mov.");
        }
        if (r.events && !r.events->shows.empty()) {
            add("");
            for (const auto& change : r.events->shows) {
                add("- " + clock(change.t) + " " + (change.screen ? "Screen" : "Me"));
            }
        }
    } else if (r.videoProblem) {
        add("Not made, because " + *r.videoProblem +
            ". camera.mov and screen.mov are whole, so the video can still be edited from them.");
    } else if (r.videoWanted || !r.screenDuration) {
        // Wanted but not made with no problem means a camera-only take whose picked mic could not be used.
        add("No screen in this take, so camera.mov is the video.");
    } else {
        add("Not made (finished with --no-video).");
    }

    add("");
    add("## Files");
    add("");
    std::vector<std::string> names;
    std::error_code ec;
    for (fs::directory_iterator it(r.folder, ec), end; !ec && it != end; it.increment(ec)) {
        std::string name = utf8(it->path().filename());
        if (name.empty() || name[0] == '.' || name == "report.md") continue;
        names.push_back(std::move(name));
    }
    std::sort(names.begin(), names.end());
    for (const auto& name : names) {
        add("- " + name + " (" + fileSize(itemSize(r.folder / pathFromUtf8(name))) + ")");
    }
    add("- report.md (this file)");
    add("");

    std::string text;
    for (size_t i = 0; i < out.size(); i++) {
        if (i > 0) text += "\n";
        text += out[i];
    }
    return text;
}

}  // namespace vl
