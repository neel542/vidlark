# Working on Vidlark with Claude Code

Vidlark is a free, open source recorder for videos. One button records your camera, your mic and
your screen as separate files that stay in sync. When you stop, it finishes the take: it lines the
files up by sound, makes `video.mp4`, and writes a transcript, YouTube chapters and a list of
retakes. This file tells Claude Code how the project fits together, so anyone can ask for a change
in plain words.

## The parts

- `Sources/Vidlark/`: the Mac app (Swift, SwiftUI, AVFoundation, ScreenCaptureKit).
  - `Studio.swift`: the app's state, the checks and the take.
  - `PanelView.swift`, `SourcesView.swift`: the main window.
  - `SettingsView.swift`: Settings.
  - `RecordingPill.swift`: the recording box, the face box and its framing.
  - `Phone.swift`, `PhonePage.swift`, `PhoneCodeView.swift`: phones over Wi-Fi.
  - `Mics.swift`: extra microphones.
  - `Theme.swift`: colours and type. `DESIGN.md` explains the look.
- `Sources/vidlark-finish/`: the after-stop tool the app runs on every take. It calls ffmpeg and
  whisper-cpp.
- `windows/`: the Windows app (C++20, CMake, Media Foundation, a WebView2 window whose screens are
  in `windows/app/ui/`) and a C++ port of the after-stop tool in `windows/finish/`. See
  `windows/PLAN.md`.
- `website/`: the static website at vidlark.vercel.app. `website/DESIGN.md` explains its look.
- `Tests/`: `run_tests.sh` runs the after-stop tool on test takes and checks every file it makes.
- `PLAN.md`: the take folder contract, every file a take leaves and what is in it. The Mac and
  Windows apps write the same folder, so a change to it is a change to both.

## Build and check on a Mac

- Needs an Apple silicon Mac on macOS 15 or later, Xcode's command line tools, and
  `brew install ffmpeg whisper-cpp`.
- Build the app with `bash Tools/build.sh`, then `open dist/Vidlark.app`. Screen recording needs a
  free Apple Development certificate (see README.md). If Vidlark is already open, check it is not
  recording before building, because the build replaces it.
- Run the tests with `SKIP_FIXTURE=1 bash Tests/run_tests.sh` (leave out `SKIP_FIXTURE=1` the first
  time, so the test videos get built). The transcript checks need the whisper model; without it
  they fail, and that is expected.
- See the screens without recording anything: `dist/Vidlark.app/Contents/MacOS/Vidlark --snapshot <folder>`.

## Build and check on Windows

- Needs Visual Studio 2022 or its Build Tools (Desktop development with C++) and CMake.
- `cmake -S windows -B build -A x64`, then `cmake --build build --config Release`, then
  `build\Release\vidlark-tests.exe`.
- GitHub Actions builds and tests it on every push (`.github/workflows/windows.yml`).

## How changes should feel

- Plain words in everything a person reads, one short sentence per setting, and no em dashes.
- Never lose a take. Anything that touches recording keeps the files crash safe and every source
  in sync.
- The app's own windows never appear in a recording.
- Keep it light: the camera, previews and phones work only while something needs them.
- Ask before installing a tool or changing a system setting, and say what it is for.
- After a change, build it, run the tests, and say plainly what was checked and what was not.
