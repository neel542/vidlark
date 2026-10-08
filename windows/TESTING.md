# Testing Vidlark on a Windows laptop

The first real-PC test of the Windows build. GitHub's test machines have no camera, mic, speakers or
graphics chip, so they check the files, the screen recording and the finished video with made-up
pictures and sound. What only a real laptop can show is below: the camera, the mic, the computer's
sound, the screen sharing buttons, and how heavy a take is. It takes about 40 minutes.

## What the laptop needs

- Windows 11, 64-bit. Settings, System, About shows it.
- A webcam and a mic, built in or plugged in. A USB or Bluetooth headset as well, if there is one.
- Speakers or headphones, and a YouTube video to play, for the computer's sound.
- No admin rights and nothing to install.

## Getting the app onto it

1. Open https://github.com/neel542/vidlark/releases and download **Vidlark-Windows.zip** from the
   newest Windows beta. No sign-in is needed.
2. Right-click the zip, Extract All, Extract. Open `Vidlark.exe` in the folder.
3. Windows says "Windows protected your PC". Click More info, then Run anyway.

## The tests

| # | Do this | It passes when |
|---|---------|----------------|
| 1 | Open the app. | The window opens, the camera picture shows within a few seconds, and the meter moves when you talk. |
| 2 | Pick another camera or mic from the lists, if there is one. | The picture and the meter follow the new one. |
| 3 | Type the title "Test 1". Record 30 seconds: clap once at the start, then talk and move. Press stop. | The status says "Every file is ready." (it adds that there is no transcript yet, which is expected). Show the take opens a folder with `camera.mov` and `report.md`. In `camera.mov` the picture is smooth and the clap's sound lands on the clap. |
| 4 | Record 5 minutes while doing normal things. Open Task Manager during it. | `camera.mov` is 5 minutes long with no frozen picture. Write down Vidlark's CPU and memory in Task Manager. |
| 5 | Plug in a second mic and tick it under More microphones. Record 30 seconds. | The folder also has `mic-2.m4a`, and it plays. |
| 6 | Close the window during a take. | It asks before closing. |
| 7 | During a take, end Vidlark in Task Manager (Processes, Vidlark, End task). | `camera.mov` still plays, up to about the last 2 seconds before the crash. |
| 8 | Unplug the camera during a take, if it is a USB one. | The camera's lamp turns red. Write down what the take and its files do next: this case is not handled well yet. |

## Screen tests

| # | Do this | It passes when |
|---|---------|----------------|
| 9 | Title "Screen 1". Start a take. After 10 seconds click **Share screen**. In the picker keep Entire screen, tick Include the computer's sound, click Share. | Vidlark shrinks to a small box at the top right. Your camera fills the whole screen for a moment, then shrinks into a round bubble at the bottom right. |
| 10 | Play a YouTube video for 15 seconds. Then, in the box, click Me, wait 10 seconds, click Screen. Click Stop in the box. | Vidlark comes back and says "Every file is ready." The folder has `screen.mov` and `video.mp4`, and no `screen-sound.m4a`. `video.mp4` starts on your camera, changes to the screen when you shared it, shows you full screen where you clicked Me, and has the YouTube sound. Your voice matches your lips all the way through. |
| 11 | Title "Screen 2". Start a take, share the screen without the computer's sound. Drag the bubble to the top left. Click Face off, wait 5 seconds, click it on. Click Sound on for 10 seconds while a video plays, then off. Stop. | In `video.mp4` the bubble is where you dragged it, it is gone for those 5 seconds, and the video's sound is only there for those 10 seconds. |
| 12 | During a shared take, click **Vidlark** in the box, look at the panel, then minimise it again. Stop. | The panel shows over your camera. Neither the panel nor the box is anywhere in `video.mp4`. |
| 13 | Title "Window". Open a browser window, not full screen. Start a take, share it with **A window** in the picker. Move the window a little and resize it during the take. Stop. | `video.mp4` shows only that window, following it, with the bubble in its bottom right corner. |
| 14 | Record a 5 minute shared take while doing normal things. Open Task Manager during it. | `video.mp4` is 5 minutes long and smooth. Write down Vidlark's CPU, GPU and memory in Task Manager. |
| 15 | During a shared take, end Vidlark in Task Manager. | `screen.mov` still plays, up to about the last 2 seconds. The computer's sound is beside it in `screen-sound.m4a`. |

While the screen is recorded, Windows 11 may draw a thin yellow frame round it. That frame is not in the video.

## What to send back

- For each test: passed, or what happened instead.
- `report.md` from the Test 1 folder.
- A screenshot of anything that looks wrong, and any error message word for word.
- The CPU and memory numbers from test 4, and the CPU, GPU and memory numbers from test 14.
- `video.mp4` and `report.md` from the Screen 1 folder (or a link to them, as video.mp4 is big).
- The laptop's model and Windows version (Settings, System, About).

Takes are saved in `C:\Users\Public\Videos\Vidlark Recordings`. Delete the test takes afterwards.

Not in this build yet: phones, live view, the transcript (its speech model is not downloaded yet), sound
from one app only, and face framing in the bubble. They come in the next steps of [PLAN.md](PLAN.md).
