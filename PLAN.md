# Vidlark

A native Mac app for filming YouTube videos. It replaces Loom. It records the face, the voice and the slides in one take, shows the presenter a prompter under the lens, and hands tidy files to the `video-edit` skill.

## How a filming day works

- The presenter sits at the MacBook. The iPhone is mounted on top of the prompter screen with its rear camera facing them, connected as a Continuity Camera.
- Her mic receiver plugs into the Mac.
- Neel runs the app: he picks the script, checks the setup and presses Start and Stop. He also handles the lighting.
- The prompter sits directly under the iPhone lens and is never recorded. It shows the hook word for word, then one bullet at a time.
- The content (PowerPoint, Seller Central and so on) is on the recorded screen.
- One key moves the prompter forward, even while PowerPoint is in front.

## Features (agreed 4 Oct 2026)

| # | Feature | Notes |
|---|---|---|
| 1 | One Start button | Camera, mic and screen start and stop together |
| 2 | Prompter | The hook word for word, then one bullet at a time. The advance key is the backtick key (top left of the keyboard, under Esc); Shift plus backtick goes back. It also follows her voice, on the Mac only: prose moves on when she reaches the end of the line, a bullet when she is clearly talking about the next one. The key always works, and the panel's Prompter row can set it to Key only |
| 3 | Never loses a take | Both files are written in 2-second fragments, so a crash keeps everything up to the last 2 seconds |
| 4 | Markers on every switch | App switches and prompter sections are logged and become chapters |
| 5 | "Retake" word | Saying "retake" out loud is found in the transcript and listed with its time |
| 6 | No pop-ups in the video | Notification Center is cut out of the screen recording |
| 7 | Check before recording | Shows the camera picture, mic level, disk space, battery and permissions |
| 8 | Auto-naming and filing | `/Users/Shared/Vidlark Recordings/<date> <title>/recording-N/`. Shared, so it works from a second Mac user account too |
| 9 | Pace and time | Elapsed time against the target length, plus a per-section time budget on the prompter |
| 10 | Load the script | Drop in a `.md` or `.txt` file, or paste the text |
| 11 | Simple for the presenter | They only ever see the prompter |
| 12 | Batch day | A queue of videos for the day; the next one loads after each finishes |
| 13 | Extra cameras | Added 4 Oct: any other camera can record its own file (`camera-2.mov` on) next to the main one, with the same mic for sync |
| 15 | Face in video, any shape | Added 4 Oct: circle, square, oval or wide. The camera file is always separate, so the shape can also change in editing |
| 16 | Camera watchdog | Added 4 Oct: if camera.mov stops growing for 6 seconds the take stops and says so. Every preview (panel, face box, bubble) shows copies of frames from one data output (`CameraFeed`), never an `AVCaptureVideoPreviewLayer`: with preview layers, 10 of 11 test takes lost the camera picture within a second of starting |
| 17 | Camera first, share later | Added 4 Oct: the Record row can start a take with only the camera; the face box's Share button records the screen from then on, after a confirmation, with the Mac's sound as an option. Never shared means no screen.mov |
| 18 | Transcript tick box | Added 4 Oct: unticked runs `vidlark-finish --no-transcribe --no-chapters`; sync and the report are still made |
| 19 | Countdown beeps | Added 4 Oct: a beep on 3, 2 and 1, a higher one on go. Since 6 Oct the count comes before the files open, so it is not in the recording, and the record button cancels it |
| 20 | Recordings page | Added 4 Oct: every take with a thumbnail, search, filters, rename, save a copy and delete to Trash. Click a take to watch it in the app; Camera and Screen switch at the same moment of the take |
| 21 | Me and Screen | Added 4 Oct: a two-way switch in the face box. Me grows her camera out of the bubble to fill the recorded screen (a click-through window, `Stage`, that is part of the screen recording); Screen shrinks it back in 0.5 s. `vidlark-finish` makes `video.mp4` from screen.mov, and from camera.mov before a camera-first share (AVFoundation, HEVC, the screen's shape up to 1920 wide). Previews only get frames while they can be seen |
| 22 | One window | Added 5 Oct: "What to share" chooser (Entire screen / A window, real thumbnails), the last pick remembered and already picked next time; windows on other desktops (full screen apps) listed too, brought forward when shared. From 5 Oct every take starts on the face and the screen is shared with Screen. One window is captured from its display with only it and the stage and bubble windows included, cropped to it (`sourceRect`), and followed if it moves |
| 23 | Mac sound, any moment | Added 5 Oct: the screen recorder always listens and writes silence while off; "Only <App>" uses a small stream of its own. "sound" lines in events.jsonl |
| 24 | Prompter by itself | Added 5 Oct: scrolls at Slow, Medium or Fast (110, 140, 170 words a minute); Text size Small to Extra large; can be shown during takes |
| 25 | Phone over Wi-Fi | Added 6 Oct: any iPhone or Android phone, any account, no app. The link uses the Mac's Wi-Fi address (Android often cannot resolve .local). As the main camera (Camera row) or another camera (+ Add, extras record camera-N.mov the same way). The Mac serves a page over TLS on port 8791 (its own certificate from /usr/bin/openssl, read into memory only) behind a secret link shown as a QR code. The browser makes H.264 with WebCodecs, times each picture on the Mac's clock and posts small batches; camera.mov keeps the pictures as they came, with the Mac's mic, and a decoded copy feeds the previews, face framing and live page, only while one shows it. Picked in the Camera row's menu; `--self-test` with VIDLARK_CAMERA=phone, phone-extra or phones (two phones). Since 6 Oct, later: up to four phones at once (`/<secret>/<n>/`, camera IDs ava.iphone.wifi and ava.phone.2 to 4), each another angle; phones filming other angles take the main recorder's mic samples instead of opening a capture session each. The phone picks Wide (1920 x 1080) or Tall (1080 x 1920), drawn cover-cropped so turning the phone never changes the shape, locked while recording; the page goes full screen on Start camera (the Fullscreen API and an orientation lock where the browser has them, Android and iPad; a fixed full-page view on iPhone) |
| 26 | More microphones | Added 6 Oct: + Add, Another microphone: any mic the Mac sees (its own AVCaptureSession, `MicRecorder` in Mics.swift) or a phone's mic over Wi-Fi (`PhoneLink.micID(n)`, ava.phone.n.mic): the page sends 16-bit samples (an AudioWorklet, `mic.js`), numbered so they are timed by their place in the stream. Each records `mic-N.m4a` (AAC), gaps filled with silence, ending at Stop. A phone can film and record its sound, or be a mic only (no viewfinder). The phone's mute is one switch shared with the Mac, the last flip wins, and muted, the page stops the mic track. "Use for the video's sound" picks the mic the finished video uses; the take viewer's Sound plays any mic under any picture. Phones filming other angles stand by between takes (reply `send:false`): the picture stays on the phone, nothing is encoded or sent until the 3, 2, 1. `--self-test` with VIDLARK_MICS=phones,phone-only,same, VIDLARK_VIDEO_MIC=first and VIDLARK_MUTE=6:1:on; `Tools/fake-phone.js` stands in for the phones without a browser |
| 14 | Live view | Added 4 Oct: a no-login web page with every camera, the screen while recording, the mic level and the checks. Served by the Mac on port 8790 behind a secret link; Anywhere mode adds a Cloudflare quick tunnel. Pictures are only made while someone watches |

Not building: the Shorts cutter, and iPhone remote control.

## Parts

- `Sources/Vidlark`: the SwiftUI app.
- `Sources/vidlark-finish`: a command-line tool the app runs after every Stop. It can also be run by hand on any recording folder.
- `Tools/build.sh`: builds `dist/Vidlark.app`.

## Recording folder contract

The app writes these files:

- `camera.mov`: the iPhone video plus the mic.
- `camera-2.mov`, `camera-3.mov` and on: extra cameras, each with the same mic, in the order they were added. Only when extra cameras are picked.
- `mic-2.m4a`, `mic-3.m4a` and on: extra microphones (a mic the Mac sees, or a phone's), AAC, in the order they were added. Each runs from the take's start to Stop, silent where a phone was muted or its Wi-Fi dropped. No file when a mic sent nothing all take.
- `screen.mov`: the recorded screen plus the same mic (the shared audio is what allows exact sync). With the Mac's sound ticked, that is a second sound track; the mic is always the first. In a camera-first take it starts when the screen was shared, and is missing if it never was.
- `events.jsonl`: one JSON object per line, written live. `t` is seconds since `camera.mov` started.
  - `{"t":0,"type":"start","wall":"<ISO8601>","title":"...","targetMinutes":15,"camera":"camera.mov","screen":"screen.mov","extraCameras":[{"file":"camera-2.mov","name":"..."}],"extraMics":[{"file":"mic-2.m4a","name":"Phone 1","connection":"Over Wi-Fi"}],"videoMic":"mic-2.m4a"}`. `"screen":""` means a camera-first take; `"videoMic":""` means the video uses the main mic.
  - `{"t":4.2,"type":"mute","file":"mic-2.m4a","on":true,"by":"phone"}`: a phone's mic muted or unmuted, on the phone or from the Mac.
  - `{"t":20.4,"type":"mic-start","file":"mic-2.m4a","at":-0.79}`: where the mic file begins in camera time, written as it closes; used when its sound does not match the main mic's. `mic-error` says why a mic file was not made.
  - `{"t":20.5,"type":"camera-dropped","file":"camera-2.mov","pictures":{"out of order":3}}`: a phone's pictures that could not go into its file, and why.
  - `{"t":0,"type":"show","what":"screen"}`: what the video shows, `"camera"` or `"screen"`. One at the start, then one per click of Me or Screen.
  - `{"t":4.1,"type":"sound","on":true,"from":"Google Chrome"}`: the Mac's sound switched; "from" is "every app" or one app's name.
  - `{"t":125.3,"type":"screen-start","screen":"screen.mov","screenName":"...","macSound":false}` when the screen is shared in a camera-first take. The finisher matches the screen's sound against the camera's from just before this moment.
  - `{"t":61.0,"type":"camera-error","file":"camera-2.mov","message":"..."}` when an extra camera stops early. The take carries on.
  - `{"t":3.2,"type":"card","index":1,"section":"Hook","text":"..."}`. Every move after the first card adds `"by":"key"` or `"by":"voice"`, and so does `{"type":"end"}`.
  - `{"t":95.0,"type":"listen-error","message":"..."}` when speech recognition stops working. The take carries on with the key.
  - `{"t":40.1,"type":"app","name":"Microsoft PowerPoint"}`
  - `{"t":900,"type":"stop"}`
- `script.md`: a copy of the script used.

`vidlark-finish <folder>` first takes the padding out of `camera.mov` (and `camera-2.mov` and so on): the Mac's camera writer starts every chunk of picture or sound on a 16 KB boundary and fills the gap with zeros, which was 35% to 44% of the file on 5 Oct. Only the chunk table changes; every packet, timestamp and edit stays as it was, and anything unusual leaves the file alone. `vidlark-finish --tidy <movie>` does it to one file. Then it adds these files:

- `sync.json`: `{"screenOffsetSec":x,"method":"audio","confidence":c}`. `camera_t = screen_t + screenOffsetSec`. With extra cameras it also has `"cameras":[{"file":"camera-2.mov","offsetSec":y,"method":"audio","confidence":c}]`, where `camera_t = camera-2_t + offsetSec`. With extra mics, `"mics":[{"file":"mic-2.m4a","offsetSec":z,"method":"audio" or "clock","confidence":c}]`: by sound when it matches the main mic's with confidence 0.6 or more, otherwise by the Mac's clock (`mic-start`), corrected by how far the clock was off for mics lined up by sound.
- `mic.wav`: the clean mic track, taken from `camera.mov` (48 kHz).
- `words.json`: `[{"word","start","end"}]` on the camera timeline (the same shape `video-edit` uses).
- `chapters.txt`: in YouTube format, or empty if fewer than 3 chapters of at least 10 seconds.
- `retakes.json`: `[{"t","context"}]`.
- `video.mp4`: the finished video: screen.mov (which holds the Me and Screen motion), with camera.mov before a camera-first share. Its sound is the picked mic (`videoMic`) when one was picked and could be lined up, otherwise camera.mov's. Made when there is a screen.mov, or for a camera-only take when another mic was picked (camera.mov's picture as it was, with that mic's sound); `--no-video` skips it.
- `report.md`: a plain-language summary.

## Not yet checked

- Continuity Camera needs the iPhone and the Mac on the same Apple ID. Parked: a second Mac user account for the presenter is the plan.
- The video size Continuity Camera delivers. The app uses the largest the camera offers.
- Whether cutting out Notification Center hides banners on macOS 26. Test it with `display notification` during a recording.
- **Blocker found 4 Oct:** macOS 15 and later refuse screen recording to ad hoc signed apps, even after the switch is turned on in Settings. Camera and mic work. The app needs a free Apple Development certificate (Xcode > Settings > Accounts). `Tools/build.sh` uses one automatically once it exists.
