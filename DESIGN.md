# Design

A field audio recorder face. Graphite body, engraved labels, lamps with a hot centre, a segmented meter, and one lit key. Dark because the screens face the presenter while she is lit for camera. The contract is in the opening comment of `Sources/AVARecorder/Theme.swift`.

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
| signal | #3DCC80 | Live and good: lamps, meter, key, links, the current prompter line |
| amber | #E8B34B | Needs attention, over time |
| red | #F04E3E | The rolling lamp and ring only, plus the meter's top 10% |

## Type

The system sans for everything. Engraved labels are 9.5pt semibold, uppercase, with 1.3 tracking. Values are 12.5pt. The title is 15pt semibold. Timecode is 44pt light with tabular figures. Prompter text scales with the strip height: the base is 19% of the height, capped at 54pt, with prose at 0.86 of the base and the next line at 0.5 at 30% white.

## Components

- **Lamp:** 7pt, with a radial hot centre and no halo. States: ok, warn, fail, off.
- **Input row:** 38pt tall: lamp, engraved label (66pt column), then the value. When there is a choice, the value opens a menu. The Prompter row chooses Follows her voice or Key only.
- **MeterBar:** 40 segments over the top 60 dB. Green up to -15 dB, amber to -6 dB, red above that. Unlit segments are at 13% opacity.
- **RecordKey:** an 84pt hairline ring around a 62pt key. It is green when ready, a stop square inside a breathing red ring while rolling, and a green progress arc while finishing.
- **Prompter rail:** one segment per line (spent at 35% green, current solid green), with the section and position on the left and line time against budget on the right. While the prompter follows her voice, a lamp leads the left side, lit while she is heard.
- **Spoken words:** while following, the words of a prose line she has already said turn signal green at 50%, and the rest stay full ink, so the edge between them is where she is.

## Motion

- 0.2 to 0.24 s ease-out on state changes.
- A prompter line enters 14pt from below while fading in.
- The rolling ring breathes over 1.4 s.
- Nothing else moves.
