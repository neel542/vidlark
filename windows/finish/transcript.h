#pragma once
// The transcript (whisper-cli), words.json and retakes. Port of Transcript.swift.

#include "support.h"

#include <nlohmann/json.hpp>

#include <optional>
#include <string>
#include <vector>

namespace vl {

struct Word {
    std::string word;
    double start = 0;
    double end = 0;
};

struct Retake {
    double t = 0;
    std::string context;
};

struct ModelSearch {
    std::optional<fs::path> path;
    std::vector<std::string> searched;
};
// Mac: ~/.cache/whisper and /Users/Shared/Vidlark Recordings/.models, as in Transcript.swift.
// Windows: %LOCALAPPDATA%\Vidlark\models and <recordings root>\.models (see recordingsRoot()).
ModelSearch findModel(const std::optional<std::string>& override);
fs::path recordingsRoot();  // Mac: /Users/Shared/Vidlark Recordings. Windows: %PUBLIC%\Videos\Vidlark Recordings
std::optional<std::string> dtwPreset(const std::string& modelPath);
std::vector<Word> transcribe(const fs::path& whisper, const fs::path& model, const fs::path& wav, const fs::path& workDir);
std::vector<Word> buildWords(const nlohmann::json& segments, bool useDTW);
std::string wordsJSON(const std::vector<Word>& words);
std::vector<Retake> findRetakes(const std::vector<Word>& words);
std::string retakesJSON(const std::vector<Retake>& retakes);

}  // namespace vl
