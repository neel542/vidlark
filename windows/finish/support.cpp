#include "support.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <thread>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif

namespace vl {

std::string utf8(const fs::path& path) {
    auto text = path.u8string();
    return std::string(text.begin(), text.end());
}

fs::path pathFromUtf8(const std::string& text) {
    return fs::path(std::u8string(text.begin(), text.end()));
}

std::string format(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    va_list copy;
    va_copy(copy, args);
    int size = std::vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    std::string out(size > 0 ? size : 0, '\0');
    if (size > 0) std::vsnprintf(out.data(), out.size() + 1, fmt, args);
    va_end(args);
    return out;
}

std::string trim(const std::string& text) {
    auto isSpace = [](unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
    size_t a = 0, b = text.size();
    while (a < b && isSpace(text[a])) a++;
    while (b > a && isSpace(text[b - 1])) b--;
    return text.substr(a, b - a);
}

std::vector<std::string> splitLines(const std::string& text) {
    std::vector<std::string> lines;
    std::string line;
    for (char c : text) {
        if (c == '\n' || c == '\r') {
            if (!line.empty() || c == '\n') lines.push_back(line);
            line.clear();
        } else {
            line += c;
        }
    }
    if (!line.empty()) lines.push_back(line);
    return lines;
}

int processorCount() {
    unsigned n = std::thread::hardware_concurrency();
    return n == 0 ? 1 : static_cast<int>(n);
}

// MARK: Finding the tools

namespace {

#ifdef _WIN32
fs::path exeDir() {
    std::wstring buffer(32768, L'\0');
    DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    buffer.resize(length);
    return fs::path(buffer).parent_path();
}

std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n);
    return out;
}

std::string envVar(const wchar_t* name) {
    DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
    if (n == 0) return {};
    std::wstring value(n, L'\0');
    value.resize(GetEnvironmentVariableW(name, value.data(), n));
    return utf8(fs::path(value));
}
#else
std::string envVar(const char* name) {
    const char* value = std::getenv(name);
    return value ? value : "";
}
#endif

std::vector<fs::path> pathDirs() {
    std::vector<fs::path> dirs;
#ifdef _WIN32
    const char separator = ';';
    std::string path = envVar(L"PATH");
#else
    const char separator = ':';
    std::string path = envVar("PATH");
#endif
    std::stringstream stream(path);
    std::string part;
    while (std::getline(stream, part, separator)) {
        if (!part.empty()) dirs.push_back(pathFromUtf8(part));
    }
    return dirs;
}

bool isExecutable(const fs::path& candidate) {
    std::error_code ec;
    if (!fs::is_regular_file(candidate, ec)) return false;
#ifdef _WIN32
    return true;
#else
    return access(candidate.c_str(), X_OK) == 0;
#endif
}

}  // namespace

namespace tools {

std::vector<fs::path> searchDirs() {
#ifdef _WIN32
    fs::path here = exeDir();
    return {here, here / "tools"};
#else
    return {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"};
#endif
}

std::string searchDirsText() {
    std::string out;
    for (const auto& dir : searchDirs()) {
        if (!out.empty()) out += ", ";
        out += utf8(dir);
    }
    return out;
}

std::optional<fs::path> find(const std::string& name) {
    auto dirs = searchDirs();
    auto more = pathDirs();
    dirs.insert(dirs.end(), more.begin(), more.end());
#ifdef _WIN32
    const std::string file = name + ".exe";
#else
    const std::string& file = name;
#endif
    for (const auto& dir : dirs) {
        fs::path candidate = dir / pathFromUtf8(file);
        if (isExecutable(candidate)) return candidate;
    }
    return std::nullopt;
}

fs::path require(const std::string& name) {
    if (auto path = find(name)) return *path;
    throw FinishError(name + " not found (looked in " + searchDirsText() + " and PATH)");
}

}  // namespace tools

// MARK: Running a tool

std::string ProcessResult::lastErrorLine() const {
    auto lines = splitLines(err);
    for (auto it = lines.rbegin(); it != lines.rend(); ++it) {
        auto line = trim(*it);
        if (!line.empty()) return line;
    }
    return "exit code " + std::to_string(status);
}

#ifdef _WIN32

namespace {

// Quotes one argument the way CommandLineToArgvW and the C runtime read it back.
std::wstring quoteArgument(const std::wstring& arg) {
    if (!arg.empty() && arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) return arg;
    std::wstring out = L"\"";
    for (size_t i = 0;; i++) {
        size_t slashes = 0;
        while (i < arg.size() && arg[i] == L'\\') { i++; slashes++; }
        if (i == arg.size()) {
            out.append(slashes * 2, L'\\');
            break;
        }
        if (arg[i] == L'"') {
            out.append(slashes * 2 + 1, L'\\');
        } else {
            out.append(slashes, L'\\');
        }
        out += arg[i];
    }
    return out + L"\"";
}

std::string readAll(HANDLE pipe) {
    std::string data;
    char buffer[65536];
    DWORD got = 0;
    while (ReadFile(pipe, buffer, sizeof buffer, &got, nullptr) && got > 0) data.append(buffer, got);
    return data;
}

}  // namespace

ProcessResult runTool(const fs::path& executable, const std::vector<std::string>& arguments) {
    std::wstring commandLine = quoteArgument(executable.wstring());
    for (const auto& arg : arguments) commandLine += L" " + quoteArgument(wide(arg));

    SECURITY_ATTRIBUTES inherit{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE outRead = nullptr, outWrite = nullptr, errRead = nullptr, errWrite = nullptr;
    if (!CreatePipe(&outRead, &outWrite, &inherit, 0) || !CreatePipe(&errRead, &errWrite, &inherit, 0)) {
        throw FinishError("could not start " + utf8(executable.filename()));
    }
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);
    HANDLE nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, nullptr);

