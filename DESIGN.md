# Design

A field audio recorder face. Graphite body, engraved labels, lamps with a hot centre, a segmented meter, and one red record button. The panel holds only what a take needs (the picture, the sources, the button); everything else lives in Settings, each option with one plain sentence on what it does. Dark because the screens face the presenter while she is lit for camera. The contract is in the opening comment of `Sources/AVARecorder/Theme.swift`.

## Tokens (`Palette` in Theme.swift)

| Token | Hex | Use |
|---|---|---|
| body | #0E1110 | Window ground, with a 3.5% white top light |
| face | #151917 | The input panel |
| raised | #1B201E | Selected rows, the key when not green |
| well | #070908 | Viewfinder |
| glass | #050706 | Prompter |
| hairline | white 7.5% | Every 1px rule and border |
| engraved | #86918B | Uppercase labels, secondary text |
| dim | #A3ADA8 | Guidance text |
| ink | #ECF1EE | Primary text |
| signal | #3DCC80 | Live and good: lamps, meter, links, the current prompter line, a picked choice, a switch that is on |
| amber | #E8B34B | Needs attention, over time |
| red | #F04E3E | The record button (a disc ready, a square rolling), the rolling lamp, failed lamps, and the meter's top 10% |

## Type

The system sans for everything. Engraved labels are 9.5pt semibold, uppercase, with 1.3 tracking. Values are 12.5pt. The title is 15pt semibold. Timecode is 44pt light with tabular figures. Prompter text scales with the strip height: the base is 19% of the height, capped at 54pt, times the Text size setting (0.8, 1, 1.3 or 1.6), with prose at 0.86 of the base and the next line at 0.5 at 30% white. The strip itself is 230pt tall times the Text size, so bigger words get room instead of shrinking. The current line gets the room first; the faint next line shows only when a whole line of it fits under it.

## Components

- **Lamp:** 7pt, with a radial hot centre and no halo. States: ok, warn, fail, off.
- **Source row:** a 30pt rounded glyph well (video.fill, mic.fill, display; a numbered badge for Camera 2 and on), the source's name over what it is now ("iPhone Camera · 1920 × 1080", "Wireless Mic Rx · USB"), a lamp, and an up-down chevron. The whole row opens a menu to change it. The mic row carries the meter under it.
- **Add:** a small capsule "+ Add" above the sources: another camera. The Screen row is always there, since every take starts on her face and shares the screen when she presses Screen.
- **Attention card:** at most one, under the sources: a lamp, one plain sentence of what is wrong, and green text buttons for the fix ("Turn off", "Allow") and "What is this?", which opens the Settings page that explains it. Tinted 8% with the lamp's colour.
- **Settings:** its own window (gear in the header, Command-Comma). A 224pt sidebar of pages with SF Symbols, the selected one raised with a green glyph and an amber lamp on a page with something on that usually should not be. Each page: a 22pt title, one intro sentence, then one face panel of rows. A row is a 13pt semibold name over a 12pt plain sentence (380pt measure), its control on the right: the app's own switch (green when on), segments (green when picked), a value menu, or a small capsule button.
- **MeterBar:** 40 segments over the top 60 dB. Green up to -15 dB, amber to -6 dB, red above that. Unlit segments are at 13% opacity.
- **Recording box:** a quiet full-width row on top, the macwindow glyph with "Back to the recorder", or "Hide the recorder" while it is up, which shows the recorder as a floating panel on the desktop in front, then a Me | Screen switch (the picked half green), then, while the screen is recorded, a full-width "Mac sound: Off / Every app / Only <App>" row (speaker glyph green when on; a click anywhere opens the list Off, Every app, Only <App>), then the controls row: lamp, time, meter, the face-in-video toggle, the red stop square. Under the controls, only while the video shows the screen, her face picture (never during Me, when her camera already fills the screen, and not while the face bubble is in the video). The controls are on top so they never move when the picture comes and goes.
- **Share chooser:** a floating panel titled "What to share": Entire screen / A window segments, a grid of real thumbnails (app icon, window name, app name, or "<App>, on another desktop"; a green ring when picked), then a footer: "Your pick is remembered for next time." on the left, Cancel and Share on the right. It opens with the last pick already picked. No tick boxes: the Mac's sound lives in the recording box, and asking each time lives in Settings. Double-click a picture to share it.
- **Resting camera:** when no preview has been seen for 15 s, or the app has been in the background for a minute, the camera and mic rest. The viewfinder dims (62% black) with a moon glyph, "Camera resting to save power" and "Click here to wake it"; the Camera and Microphone rows read "· Resting" with an off lamp, and the meter and "Say something" hide. Waking either wakes both. Never during a take.
- **Source detail:** at most two quiet lines, each cut in the middle only if it must be: the Screen row puts "With Google Chrome's sound" on its own line under the share label.
- **One label for the share choice:** "Entire screen: Samsung S24R35A" or "Google Chrome: Seller Central", the same in the Screen source, its menu, and Settings.
- **RecordKey:** a camera's record button: an 84pt white ring around a 68pt red disc. Pressed, the disc closes into a 32pt red square on a spring, and opens again on stop. Grey when not ready; a green progress arc fills the ring while finishing.
- **Prompter rail:** one segment per line (spent at 35% green, current solid green), with the section and position on the left and line time against budget on the right. While the prompter follows her voice, a lamp leads the left side, lit while she is heard.
- **Spoken words:** while following, the words of a prose line she has already said turn signal green at 50%, and the rest stay full ink, so the edge between them is where she is.

## Motion

- 0.2 to 0.24 s ease-out on state changes.
- A prompter line enters 14pt from below while fading in.
- The record disc closes into a square on a 0.32 s spring.
- The face framing holds still inside a still zone (10% of the crop) and glides to a new framing over 0.5 s from wherever the picture is on screen, so a framing that changes mid-glide never jumps.
- Me and Screen: her camera grows out of the face bubble to fill the screen, or shrinks back in, over 0.5 s ease-in-out.
- By itself, the prompter scrolls the whole script up continuously at the chosen words a minute, under a 3pt green reading mark, fading out at the top and well above the rail.
- Nothing else moves.
