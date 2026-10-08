#include "library.h"

#include <cmath>
#include <ctime>

namespace vl {

namespace {
bool isSpace(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }

std::string trimSpaces(std::string text, bool newlinesToo) {
    auto strip = [&](unsigned char c) { return c == ' ' || c == '\t' || (newlinesToo && isSpace(c)); };
    while (!text.empty() && strip(static_cast<unsigned char>(text.back()))) text.pop_back();
    size_t start = 0;
    while (start < text.size() && strip(static_cast<unsigned char>(text[start]))) start++;
    return text.substr(start);
}

// The first `count` letters (not bytes) of UTF-8 text.
std::string prefixLetters(const std::string& text, size_t count) {
    size_t letters = 0, i = 0;
    while (i < text.size() && letters < count) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        size_t length = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 1;
        i += length;
        letters++;
    }
    return text.substr(0, std::min(i, text.size()));
}

std::tm localNow() {
    std::time_t now = std::time(nullptr);
    std::tm local{};
#ifdef _WIN32
    localtime_s(&local, &now);
#else
    localtime_r(&now, &local);
#endif
    return local;
}
}  // namespace

std::string safeName(const std::string& title) {
    static const std::string bad = "/:\\?%*|\"<>";
    std::string cleaned;
    for (char c : title) cleaned += bad.find(c) == std::string::npos ? c : '-';
    cleaned = trimSpaces(cleaned, true);
    std::string shortened = trimSpaces(prefixLetters(cleaned, 60), false);
#ifdef _WIN32
    while (!shortened.empty() && (shortened.back() == '.' || shortened.back() == ' ')) shortened.pop_back();
#endif
    return shortened.empty() ? "Untitled" : shortened;
}

fs::path uniqueFolder(const fs::path& path) {
    fs::path candidate = path;
    std::error_code ec;
    for (int n = 2; fs::exists(candidate, ec); n++) {
        candidate = path.parent_path() / pathFromUtf8(utf8(path.filename()) + " (" + std::to_string(n) + ")");
    }
    return candidate;
}

std::string today() {
    std::tm local = localNow();
    return format("%04d-%02d-%02d", local.tm_year + 1900, local.tm_mon + 1, local.tm_mday);
}

std::string wallClock() {
    std::time_t now = std::time(nullptr);
    std::tm utc{};
#ifdef _WIN32
    gmtime_s(&utc, &now);
#else
    gmtime_r(&now, &utc);
#endif
    return format("%04d-%02d-%02dT%02d:%02d:%02dZ", utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec);
}

fs::path newRecordingFolder(const fs::path& root, std::optional<fs::path>& videoFolder, const std::optional<std::string>& title) {
    std::error_code ec;
    fs::path folder;
    if (videoFolder && fs::is_directory(*videoFolder, ec)) {
        folder = *videoFolder;
    } else {
        std::tm local = localNow();
        std::string name = title ? *title : format("Quick recording %02d.%02d", local.tm_hour, local.tm_min);
        folder = uniqueFolder(root / pathFromUtf8(today() + " " + safeName(name)));
        videoFolder = folder;
    }
    fs::create_directories(folder, ec);
    if (ec) throw FinishError("could not make the folder " + utf8(folder));

    int n = 1;
    for (const auto& entry : fs::directory_iterator(folder, ec)) {
        if (utf8(entry.path().filename()).rfind("recording-", 0) == 0) n++;
    }
    fs::path take = folder / pathFromUtf8("recording-" + std::to_string(n));
    while (fs::exists(take, ec)) take = folder / pathFromUtf8("recording-" + std::to_string(++n));
    fs::create_directories(take, ec);
    if (ec) throw FinishError("could not make the folder " + utf8(take));
    return take;
}

EventLog::EventLog(const fs::path& path, Clock::time_point t0) : t0_(t0) {
#ifdef _WIN32
    file_ = _wfopen(path.c_str(), L"wb");
#else
    file_ = std::fopen(path.c_str(), "wb");
#endif
    if (!file_) throw FinishError("could not start " + utf8(path.filename()));
}

EventLog::~EventLog() {
    if (file_) std::fclose(file_);
}

double EventLog::seconds(Clock::time_point at) const {
    double s = std::chrono::duration<double>(at - t0_).count();
    return std::round(std::max(0.0, s) * 1000) / 1000;
}

void EventLog::write(nlohmann::json fields, Clock::time_point at) {
    if (!file_) return;
    fields["t"] = seconds(at);
    std::string line = fields.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace) + "\n";
    std::fwrite(line.data(), 1, line.size(), file_);
    std::fflush(file_);
}

}  // namespace vl
