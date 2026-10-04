# Filming with AVA Recorder

## Once, before the first video

1. Open `dist/AVA Recorder.app`. Allow the camera and the microphone when macOS asks.
2. Click the red **Record** row and allow screen recording in System Settings. Quit and reopen the app.

## Each filming day

1. Put the iPhone on the tripod with the rear camera facing the presenter, screen locked, in landscape. Plug it into the Mac with a USB-C cable (it charges during the take and is steadier than wireless). It shows up as a camera on its own, through Continuity Camera, which only works when the Mac user and the iPhone are signed in to the same Apple ID. Plug the mic receiver into the Mac.
2. Open AVA Recorder. It fills the monitor. Check the lamps are green:
   - Camera (its menu also has **Touch up the face**, which opens macOS Video Effects: switch on Studio Light once and it stays on)
   - Mic (say a few words so the meter moves)
   - Record (the screen that gets recorded from the start, or **Camera first, share the screen when ready**. Its menu also has **Include the Mac's sound**, for a video or a click played on the Mac)
   - In video (the screen only, or the face in a circle, square, oval or wide shape)
   - After (tick it for a transcript and chapters; untick it for a quick video that only needs the files)
   - Mac (free space and power)
   - An amber **Effects** row means macOS Reactions are on. Click it and switch Reactions off: they cost battery, and with gestures on a thumbs-up puts balloons in the video.
3. Press the green key. The big window steps aside, so the presenter has the whole monitor for slides, screenshots and Seller Central. Three short beeps count down 3, 2, 1, and a higher beep means go. The clock starts at 00:00 on go.
4. In the top right corner, a small box shows her face, zoomed in automatically:
   - Click the picture to switch between her face and the whole camera view.
   - The minus button shrinks the box to a small pill, and the face button brings it back.
   - The square button stops the recording.
   - **Me | Screen** says what the video shows. Click **Me** and her camera grows out of the face circle to fill the whole screen; click **Screen** and it shrinks back into the circle. The motion shows the click worked. The screen recording includes it, so the finished `video.mp4` is exactly what was on the screen, and nothing has to be cut by hand.
   - In a camera-first take, the first click on **Screen** asks first ("Share your screen?"), with a tick box for the Mac's sound. From then on the screen is recorded until the take stops, and Me and Screen switch at once.
   - The face button puts the face in the video, in the shape picked in the **In video** row. Only one face shows at a time: while the face is in the video, this box shrinks to just the time, the level and the buttons. The box never appears in the recording, and neither does any pop-up banner.
   - If the camera stops sending pictures, the take stops within about 6 seconds and says so, so nobody films on without a camera.
5. If she stumbles, she says **"retake"** and repeats the line. The edit finds it from the transcript.
6. After you stop, the big window comes back while it lines up the files, makes `video.mp4` and writes the transcript, chapters and retakes. `video.mp4` is the one to upload; the camera and screen files stay for anyone who wants to edit.

The prompter is built but switched off for now.

## All recordings

The **Recordings** button at the top right of the panel (or Command-Shift-R) shows every take with a picture, its length and size. Click a take to watch it in the app: **Video** is the finished video, and switching to Camera or Screen stays at the same moment of the take, or open it in QuickTime Player. Search by name, filter by All, This week, Not finished, With screen or Camera only, and rename, save a copy or delete (deleted takes go to the Trash).

## More than one camera

Plug in the second camera, open the **Camera** row's menu and pick **Also record** with its name. It gets its own row and its own file (`camera-2.mov`, then `camera-3.mov`), with the same mic in it so the finisher can line it up. The main camera stays the one in `camera.mov`, and the face box always uses it.

## Watching from another laptop or phone

The **Live** row shows the shoot on any browser, with no login: every camera, the screen while recording, the mic level and the checks. A camera picture that stops updating is marked "No new picture".

- **Home Wi-Fi**: works on the same Wi-Fi. The link stays the same, so bookmark it once.
- **Anywhere**: works from any internet connection through a free Cloudflare tunnel. The link changes every time it starts, so copy it again each time. Needs `cloudflared` installed.
- **Copy link** puts the link on the clipboard. On a Mac signed in to the same Apple ID, just paste it on the other laptop.
- The secret in the link is the only key. Anyone with the link sees her screen, including Seller Central, so never post it anywhere. **New link** stops every old link working.

## Where the files go

`/Users/Shared/AVA Recordings/<date> <title>/recording-N/`

| File | What it is |
|---|---|
| camera.mov | the presenter on camera, with the mic |
| camera-2.mov | A second camera, if one was added, with the same mic |
| video.mp4 | The finished video: what was on the screen, including her camera filling it for Me. Made when the take has a screen |
| screen.mov | The recorded screen, with the same mic (and the Mac's sound as a second track, if ticked). Starts when the screen was shared in a camera-first take |
| mic.wav | The clean voice track |
| words.json | The transcript, with the time of every word |
| chapters.txt | Ready to paste into the YouTube description |
| retakes.json | Every "retake", with its time |
| report.md | A plain summary of the recording |

Pop-ups such as WhatsApp or email banners are cut out of the screen recording, and so is the prompter.

## Script format

```
# Video title
Target: 15 min

## Hook
Written out word for word. It shows two sentences at a time.

## Section name
- One bullet per line
- She talks around each one
```
