#pragma once
// screen.mov: one screen, or one window cut out of its screen, through Windows.Graphics.Capture, as H.264
// at 30 frames a second, at most 1920 on the long side. The first sound track is the main mic (the same
// sound as camera.mov, which is how the finisher lines the two files up), the second the computer's own
// sound (WASAPI loopback), silence while it is switched off. Fragmented like camera.mov, so a crash keeps
// all but the last moment. Vidlark's own windows are kept out by SetWindowDisplayAffinity, not here.
//
// Media Foundation's fragmented MP4 holds one sound track only (its streams are fixed when it is made), so
// during the take the computer's sound goes to a file of its own, screen-sound.m4a, and mergeSound puts it
// into screen.mov after Stop with ffmpeg, copying, not compressing again. After a crash both files stay.

#include "gpu.h"
#include "mic.h"
#include "writer.h"

#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace capture {

class ScreenRecorder {
public:
    struct Options {
        std::filesystem::path file;
        HMONITOR monitor = nullptr;  // the screen recorded
        HWND window = nullptr;       // one window, cut out of that screen; none for the entire screen
        bool sound = false;          // the computer's sound on from the start
        bool testPattern = false;    // a moving test picture instead of the screen, for checks where capture cannot run
    };

    // Starts recording. Call from a thread that has joined the multithreaded COM apartment.
    // Throws std::runtime_error in plain words when it cannot.
    explicit ScreenRecorder(const Options& options);
    ~ScreenRecorder();
    ScreenRecorder(const ScreenRecorder&) = delete;
    ScreenRecorder& operator=(const ScreenRecorder&) = delete;

    // Whether this PC can record its screen, and if not, why, in plain words.
    static bool supported(std::string* why = nullptr);
    // Where the computer's sound waits during the take: screen-sound.m4a next to screen.mov.
    static std::filesystem::path soundFile(const std::filesystem::path& screen);
    // After Stop: the computer's sound into screen.mov as its second sound track, and its own file removed.
    // True when that is done or there was nothing to do; false with the reason when ffmpeg could not.
    static bool mergeSound(const std::filesystem::path& screen, std::string* problem = nullptr);

    // The PC's clock (MFGetSystemTime, 100 ns units) at time 0 of screen.mov.
    LONGLONG startTime() const { return t0_; }
    const VideoFormat& format() const { return format_; }
    // The part of the desktop recorded, in physical pixels: the screen, or the shared window where it is now.
    RECT area() const;
    // "screen", "window" or "test pattern".
    const char* kind() const { return kind_; }
    // Whether the computer's sound can be heard at all (false on a PC with no sound device).
    bool hearsComputer() const { return loopback_ != nullptr; }
    // The main mic's sound, for the first sound track.
    void addMic(const int16_t* samples, UINT32 frames, LONGLONG time);
    // The computer's sound on or off from now on. Off writes silence, so it can come back at any moment.
    void setSound(bool on) { soundOn_ = on; }
    bool soundOn() const { return soundOn_; }
    // The first thing that went wrong while recording, if anything did.
    std::string problem() const;
    // Pictures written so far, and how many were new from the screen rather than repeats of a still one.
    long long pictures() const { return pictures_; }
    long long newPictures() const { return newPictures_; }
    // How long turning one screen picture into NV12 takes on average, in milliseconds.
    double convertMs() const { return converted_ ? double(convertTime_) / converted_ / 10'000.0 : 0; }
    // Ends the file properly at this moment. Called by the destructor if not called before.
    void stop();

private:
    struct Capture;
    void run();
    void step(LONGLONG now);
    void onComputerSound(const int16_t* samples, UINT32 frames, LONGLONG time, bool silent);
    void keepComputerSoundGoing(LONGLONG now);
    void note(const std::string& problem);

    Options options_;
    const char* kind_ = "screen";
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    std::unique_ptr<Nv12Converter> converter_;
    std::unique_ptr<Capture> capture_;
    std::unique_ptr<MovieWriter> writer_;       // screen.mov: the picture and the mic
    std::unique_ptr<MovieWriter> soundWriter_;  // screen-sound.m4a: the computer's sound
    std::unique_ptr<Mic> loopback_;
    VideoFormat format_;
    RECT monitorRect_{};
    mutable std::mutex areaLock_;
    RECT area_{};

    std::mutex writeLock_;  // every write to the file, from the picture, mic and computer sound threads
    LONGLONG t0_ = 0;
    std::vector<BYTE> picture_;  // the last picture, repeated while the screen is still
    bool havePicture_ = false;
    LONGLONG lastPicture_ = -1;  // file time of the last picture written
    long long micWritten_ = 0;
    long long soundWritten_ = 0;
    std::atomic<LONGLONG> lastSoundPacket_{0};
    std::atomic<bool> soundOn_{false};
    std::atomic<long long> pictures_{0}, newPictures_{0};
    LONGLONG convertTime_ = 0;
    long long converted_ = 0;
    std::vector<BYTE> pattern_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> patternTexture_;
    int tick_ = 0;

    std::thread thread_;
    std::atomic<bool> stopping_{false};
    bool stopped_ = false;
    mutable std::mutex problemLock_;
    std::string problem_;
};

}  // namespace capture
