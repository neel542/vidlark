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

The system sans for everything. Engraved labels are 9.5pt semibold, uppercase, with 1.3 tracking. Values are 12.5pt. The title is 15pt semibold. Timecode is 44pt light with tabular figures. Prompter text scales with the strip height: the base is 19% of the height, capped at 54pt, with prose at 0.86 of the base and the next line at 0.5 at 30% white.

## Components

- **Lamp:** 7pt, with a radial hot centre and no halo. States: ok, warn, fail, off.
- **Source row:** a 30pt rounded glyph well (video.fill, mic.fill, display; a numbered badge for Camera 2 and on), the source's name over what it is now ("iPhone Camera · 1920 × 1080", "Wireless Mic Rx · USB"), a lamp, and an up-down chevron. The whole row opens a menu to change it. The mic row carries the meter under it.
- **Add:** a small capsule "+ Add" above the sources: another camera, or the screen when it is not recorded from the start.
- **Attention card:** at most one, under the sources: a lamp, one plain sentence of what is wrong, and green text buttons for the fix ("Turn off", "Allow") and "What is this?", which opens the Settings page that explains it. Tinted 8% with the lamp's colour.
- **Settings:** its own window (gear in the header, Command-Comma). A 224pt sidebar of pages with SF Symbols, the selected one raised with a green glyph and an amber lamp on a page with something on that usually should not be. Each page: a 22pt title, one intro sentence, then one face panel of rows. A row is a 13pt semibold name over a 12pt plain sentence (380pt measure), its control on the right: the app's own switch (green when on), segments (green when picked), a value menu, or a small capsule button.
- **MeterBar:** 40 segments over the top 60 dB. Green up to -15 dB, amber to -6 dB, red above that. Unlit segments are at 13% opacity.
- **RecordKey:** a camera's record button: an 84pt white ring around a 68pt red disc. Pressed, the disc closes into a 32pt red square on a spring, and opens again on stop. Grey when not ready; a green progress arc fills the ring while finishing.
- **Prompter rail:** one segment per line (spent at 35% green, current solid green), with the section and position on the left and line time against budget on the right. While the prompter follows her voice, a lamp leads the left side, lit while she is heard.
- **Spoken words:** while following, the words of a prose line she has already said turn signal green at 50%, and the rest stay full ink, so the edge between them is where she is.

## Motion

- 0.2 to 0.24 s ease-out on state changes.
- A prompter line enters 14pt from below while fading in.
- The record disc closes into a square on a 0.32 s spring.
- Me and Screen: her camera grows out of the face bubble to fill the screen, or shrinks back in, over 0.5 s ease-in-out.
- Nothing else moves.
