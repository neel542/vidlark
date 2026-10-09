# Contributing to Vidlark

Thank you for helping. Vidlark is small and friendly to newcomers: many changes here are made by asking [Claude Code](https://claude.com/claude-code) in plain words, and that is welcome.

## Ways to help

- **Report a problem** with the [bug form](https://github.com/neel542/vidlark/issues/new?template=bug_report.yml). Say what happened, on a Mac or on Windows, and the steps to make it happen again.
- **Suggest an idea** with the [idea form](https://github.com/neel542/vidlark/issues/new?template=feature_request.yml).
- **No GitHub account?** Use the [feedback page](https://vidlark.vercel.app/feedback).
- **Test the Windows beta** on a real laptop with [windows/TESTING.md](windows/TESTING.md). It takes about 40 minutes.
- **Change the code** and send a pull request (below).

Please never attach a recording you would not want public, and never post a live view link: the secret in it is the only key.

## How the project fits together

[CLAUDE.md](CLAUDE.md) is the map, for people and for Claude Code alike. In short:

- `Sources/Vidlark/`: the Mac app (Swift, SwiftUI, AVFoundation, ScreenCaptureKit).
- `Sources/vidlark-finish/`: the after-stop tool the app runs on every take. It calls ffmpeg and whisper-cpp.
- `windows/`: the Windows app (C++20, CMake, Media Foundation, WebView2) and a C++ port of the after-stop tool. [windows/PLAN.md](windows/PLAN.md) explains it.
- `website/`: the static website at vidlark.vercel.app.
- `Tests/`: the after-stop tool's tests.
- [PLAN.md](PLAN.md): the take folder contract, every file a take leaves and what is in it. The Mac and Windows apps write the same folder, so a change to it is a change to both.

## How changes should feel

These come from [CLAUDE.md](CLAUDE.md), and every change is checked against them:

- Plain words in everything a person reads, one short sentence per setting, and no em dashes.
- Never lose a take. Anything that touches recording keeps the files crash safe and every source in sync.
- The app's own windows never appear in a recording.
- Keep it light: the camera, previews and phones work only while something needs them.
- Ask before installing a tool or changing a system setting, and say what it is for.
- After a change, build it, run the tests, and say plainly what was checked and what was not.

## Build and test on a Mac

You need an Apple silicon Mac on macOS 15 or later, Xcode (for the free Apple Development certificate), and:

```bash
xcode-select --install
brew install ffmpeg whisper-cpp
```

The [README](README.md#install-on-a-mac) walks through the certificate. Without it the app still builds, but macOS refuses screen recording.

```bash
# Build dist/Vidlark.app, then open it. If Vidlark is open, check it is not recording first:
# the build replaces it.
bash Tools/build.sh
open dist/Vidlark.app

# Run the after-stop tool's tests. Leave out SKIP_FIXTURE=1 the first time, so the test videos get built.
SKIP_FIXTURE=1 bash Tests/run_tests.sh

# See every screen without recording anything: the app saves pictures of them into the folder.
dist/Vidlark.app/Contents/MacOS/Vidlark --snapshot /tmp/vidlark-screens
```

The transcript checks need the speech model (`~/.cache/whisper/ggml-large-v3-turbo-q5_0.bin`, see the README). Without it they fail, and that is expected.

To check the C++ after-stop tool from `windows/` on a Mac (this needs `brew install cmake ninja`):

```bash
cmake -S windows -B windows/build -G Ninja && cmake --build windows/build
FINISH_BIN=windows/build/vidlark-finish bash Tests/run_tests.sh
```

## Build and test on Windows

You need Visual Studio 2022 or its free Build Tools (with "Desktop development with C++") and CMake.

```bat
cmake -S windows -B build -A x64
cmake --build build --config Release
build\Release\vidlark-tests.exe
```

GitHub Actions builds and tests the Windows app whenever changes to `windows/` are pushed to the `windows` branch (`.github/workflows/windows.yml`), including a real screen recording on GitHub's Windows machine. That machine has no camera, mic, speakers or graphics chip, so anything needing those is checked by hand with [windows/TESTING.md](windows/TESTING.md).

## Working with Claude Code

Open the folder in Claude Code and describe the change in plain words. Claude reads [CLAUDE.md](CLAUDE.md), makes the change, builds and runs the tests. Before you send the change, ask it what it checked and what it could not check, and put that in the pull request.

## Opening a pull request

1. **Fork** the repository on GitHub (the Fork button at the top right), then clone your fork.
2. **Make a branch** for your change: `git switch -c short-name-for-the-change`
3. **Make the change, build it and run the tests** (above). For a change to a screen, take a picture with `--snapshot` or a screenshot.
4. **Commit** with a message that says what changed and why, in plain words.
5. **Push** your branch to your fork and open a pull request against `main`.
6. **In the pull request, say:**
   - what it changes, and why;
   - how you checked it: Mac or Windows, the tests you ran, and what you tried by hand;
   - what you could not check;
   - a picture, if a screen changed.

Keep each pull request to one change, so it is easy to review. If you change the take folder, update [PLAN.md](PLAN.md) and say whether the other app needs the same change.

Please do not commit build output (`dist/`, `.build/`, `build/`), recordings, or anything personal, such as names, email addresses or paths from your own computer.

## Licence

Vidlark is MIT licensed. By sending a pull request, you agree that your change is shared under the same [licence](LICENSE).
