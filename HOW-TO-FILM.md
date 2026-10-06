# Filming with AVA Recorder

## Once, before the first video

1. Open `dist/AVA Recorder.app`. Allow the camera and the microphone when macOS asks.
2. Click the red **Record** row and allow screen recording in System Settings. Quit and reopen the app.

## Each filming day

1. Put the iPhone on the tripod with the rear camera facing the presenter, screen locked, in landscape. Plug it into the Mac with a USB-C cable (it charges during the take and is steadier than wireless). It shows up as a camera on its own, through Continuity Camera, which only works when the Mac user and the iPhone are signed in to the same Apple ID. Plug the mic receiver into the Mac.
2. Open AVA Recorder. It fills the monitor. The **Sources** list shows what gets recorded, each with a lamp: click a row to change it, or **+ Add** for another camera or the screen. If something needs fixing, one note under the list says what and has the button that fixes it. Everything else is in **Settings** (the gear, or Command-Comma), where each option says in one sentence what it does. If the picture says **Camera resting to save power**, click it: the camera and mic switch off while the app sits unused in the background, and wake in about a second. The old rows, for reference:
   - Camera (its menu also has **Touch up the face**, which opens macOS Video Effects: switch on Studio Light once and it stays on)
   - Mic (say a few words so the meter moves)
   - Screen (what **Screen** shares during the take: the entire screen or one window. Every take starts on her face; the screen is only recorded once she presses Screen)
   - In video (the screen only, or the face in a circle, square, oval or wide shape)
   - After (tick it for a transcript and chapters; untick it for a quick video that only needs the files)
   - Mac (free space and power)
   - An amber **Effects** row means macOS Reactions are on. Click it and switch Reactions off: they cost battery, and with gestures on a thumbs-up puts balloons in the video.
3. Press the red button. The big window steps aside, so the presenter has the whole monitor for slides, screenshots and Seller Central. Three short beeps count down 3, 2, 1, and a higher beep means go. The clock starts at 00:00 on go.
4. In the top right corner, a small box holds the controls. While the video shows the screen it also shows her face, zoomed in automatically: it holds still while she talks and glides over when she really moves. While the video shows her (Me), her camera already fills the screen, so the box keeps only the controls:
   - Click the picture to switch between her face and the whole camera view.
   - The minus button shrinks the box to a small pill, and the face button brings it back.
   - The square button stops the recording.
   - **Me | Screen** says what the video shows. Click **Me** and her camera grows out of the face circle to fill the whole screen; click **Screen** and it shrinks back into the circle. The motion shows the click worked. The screen recording includes it, so the finished `video.mp4` is exactly what was on the screen, and nothing has to be cut by hand.
   - Every take starts on her face. The first click on **Screen** opens **What to share**, like Google Meet's: the **Entire screen** or **A window** (for example one Chrome window), picked from pictures, with the last pick already picked, so it is one click on **Share**. Windows on other desktops are there too, like Chrome in full screen; picking one moves the Mac to it. From then on the screen or window is recorded until the take stops, and Me and Screen switch at once.
   - **Back to the recorder** (the top row of the box) brings the AVA Recorder window up over whatever is on screen, without leaving the shared window's desktop. The recording carries on, and the window is never in the video. **Hide the recorder** puts it away.
   - Sharing one window, only that window goes into the video, even if something covers it; the face circle and Me stay inside it and follow it if it moves.
   - **Mac sound** (under Me | Screen, while the screen is recorded): click it and pick **Off**, **Every app** or **Only** one app, like Chrome playing a video, so notifications stay out. Change it at any moment of the take.
   - The face button puts the face in the video, in the shape picked in the **In video** row. Only one face shows at a time: while the face is in the video, this box shrinks to just the time, the level and the buttons. The box never appears in the recording, and neither does any pop-up banner.
   - If the camera stops sending pictures, the take stops within about 6 seconds and says so, so nobody films on without a camera.
5. If she stumbles, she says **"retake"** and repeats the line. The edit finds it from the transcript.
6. After you stop, the big window comes back while it lines up the files, makes `video.mp4` and writes the transcript, chapters and retakes. `video.mp4` is the one to upload; the camera and screen files stay for anyone who wants to edit.

The prompter is built but switched off for now.

## All recordings

The **Recordings** button at the top right of the panel (or Command-Shift-R) shows every take with a picture, its length and size. Click a take to watch it in the app: **Video** is the finished video, and switching to Camera or Screen stays at the same moment of the take, or open it in QuickTime Player. Search by name, filter by All, This week, Not finished, With screen or Camera only, and rename, save a copy or delete (deleted takes go to the Trash).

## More than one camera

Connect the second camera first: an iPhone, a USB webcam, or a real camera through an HDMI to USB capture card (Bluetooth cannot carry video). **Settings, Connect a camera** (also **+ Add, How to connect a camera…**) walks through each one and lists the cameras the Mac sees. Then press **+ Add** and pick it under **Another camera**. It gets its own row and its own file (`camera-2.mov`, then `camera-3.mov`), with the same mic in it so the finisher can line it up. The main camera stays the one in `camera.mov`, and the face box always uses it.

## More than one microphone

Press **+ Add** and pick a mic under **Another microphone**: a USB mic, a wireless kit's receiver, AirPods (they record at phone call quality, so a USB mic or a wireless kit sounds better), or a phone. A phone that already films an angle can record its own sound too ("Phone 1's mic", or "Record this phone's sound too" in its row's menu). **A phone as a microphone, with a QR code…** makes a spare phone a mic only: scan its code, tap Start microphone, Allow, and keep it close to the person talking, about a hand's width from the mouth.

Each mic gets its own row with its own level and its own file (`mic-2.m4a`, then `mic-3.m4a`). The video uses the main mic unless another row's menu says **Use for the video's sound**; that row then reads "The video's sound". Every mic records either way, so while watching a take, **Sound** at the bottom right plays any mic under any picture to hear which is best, and the files are all there for editing.

A phone's **Mute** is one switch shared by the phone and the Mac: tap Mute on the phone, or pick "Mute the phone's mic" in its row on the Mac, and both show it ("Muted on the phone" or "Muted from this Mac"). Either side can unmute. While muted the phone's mic is fully off, and its file stays silent for that stretch so it still lines up.

## Watching from another laptop or phone

The **Live** row shows the shoot on any browser, with no login: every camera, the screen while recording, the mic level and the checks. A camera picture that stops updating is marked "No new picture".

- **Listen** plays the mic as it is being recorded, about a quarter of a second late, to hear echo, hum or a loose cable. Use headphones: through speakers in the same room it echoes.
- **Pin** (or click a picture) makes that camera or the screen the big one, like pinning in Zoom; **Full screen** fills the screen with it. The picture the finished video is showing right now says **In the video**.
- During a take, **Reading now** shows the prompter line she is on.

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
| screen.mov | The recorded screen, with the same mic (and the Mac's sound as a second track, if it was on). Starts when the screen was shared |
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
