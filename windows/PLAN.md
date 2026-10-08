# Vidlark for Windows: the plan

A native Windows version of Vidlark, in C++, with the same features and the same take folder as the
Mac app. Free, downloaded from GitHub Releases. No Microsoft Store.

## Decisions

- **C++20, no .NET.** Windows' recording APIs are native C++/COM underneath, so C++ calls them directly
  and ships as one small exe with nothing extra to install. MSVC builds it on GitHub Actions.
- **Screens in WebView2, recording in C++.** The panel, Settings and Recordings are HTML/CSS/JS in
  `app/ui/`, styled with the Mac app's palette (`Sources/Vidlark/Theme.swift`). WebView2 comes with
  Windows 11. The camera picture, face bubble and recording box are native windows drawn with
  Direct3D, because they show live video.
- **Same take folder, same files.** `camera.mov`, `screen.mov`, `mic-N.m4a`, `events.jsonl`, `sync.json`,
  `words.json`, `retakes.json`, `chapters.txt`, `video.mp4`, `report.md`, with the same JSON shapes, so a
  take looks the same whichever computer recorded it. Library: `%PUBLIC%\Videos\Vidlark Recordings`
  (the Windows match for the Mac's `/Users/Shared`, shared by every account on the PC).
- **H.264 on Windows**, not HEVC: HEVC needs a paid add-on on many PCs.
- **Windows 11 first** (one-app sound needs build 20348 or later). Windows 10 later if people ask.
- **ffmpeg and whisper ship in the download** (`tools\` next to `Vidlark.exe`); the speech model is
  downloaded on first use, as on the Mac.

## How each feature maps

| Feature | Mac (now) | Windows |
|---|---|---|
| Screen or one window | ScreenCaptureKit | Windows.Graphics.Capture (C++/WinRT) of the screen; one window is cut out of its screen and followed as it moves |
| App's own windows kept out | SCContentFilter | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on the panel and the recording box |
| Face bubble and Me in the video | windows let into the capture | the same: the stage and bubble windows (`app/overlay.cpp`, Direct3D through DirectComposition) are not excluded |
| Computer sound, every app | SCStream audio | WASAPI loopback, to `screen-sound.m4a` during the take, copied into screen.mov as its second sound track after Stop (Media Foundation's fragmented MP4 holds one sound track) |
| Sound from one app | a second SCStream | WASAPI process loopback (Windows 11) |
| Camera | AVCaptureSession | Media Foundation source reader |
| Writing files, 2 s pieces | AVAssetWriter | Media Foundation sink writer, fragmented MP4 |
| Several mics | AVCaptureSession each | WASAPI capture each |
| Phones over Wi-Fi | NWListener + TLS, PhonePage.swift | same page and record format; Winsock + mbedTLS |
| Live view, Anywhere | NWListener, cloudflared | same page; cloudflared for Windows |
| Face framing | Vision | Windows.Media.FaceAnalysis |
| Voice-following prompter | Speech | Windows.Media.SpeechRecognition (weaker, last) |
| After stop | vidlark-finish (Swift) | vidlark-finish (C++, `finish/`) |
| Global keys, clickers | Carbon, CGEventTap | RegisterHotKey, raw input |

## Steps

1. **Groundwork** (this branch): CMake project, the after-stop tool ported to C++ and passing the
   Mac's test suite, GitHub Actions building it on Windows, and a first window listing cameras,
   mics and screens.
2. **Camera and mics:** record `camera.mov` and `mic-N.m4a`, the timecode and meter, then run the
   finisher. First usable build.
3. **Screen** (built 8 Oct, branch `windows-screen`): `screen.mov` with the computer's sound, Me and Screen,
   the face bubble, the recording box kept out of the video. Details below.
4. **Phones and live view**, reusing the Mac app's web pages unchanged.
5. **The rest:** prompter, face framing, Recordings, Settings, checks.
6. **Beta, then release:** a zip on GitHub Releases, tested by 10 to 20 Windows users. The release job is
   ready (see Releasing); the first real-laptop test in [TESTING.md](TESTING.md) comes first.

## Step 3: the screen, as built

Every take starts on the camera, as on the Mac. During a take the panel has **Share screen**; it opens
the picker (Entire screen or A window, with a picture of each, the last pick remembered, and Include the
computer's sound). Then:

- The panel steps aside (minimised) and a small always-on-top **recording box** (`ui/box.html`, its own
  WebView2 window) shows the time, the level, Me and Screen, Face (the bubble in the video or not), Sound
  (the computer's sound on or off), Vidlark (the panel back, over the stage) and Stop. A click in the box
  hands the keyboard straight back to the app she was using.
- The **stage**, a click-through window over the shared screen or window, shows her camera across all of
  it, so screen.mov opens on her; 0.6 s later it shrinks into the **face bubble** (a 200 px circle, bottom
  right, draggable) and the video shows the screen. Me grows it back, Screen shrinks it, 0.5 s each way.
  The bubble shows the middle of the camera picture (face framing comes in step 5).
- `capture/screen.cpp` records the screen with Windows.Graphics.Capture, converts each picture to NV12 on
  the graphics chip (`capture/gpu.cpp`, at most 1920 on the long side, BT.709) and writes H.264 at a steady
  30 frames a second (a still screen repeats its last picture, so key frames stay 2 s apart and a crash
  loses at most about 2 seconds). The first sound track is the main mic, fed from the same mic as
  camera.mov, so the finisher lines the two files up by sound. The computer's sound goes to
  `screen-sound.m4a` and is copied into screen.mov after Stop; after a crash the two stay side by side.
- events.jsonl gets the Mac's lines: `screen-start` (`screen`, `screenName`, `macSound`), `sound`
  (`on`, `from: "every app"`), `bubble` (`visible`), `show` (`camera` or `screen`) on every click, and
  `screen-error` when something goes wrong. vidlark-finish then makes video.mp4 the Mac's way.

Different from the Mac, for now: sound from one app only (process loopback) is not built; a shared window
is cut out of the screen, so a window dragged over it shows too (the Mac records the window alone); the
bubble is one shape (a circle) and is not face-framed; the picker's window choice is found again by its
title; the box has no face picture.

Checked in CI (`tests/screen_check.py`, GitHub's Windows Server 2025 machine, which has no graphics chip,
no camera and no speakers): a real screen recording with the stage and bubble windows, a window kept out,
one window cut out of the screen, the frame rate, a crash, and video.mp4 from it. Not checkable there: the
computer's sound (no sound device, so that track is silence), a real camera in the bubble, and the panel,
picker and box running in the app itself. Those are in [TESTING.md](TESTING.md).

## Building

On Windows: `cmake -S windows -B build -A x64 && cmake --build build --config Release`.
On a Mac (the finisher and its tests only): `cmake -S windows -B windows/build -G Ninja && cmake --build windows/build`.
Check the C++ finisher against the Mac's suite: `FINISH_BIN=windows/build/vidlark-finish bash Tests/run_tests.sh`.
End to end on any computer with ffmpeg: `python3 windows/tests/e2e.py <path to vidlark-finish>`.

## Releasing

Pushing a tag named `windows-v<version>` (for example `windows-v0.1`) runs the Windows workflow on that
commit: the build and every test as usual, then the `release` job zips `dist\Vidlark` into
`Vidlark-Windows.zip` and publishes a GitHub prerelease titled "Vidlark for Windows <version> beta", with
`release-notes.md` as its text. The zip's name never changes. Nothing is published without the tag.

## Unsigned downloads

Without a code signing certificate, Windows SmartScreen warns the first time ("Windows protected your
PC", then More info, Run anyway). Free signing for open source projects exists (SignPath Foundation)
once the repo is public.
