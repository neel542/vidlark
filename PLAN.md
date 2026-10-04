# AVA Recorder

A native Mac app for filming the presenter's YouTube videos. It replaces Loom. It records the face, the voice and the slides in one take, shows her a prompter under the lens, and hands tidy files to the `video-edit` skill.

## How a filming day works

- the presenter sits at the MacBook. The iPhone 15 is mounted on top of the prompter screen with its rear camera facing her, connected as a Continuity Camera.
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
| 8 | Auto-naming and filing | `/Users/Shared/AVA Recordings/<date> <title>/recording-N/`. Shared, so it works from the presenter's own Mac user account too |
| 9 | Pace and time | Elapsed time against the target length, plus a per-section time budget on the prompter |
| 10 | Load the script | Drop in a `.md` or `.txt` file, or paste the text |
| 11 | Simple for the presenter | She only ever sees the prompter |
| 12 | Batch day | A queue of videos for the day; the next one loads after each finishes |
| 13 | Extra cameras | Added 4 Oct: any other camera can record its own file (`camera-2.mov` on) next to the main one, with the same mic for sync |
| 15 | Face in video, any shape | Added 4 Oct: circle, square, oval or wide. The camera file is always separate, so the shape can also change in editing |
| 16 | Camera watchdog | Added 4 Oct: if camera.mov stops growing for 6 seconds the take stops and says so. Every preview (panel, face box, bubble) shows copies of frames from one data output (`CameraFeed`), never an `AVCaptureVideoPreviewLayer`: with preview layers, 10 of 11 test takes lost the camera picture within a second of starting |
| 17 | Camera first, share later | Added 4 Oct: the Record row can start a take with only the camera; the face box's Share button records the screen from then on, after a confirmation, with the Mac's sound as an option. Never shared means no screen.mov |
| 18 | Transcript tick box | Added 4 Oct: unticked runs `ava-finish --no-transcribe --no-chapters`; sync and the report are still made |
| 19 | Countdown beeps | Added 4 Oct: a beep on 3, 2 and 1, a higher one on go |
| 20 | Recordings page | Added 4 Oct: every take with a thumbnail, search, filters, rename, save a copy and delete to Trash. Click a take to watch it in the app; Camera and Screen switch at the same moment of the take |
| 14 | Live view | Added 4 Oct: a no-login web page with every camera, the screen while recording, the mic level and the checks. Served by the Mac on port 8790 behind a secret link; Anywhere mode adds a Cloudflare quick tunnel. Pictures are only made while someone watches |

Not building: the Shorts cutter, and iPhone remote control.

## Parts

- `Sources/AVARecorder`: the SwiftUI app.
- `Sources/ava-finish`: a command-line tool the app runs after every Stop. It can also be run by hand on any recording folder.
- `Tools/build.sh`: builds `dist/AVA Recorder.app`.

## Recording folder contract

The app writes these files:

- `camera.mov`: the iPhone video plus the mic.
- `camera-2.mov`, `camera-3.mov` and on: extra cameras, each with the same mic, in the order they were added. Only when extra cameras are picked.
- `screen.mov`: the recorded screen plus the same mic (the shared audio is what allows exact sync). With the Mac's sound ticked, that is a second sound track; the mic is always the first. In a camera-first take it starts when the screen was shared, and is missing if it never was.
- `events.jsonl`: one JSON object per line, written live. `t` is seconds since `camera.mov` started.
  - `{"t":0,"type":"start","wall":"<ISO8601>","title":"...","targetMinutes":15,"camera":"camera.mov","screen":"screen.mov","extraCameras":[{"file":"camera-2.mov","name":"..."}]}`. `"screen":""` means a camera-first take.
  - `{"t":125.3,"type":"screen-start","screen":"screen.mov","screenName":"...","macSound":false}` when the screen is shared in a camera-first take. The finisher matches the screen's sound against the camera's from just before this moment.
  - `{"t":61.0,"type":"camera-error","file":"camera-2.mov","message":"..."}` when an extra camera stops early. The take carries on.
  - `{"t":3.2,"type":"card","index":1,"section":"Hook","text":"..."}`. Every move after the first card adds `"by":"key"` or `"by":"voice"`, and so does `{"type":"end"}`.
  - `{"t":95.0,"type":"listen-error","message":"..."}` when speech recognition stops working. The take carries on with the key.
  - `{"t":40.1,"type":"app","name":"Microsoft PowerPoint"}`
  - `{"t":900,"type":"stop"}`
- `script.md`: a copy of the script used.

`ava-finish <folder>` adds these files:

- `sync.json`: `{"screenOffsetSec":x,"method":"audio","confidence":c}`. `camera_t = screen_t + screenOffsetSec`. With extra cameras it also has `"cameras":[{"file":"camera-2.mov","offsetSec":y,"method":"audio","confidence":c}]`, where `camera_t = camera-2_t + offsetSec`.
- `mic.wav`: the clean mic track, taken from `camera.mov` (48 kHz).
- `words.json`: `[{"word","start","end"}]` on the camera timeline (the same shape `video-edit` uses).
- `chapters.txt`: in YouTube format, or empty if fewer than 3 chapters of at least 10 seconds.
- `retakes.json`: `[{"t","context"}]`.
- `report.md`: a plain-language summary.

## Not yet checked

- Continuity Camera needs the iPhone and the Mac on the same Apple ID. Parked: a second Mac user account for the presenter is the plan.
- The video size Continuity Camera delivers. The app uses the largest the camera offers.
- Whether cutting out Notification Center hides banners on macOS 26. Test it with `display notification` during a recording.
- **Blocker found 4 Oct:** macOS 15 and later refuse screen recording to ad hoc signed apps, even after the switch is turned on in Settings. Camera and mic work. The app needs a free Apple Development certificate (Xcode > Settings > Accounts). `Tools/build.sh` uses one automatically once it exists.
