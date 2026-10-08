#pragma once
// The live state of the panel: the camera and main mic that are open, the picture and level the panel
// shows, and the take while one is recording. Messages for the panel go through `post`, from any thread.

#include "capture/camera.h"
#include "capture/mic.h"
#include "capture/writer.h"
#include "library.h"

#include <nlohmann/json.hpp>

#include <chrono>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace app {

class Session {
public:
    using Post = std::function<void(nlohmann::json)>;
    explicit Session(Post post);
    ~Session();

    // Opens the camera and mic by id ("" for the first camera and Windows' default mic).
    void open(const std::string& cameraId, const std::string& micId);
    // Starts a take. Extra mics record to mic-2.m4a and on. Sends "recording" or "problem".
    void record(const std::optional<std::string>& title, const std::vector<std::string>& extraMicIds);
    // Ends the take and runs vidlark-finish on it. Sends "finishing" lines, then "finished".
    void stop();
    bool recording() const { return recording_; }
    // Called about 20 times a second from the window's timer: the meter, and the clock while recording.
    void tick();
    std::filesystem::path lastTake() const { return lastTake_; }

private:
    struct Take;
    void onFrame(IMFSample* sample, LONGLONG time);
    void onSound(const int16_t* samples, UINT32 frames, LONGLONG time, bool silent);
    void sendPreview(IMFSample* sample);
    void runFinisher(std::filesystem::path folder);

    Post post_;
    std::unique_ptr<capture::Camera> camera_;
    std::unique_ptr<capture::Mic> mic_;
    std::string cameraName_, micName_;
    std::mutex takeMutex_;
    std::unique_ptr<Take> take_;
    std::atomic<bool> recording_{false};
    std::atomic<LONGLONG> lastPreview_{0};
    std::filesystem::path lastTake_;
    std::thread finisher_;
};

// Where takes go: %PUBLIC%\Videos\Vidlark Recordings, shared by every account on the PC.
std::filesystem::path recordingsRoot();

}  // namespace app
