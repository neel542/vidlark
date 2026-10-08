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
| Screen or one window | ScreenCaptureKit | Windows.Graphics.Capture (C++/WinRT) |
| App's own windows kept out | SCContentFilter | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` |
| Face bubble and Me in the video | windows let into the capture | the same: bubble windows not excluded |
| Computer sound, every app | SCStream audio | WASAPI loopback |
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
3. **Screen:** `screen.mov` with the computer's sound, Me and Screen, the face bubble, the recording box
   kept out of the video.
4. **Phones and live view**, reusing the Mac app's web pages unchanged.
5. **The rest:** prompter, face framing, Recordings, Settings, checks.
6. **Beta, then release:** a zip on GitHub Releases, tested by 10 to 20 Windows users.

## Building

On Windows: `cmake -S windows -B build -A x64 && cmake --build build --config Release`.
On a Mac (the finisher and its tests only): `cmake -S windows -B windows/build -G Ninja && cmake --build windows/build`.
Check the C++ finisher against the Mac's suite: `FINISH_BIN=windows/build/vidlark-finish bash Tests/run_tests.sh`.
End to end on any computer with ffmpeg: `python3 windows/tests/e2e.py <path to vidlark-finish>`.

## Unsigned downloads

Without a code signing certificate, Windows SmartScreen warns the first time ("Windows protected your
PC", then More info, Run anyway). Free signing for open source projects exists (SignPath Foundation)
once the repo is public.
