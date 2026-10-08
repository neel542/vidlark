#pragma once
// Shared by every part of vidlark-finish: errors, finding and running the tools, small output helpers.
// Text is UTF-8 everywhere; paths turn into text only through utf8() and back through pathFromUtf8().

#include <filesystem>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace vl {

// What the report calls the computer the take was recorded on.
#ifdef _WIN32
inline constexpr const char* computerName = "PC";
#else
inline constexpr const char* computerName = "Mac";
#endif

struct FinishError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

std::string utf8(const fs::path& path);
fs::path pathFromUtf8(const std::string& text);

// The app starts this tool without a shell PATH. On a Mac, look in the usual Homebrew places first.
// On Windows, look next to the exe and in its tools folder, where the download puts ffmpeg and whisper.
namespace tools {
std::vector<fs::path> searchDirs();
std::string searchDirsText();
std::optional<fs::path> find(const std::string& name);  // adds .exe on Windows
fs::path require(const std::string& name);              // throws FinishError when missing
}  // namespace tools

struct ProcessResult {
    int status = -1;
    std::string out;
    std::string err;
    // The last non-empty line of stderr, or "exit code N".
    std::string lastErrorLine() const;
};

// Runs a program with stdin closed, reading stdout and stderr at once so neither can fill up and stall.
ProcessResult runTool(const fs::path& executable, const std::vector<std::string>& arguments);

struct MediaInfo {
    std::optional<double> duration;
    bool hasAudio = false;
};
MediaInfo probeMedia(const fs::path& ffprobe, const fs::path& file);

std::string jsonString(const std::string& text);
std::string jsonNumber(double value, int places = 3);
// MM:SS, or H:MM:SS from one hour on. Seconds are rounded down, as YouTube expects.
std::string clock(double seconds);
// Neel's hard rule: no em dashes in anything this tool writes.
std::string noEmDash(std::string text);
// Writes UTF-8 text with no em dashes, replacing the file in one step.
void writeText(const std::string& text, const fs::path& path);
std::string readFile(const fs::path& path);  // throws FinishError
std::string format(const char* fmt, ...);
std::string trim(const std::string& text);
std::vector<std::string> splitLines(const std::string& text);
int processorCount();

}  // namespace vl
