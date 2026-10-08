#include "events.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <set>
#include <utility>

namespace vl {

namespace {

using nlohmann::json;

// Foundation's CharacterSet.newlines and CharacterSet.whitespaces.
bool isNewline(char32_t c) { return (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029; }
bool isWhitespace(char32_t c) {
    return c == 0x09 || c == 0x20 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200B) || c == 0x202F ||
           c == 0x205F || c == 0x3000;
}

// The character starting at text[at] and its length in bytes. nlohmann has already checked the UTF-8.
std::pair<char32_t, size_t> scalarAt(const std::string& text, size_t at) {
    const auto lead = static_cast<unsigned char>(text[at]);
    size_t length = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
    length = std::min(length, text.size() - at);
    unsigned value = length == 1 ? lead : length == 2 ? (lead & 0x1Fu) : length == 3 ? (lead & 0x0Fu) : (lead & 0x07u);
    for (size_t i = 1; i < length; i++) value = (value << 6) | (static_cast<unsigned char>(text[at + i]) & 0x3Fu);
    return {static_cast<char32_t>(value), length};
}

// Each newline becomes a space, then spaces and tabs come off both ends. Nothing when that leaves nothing.
std::optional<std::string> oneLine(const std::string& raw) {
    std::string out;
    size_t keepFrom = std::string::npos;
    size_t keepTo = 0;
    for (size_t at = 0; at < raw.size();) {
        const auto [c, length] = scalarAt(raw, at);
        if (isNewline(c)) {
            out += ' ';
        } else {
            if (!isWhitespace(c)) {
                if (keepFrom == std::string::npos) keepFrom = out.size();
                keepTo = out.size() + length;
            }
            out.append(raw, at, length);
        }
        at += length;
    }
    if (keepFrom == std::string::npos) return std::nullopt;
    return out.substr(keepFrom, keepTo - keepFrom);
}

// `as? String`
const std::string* stringValue(const json& object, const char* key) {
    auto it = object.find(key);
    return it != object.end() && it->is_string() ? it->get_ptr<const std::string*>() : nullptr;
}

// `as? NSNumber`: any number, and true and false as 1 and 0.
std::optional<double> numberValue(const json& object, const char* key) {
    auto it = object.find(key);
    if (it == object.end()) return std::nullopt;
    if (it->is_number()) return it->get<double>();
    if (it->is_boolean()) return it->get<bool>() ? 1.0 : 0.0;
    return std::nullopt;
}

// `as? Bool`: true and false, and the numbers 1 and 0.
std::optional<bool> boolValue(const json& object, const char* key) {
    auto it = object.find(key);
    if (it == object.end()) return std::nullopt;
    if (it->is_boolean()) return it->get<bool>();
    if (it->is_number()) {
        const double value = it->get<double>();
        if (value == 1) return true;
        if (value == 0) return false;
    }
    return std::nullopt;
}

// One line as a JSON value, keeping the first of any repeated key, as JSONSerialization does
// (nlohmann on its own keeps the last). Discarded when it is not whole JSON.
json parseLine(const std::string& line) {
    std::vector<std::set<std::string>> keys;  // the keys seen so far in the object open at each depth
    json::parser_callback_t firstKeyWins = [&keys](int depth, json::parse_event_t event, json& parsed) {
        const auto level = static_cast<size_t>(depth);
        if (event == json::parse_event_t::object_start) {
            if (keys.size() < level + 2) keys.resize(level + 2);
            keys[level + 1].clear();
        } else if (event == json::parse_event_t::key) {
            if (keys.size() < level + 1) keys.resize(level + 1);
            return keys[level].insert(parsed.get<std::string>()).second;
        }
        return true;
    };
    return json::parse(line, firstKeyWins, false);
}

}  // namespace

// Reads events.jsonl line by line. A crash can leave a cut-off last line or no stop line,
// so any line that is not a whole JSON object is counted and skipped.
std::optional<RecordingEvents> readEvents(const fs::path& path) {
    std::error_code ec;
    if (fs::is_directory(path, ec)) return std::nullopt;
    std::string data;
    try {
        data = readFile(path);
    } catch (const FinishError&) {
        return std::nullopt;
    }
    RecordingEvents events;
    for (size_t start = 0; start < data.size();) {
        size_t end = data.find('\n', start);
        if (end == std::string::npos) end = data.size();
        std::string line;
        for (size_t i = start; i < end; i++) {
            if (data[i] != '\0' && data[i] != '\r') line += data[i];
        }
        start = end + 1;
        if (std::all_of(line.begin(), line.end(), [](char c) { return c == ' ' || c == '\t'; })) continue;
        const json object = parseLine(line);
        const std::string* type = object.is_object() ? stringValue(object, "type") : nullptr;
        if (!type) {
            events.skippedLines += 1;
            continue;
        }
        const double t = numberValue(object, "t").value_or(0);
        auto text = [&object](const char* key) -> std::optional<std::string> {
            const std::string* value = stringValue(object, key);
            return value ? oneLine(*value) : std::nullopt;
        };
        if (*type == "start") {
            events.title = text("title");
            events.wall = text("wall");
            const std::string* screen = stringValue(object, "screen");
            events.cameraFirst = screen && screen->empty();
            // `as? [[String: Any]]` is all or nothing: one entry that is not an object drops them all.
            auto mics = object.find("extraMics");
            if (mics != object.end() && mics->is_array() &&
                std::all_of(mics->begin(), mics->end(), [](const json& mic) { return mic.is_object(); })) {
                for (const auto& mic : *mics) {
                    if (const std::string* file = stringValue(mic, "file")) {
                        const std::string* name = stringValue(mic, "name");
                        events.micNames[*file] = name ? *name : *file;
                    }
                }
            }
            events.videoMic = text("videoMic");
        } else if (*type == "mic-start") {
            auto file = text("file");
            auto at = numberValue(object, "at");
            if (file && at) events.micStarts[*file] = *at;
        } else if (*type == "mute") {
            if (auto file = text("file")) {
                events.mutes.push_back({t, *file, boolValue(object, "on").value_or(false), text("by") == "phone"});
            }
        } else if (*type == "screen-start") {
            if (!events.screenShared) events.screenShared = t;
        } else if (*type == "sound") {
            events.sounds.push_back({t, boolValue(object, "on").value_or(false), text("from").value_or("every app")});
        } else if (*type == "show") {
            if (auto what = text("what")) events.shows.push_back({t, *what == "screen"});
        } else if (*type == "card") {
            if (auto section = text("section")) events.cards.push_back({t, *section});
        } else if (*type == "app") {
            if (auto name = text("name")) events.apps.push_back({t, *name});
        } else if (*type == "stop") {
            events.stopTime = t;
        }
    }
    return events;
}

}  // namespace vl
