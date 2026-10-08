# Testing Vidlark on a Windows laptop

The first real-PC test of the Windows build. GitHub's test machines have no camera or mic, so
everything below is checked there except what only a real laptop can show: the camera, the mic,
and how heavy a take is. It takes about 20 minutes.

## What the laptop needs

- Windows 11, 64-bit. Settings, System, About shows it.
- A webcam and a mic, built in or plugged in. A USB or Bluetooth headset as well, if there is one.
- A GitHub sign-in, because the repo is private for now.
- No admin rights and nothing to install.

## Getting the app onto it

1. Sign in to GitHub on the laptop and open https://github.com/neel542/vidlark/actions/workflows/windows.yml
2. Click the newest run with a green tick. Under Artifacts, click **vidlark-windows** (about 68 MB).
3. Right-click the zip, Extract All, Extract. Open `Vidlark.exe` in the folder.
4. Windows says "Windows protected your PC". Click More info, then Run anyway.

## The tests

| # | Do this | It passes when |
|---|---------|----------------|
| 1 | Open the app. | The window opens, the camera picture shows within a few seconds, and the meter moves when you talk. |
| 2 | Pick another camera or mic from the lists, if there is one. | The picture and the meter follow the new one. |
| 3 | Type the title "Test 1". Record 30 seconds: clap once at the start, then talk and move. Press stop. | The status ends with "Every file is ready." Show the take opens a folder with `camera.mov` and `report.md`. In `camera.mov` the picture is smooth and the clap's sound lands on the clap. |
| 4 | Record 5 minutes while doing normal things. Open Task Manager during it. | `camera.mov` is 5 minutes long with no frozen picture. Write down Vidlark's CPU and memory in Task Manager. |
| 5 | Plug in a second mic and tick it under More microphones. Record 30 seconds. | The folder also has `mic-2.m4a`, and it plays. |
| 6 | Close the window during a take. | It asks before closing. |
| 7 | During a take, end Vidlark in Task Manager (Processes, Vidlark, End task). | `camera.mov` still plays, up to about the last 2 seconds before the crash. |
| 8 | Unplug the camera during a take, if it is a USB one. | The camera's lamp turns red. Write down what the take and its files do next: this case is not handled well yet. |

## What to send back

- For each test: passed, or what happened instead.
- `report.md` from the Test 1 folder.
- A screenshot of anything that looks wrong, and any error message word for word.
- The CPU and memory numbers from test 4.
- The laptop's model and Windows version (Settings, System, About).

Takes are saved in `C:\Users\Public\Videos\Vidlark Recordings`. Delete the test takes afterwards.

Not in this build yet: screen recording, phones and live view. They come in the next steps of
[PLAN.md](PLAN.md).
