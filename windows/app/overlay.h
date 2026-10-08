#pragma once
// Me and Screen on the screen itself, as on the Mac (Stage.swift and the face bubble). Click Me and her
// camera grows out of the face bubble to fill the whole recorded area; click Screen and it shrinks back
// into the bubble. Both windows are part of the screen recording (they are not kept out of it like
// Vidlark's other windows), so screen.mov, and so the finished video, has exactly what she saw.
//
// The stage is a click-through window over the recorded area; the bubble is a small round window in its
// bottom right corner that can be dragged. Both are drawn with Direct3D through DirectComposition, so
// they can be see-through, on a thread of their own that only draws while something shows.

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace app {

class Overlay {
public:
    // On the window thread: the windows are made here, hidden; Direct3D starts on first use.
    Overlay();
    ~Overlay();
    Overlay(const Overlay&) = delete;
    Overlay& operator=(const Overlay&) = delete;

    // The newest camera picture, NV12 with rows `pitch` bytes apart. From the camera's thread; it is
    // only copied while a window shows the camera.
    void camera(const BYTE* nv12, LONG pitch, UINT32 width, UINT32 height);
    bool wantsCamera() const { return wantsCamera_; }

    // Window thread only from here on.
    // Covers the recorded area, in physical pixels: a screen, or one shared window. `work` is the part
    // of that screen not under the taskbar; the bubble starts in its bottom right corner.
    void cover(const RECT& area, const RECT& work);
    // Me: her camera fills the area (growing out of the bubble when animated).
    void showMe(bool animated);
    // Screen: her camera shrinks back into the bubble, or fades away there when the bubble is off.
    void showScreen(bool animated);
    // Her face in the bubble over the screen, in the video, or not.
    void setBubble(bool visible);
    bool bubble() const { return bubbleOn_; }
    bool me() const { return me_; }
    // True once the stage has drawn her camera across the area, so the screen recording opens on it.
    bool ready() const { return ready_; }
    // The take is over: both windows go.
    void hide();
    // The stage and bubble windows, for checks.
    HWND stageWindow() const { return stage_; }
    HWND bubbleWindow() const { return bubbleWindow_; }
    RECT bubbleRect() const;
    std::string problem() const;

    // Where the bubble and the camera crop sit, and how the card looks, in desktop pixels.
    struct Look {
        float left = 0, top = 0, right = 0, bottom = 0;
        float radius = 0;
        float border = 0;
        float opacity = 0;
        float crop[4] = {0, 0, 1, 1};
    };

private:
    struct Gpu;
    static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    void run();
    void draw();
    Look fullLook() const;
    Look bubbleLook() const;
    void placeBubble();
    void wake();

    HWND stage_ = nullptr;
    HWND bubbleWindow_ = nullptr;
    std::unique_ptr<Gpu> gpu_;
    std::thread thread_;

    mutable std::mutex lock_;
    std::condition_variable woken_;
    bool quit_ = false;
    bool kick_ = false;
    RECT area_{};
    RECT work_{};
    RECT bubble_{};          // the bubble window, in desktop pixels
    bool bubblePlaced_ = false;
    bool covering_ = false;  // the stage is up
    std::atomic<bool> me_{false};
    std::atomic<bool> bubbleOn_{true};
    // The card moving between the bubble and the whole area.
    Look from_, to_;
    ULONGLONG moveStart_ = 0;
    ULONGLONG moveLength_ = 0;
    bool moveDone_ = true;
    std::atomic<bool> ready_{false};
    std::atomic<bool> wantsCamera_{false};
    float cameraAspect_ = 16.0f / 9.0f;

    // The newest camera picture, packed.
    std::vector<BYTE> luma_, chroma_;
    UINT32 cameraW_ = 0, cameraH_ = 0;
    unsigned long long cameraFrame_ = 0;
    std::string problem_;
};

}  // namespace app
