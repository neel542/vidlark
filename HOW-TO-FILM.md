# Filming with AVA Recorder

## Once, before the first video

1. Open `dist/AVA Recorder.app`. Allow the camera and the microphone when macOS asks.
2. Click the red **Record** row and allow screen recording in System Settings. Quit and reopen the app.

## Each filming day

1. Put the iPhone on the tripod with the rear camera facing the presenter. Plug the mic receiver into the Mac.
2. Open AVA Recorder. It fills the monitor. Check that all five lamps are green:
   - Camera
   - Mic (say a few words so the meter moves)
   - Record (the screen that gets recorded)
   - Space
   - Power
3. Press the green key. The big window steps aside, so the presenter has the whole monitor for slides, screenshots and Seller Central.
4. In the top right corner, a small box shows her face, zoomed in automatically:
   - Click the picture to switch between her face and the whole camera view.
   - The minus button shrinks the box to a small pill, and the face button brings it back.
   - The square button stops the recording.
   - Neither the box nor any pop-up banner appears in the recording.
5. If she stumbles, she says **"retake"** and repeats the line. The edit finds it from the transcript.
6. After you stop, the big window comes back while it lines up the files and writes the transcript, chapters and retakes.

The prompter is built but switched off for now.

## Where the files go

`/Users/Shared/AVA Recordings/<date> <title>/recording-N/`

| File | What it is |
|---|---|
| camera.mov | the presenter on camera, with the mic |
| screen.mov | The recorded screen, with the same mic |
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