    STARTUPINFOW startup{};
    startup.cb = sizeof startup;
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = nul;
    startup.hStdOutput = outWrite;
    startup.hStdError = errWrite;
    PROCESS_INFORMATION process{};
    BOOL started = CreateProcessW(executable.wstring().c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                                  CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
    CloseHandle(outWrite);
    CloseHandle(errWrite);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!started) {
        CloseHandle(outRead);
        CloseHandle(errRead);
        throw FinishError("could not start " + utf8(executable.filename()) + " (error " + std::to_string(GetLastError()) + ")");
    }

    ProcessResult result;
    std::thread errThread([&] { result.err = readAll(errRead); });
    result.out = readAll(outRead);
    errThread.join();
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    result.status = static_cast<int>(code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    CloseHandle(outRead);
    CloseHandle(errRead);
    return result;
}

#else

ProcessResult runTool(const fs::path& executable, const std::vector<std::string>& arguments) {
    int outPipe[2], errPipe[2];
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0) throw FinishError("could not start " + utf8(executable.filename()));

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1);
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2);
    posix_spawn_file_actions_addclose(&actions, outPipe[0]);
    posix_spawn_file_actions_addclose(&actions, errPipe[0]);

    std::string exe = executable.string();
    std::vector<char*> argv;
    argv.push_back(exe.data());
    std::vector<std::string> copies = arguments;
    for (auto& arg : copies) argv.push_back(arg.data());
    argv.push_back(nullptr);

    pid_t pid = 0;
    int spawned = posix_spawn(&pid, exe.c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outPipe[1]);
    close(errPipe[1]);
    if (spawned != 0) {
        close(outPipe[0]);
        close(errPipe[0]);
        throw FinishError("could not start " + utf8(executable.filename()));
    }

    ProcessResult result;
    pollfd fds[2] = {{outPipe[0], POLLIN, 0}, {errPipe[0], POLLIN, 0}};
    std::string* sinks[2] = {&result.out, &result.err};
    int open = 2;
    char buffer[65536];
    while (open > 0) {
        if (poll(fds, 2, -1) < 0) break;
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t got = read(fds[i].fd, buffer, sizeof buffer);
            if (got > 0) {
                sinks[i]->append(buffer, static_cast<size_t>(got));
            } else {
                close(fds[i].fd);
                fds[i].fd = -1;
                open--;
            }
        }
    }
    int status = 0;
    waitpid(pid, &status, 0);
    result.status = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    return result;
}

#endif

// MARK: Media probing

MediaInfo probeMedia(const fs::path& ffprobe, const fs::path& file) {
    auto result = runTool(ffprobe, {"-v", "error", "-show_entries", "format=duration:stream=codec_type,duration",
                                    "-of", "json", utf8(file)});
    nlohmann::json json;
    if (result.status == 0) json = nlohmann::json::parse(result.out, nullptr, false);
    if (result.status != 0 || json.is_discarded() || !json.is_object()) throw FinishError(result.lastErrorLine());

    auto number = [](const nlohmann::json& value) -> std::optional<double> {
        if (!value.is_string()) return std::nullopt;
        try {
            return std::stod(value.get<std::string>());
        } catch (...) {
            return std::nullopt;
        }
    };
    MediaInfo info;
    const auto streams = json.value("streams", nlohmann::json::array());
    for (const auto& stream : streams) {
        if (stream.value("codec_type", "") == "audio") info.hasAudio = true;
    }
    if (json.contains("format") && json["format"].contains("duration")) info.duration = number(json["format"]["duration"]);
    if (!info.duration || *info.duration == 0) {
        std::optional<double> longest;
        for (const auto& stream : streams) {
            if (!stream.contains("duration")) continue;
            if (auto d = number(stream["duration"]); d && (!longest || *d > *longest)) longest = d;
        }
        info.duration = longest;
    }
    if (streams.empty()) throw FinishError("no audio or video found in the file");
    return info;
}

// MARK: Output helpers

std::string jsonString(const std::string& text) {
    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                out += format("\\u%04x", c);
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string jsonNumber(double value, int places) {
    std::string text = format("%.*f", places, value);
    if (std::stod(text) == 0) return format("%.*f", places, 0.0);
    return text;
}

std::string clock(double seconds) {
    long total = static_cast<long>(std::max(0.0, seconds));
    long h = total / 3600, m = (total % 3600) / 60, s = total % 60;
    return h > 0 ? format("%ld:%02ld:%02ld", h, m, s) : format("%02ld:%02ld", m, s);
}

std::string noEmDash(std::string text) {
    static const std::string dash = "\xE2\x80\x94";
    static const std::string spaced = " " + dash + " ";
    for (size_t at; (at = text.find(spaced)) != std::string::npos;) text.replace(at, spaced.size(), ", ");
    for (size_t at; (at = text.find(dash)) != std::string::npos;) text.replace(at, dash.size(), ", ");
    return text;
}

void writeText(const std::string& text, const fs::path& path) {
    static std::mt19937_64 random{std::random_device{}()};
    fs::path temp = path;
    temp += ".tmp-" + std::to_string(random() % 1000000);
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) throw FinishError("could not write " + utf8(path));
        std::string clean = noEmDash(text);
        out.write(clean.data(), static_cast<std::streamsize>(clean.size()));
        if (!out) throw FinishError("could not write " + utf8(path));
    }
    std::error_code ec;
    fs::rename(temp, path, ec);
    if (ec) {
        fs::remove(temp, ec);
        throw FinishError("could not write " + utf8(path));
    }
}

std::string readFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw FinishError("could not read " + utf8(path));
    std::ostringstream data;
    data << in.rdbuf();
    return data.str();
}

}  // namespace vl
