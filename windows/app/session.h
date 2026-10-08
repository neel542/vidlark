#pragma once
// The live state of the panel: the camera and main mic that are open, the picture and level the panel
// shows, and the take while one is recording. Messages for the panel go through `post`, from any thread.

#include "capture/camera.h"
#include "capture/mic.h"
#include "capture/screen.h"
#include "capture/writer.h"
#include "library.h"
#include "overlay.h"

#include <nlohmann/json.hpp>

#include <atomic>
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
    using RunOnWindowThread = std::function<void(std::function<void()>)>;
    // On the window thread, which every call below is made on too.
    Session(Post post, RunOnWindowThread onWindowThread);
    ~Session();

    // Opens the camera and mic by id ("" for the first camera and Windows' default mic).
    void open(const std::string& cameraId, const std::string& micId);
    // Starts a take. Extra mics record to mic-2.m4a and on. Sends "recording" or "problem".
    void record(const std::optional<std::string>& title, const std::vector<std::string>& extraMicIds);
    // Ends the take and runs vidlark-finish on it. Sends "finishing" lines, then "finished".
    void stop();
    // Share screen, during a take: records `target` ({"kind": "screen" or "window", "id": ...}) into
    // screen.mov from now on, with the computer's sound on or off. Sends "sharing", then "shared" or
    // "share-failed". Her camera fills the screen first (Me), then shrinks into the bubble (Screen).
    void shareScreen(const nlohmann::json& target, bool computerSound);
    // Me or Screen: what the video shows from now on. Only once the screen is shared.
    void show(bool screen);
    // The computer's sound in screen.mov, on or off, at any moment of the take.
    void setSound(bool on);
    // Her face in the bubble over the screen, in the video, or not.
    void setBubble(bool on);
    // The take's state for the recording box and the panel: {"type": "take", ...}.
    nlohmann::json takeState();
    bool recording() const { return recording_; }
    // Called about 20 times a second from the window's timer: the meter, and the clock while recording.
    void tick();
    std::filesystem::path lastTake() const { return lastTake_; }

private:
    struct Take;
    void onFrame(IMFSample* sample, LONGLONG time);
    void onSound(const int16_t* samples, UINT32 frames, LONGLONG time, bool silent);
    void sendPreview(const BYTE* data, LONG pitch);
    void runFinisher(std::filesystem::path folder);
    void startScreen(Take* take, HMONITOR monitor, HWND window, std::string name, bool computerSound);

    Post post_;
    RunOnWindowThread onWindowThread_;
    std::unique_ptr<Overlay> overlay_;
    bool bubbleOn_ = true;
    std::thread sharer_;
    std::unique_ptr<capture::Camera> camera_;
    std::unique_ptr<capture::Mic> mic_;
    std::string cameraName_, micName_;
    capture::VideoFormat format_;  // the open camera's, kept so the camera thread never reads camera_
    std::atomic<bool> previewReady_{false};  // set once format_ is filled in
    std::mutex takeMutex_;
    std::unique_ptr<Take> take_;
    std::atomic<bool> recording_{false};
    std::atomic<bool> sharingScreen_{false};  // the screen is shared or being shared: the panel's preview rests
    std::atomic<LONGLONG> lastPreview_{0};
    std::filesystem::path lastTake_;
    std::thread finisher_;
};

// Where takes go: %PUBLIC%\Videos\Vidlark Recordings, shared by every account on the PC.
std::filesystem::path recordingsRoot();

}  // namespace app
