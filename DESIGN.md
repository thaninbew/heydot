# HeyDot design: Frost

Liquid Glass with pill components. Every value below lives in `Sources/HeyDot/Kit/UI/Frost.swift`; surfaces use
those pieces and never restyle a control locally.

## Materials

| Surface | Live (macOS 26) | Fallback (macOS 14 and 15, and QA renders) |
| --- | --- | --- |
| Windows (setup, Settings, dot designer) | `FrostBackdrop`: behind-window `NSVisualEffectView` the wallpaper tints, with three soft blobs in the theme's stops | The same blobs over a translucent wash |
| Popover | NSPopover's own material plus static blobs (`FrostBackdrop(animated: false, material: false)`) | Same |
| Buttons and chips | `glassEffect(.regular.interactive())`, tinted with the accent for the primary | Drawn capsule: accent gradient with a top highlight, or frosted white |
| Cards (`FrostCard`) | White 55 % (dark: 7 %) at radius 18 with a hairline | Same |

Offscreen captures can't draw glass or behind-window blur, so QA renders set `frostSnapshot` and show the
fallback over a sample wallpaper.

## Pills

`.frostButton(_:)` is the only way to style a button. One capsule, sized by HeyDot:

| Role | Use | Height | Padding | Width |
| --- | --- | --- | --- | --- |
| `.primary` | The one action that moves on (Get started, Continue, Sign in, Call, Save) | 46 | 24 | at least 132, grows with text |
| `.secondary` | Its alternative (Later, Try a call, Cancel) | 46 | 24 | at least 132 |
| `.round` | Back, Mute | 46 circle (54 in a call) | | |
| `.hangUp` | Hang up | 54 circle, red tint | | |
| `.chip` | Inline actions in cards and Settings, pause chips, Resume | 30 | 11 | fits the text |

A button row holds only back, Later where it applies, and the primary, centred with 12 pt between them. The tinted
primary is the recommendation; there is no badge. Hints sit above the row. Destructive chips use red text.
`FrostChoice` replaces segmented controls (a capsule track of chips, the chosen one filled with the accent).
Forms apply `FrostButtonStyle(role: .chip)` once to the whole form.

## Shape, spacing, type

- Radii: pills and chips are capsules; cards and the popover 18; text fields and option cells 14; banners, code
  previews and list rows 12; tiles 23 % of their side.
- Spacing: 4, 8, 12, 16, 24, 32 (`Frost.Space`).
- Type: setup titles 34 bold (welcome 40), tracking -0.6; supporting lines 16 secondary; body 15;
  captions and hints footnote, tertiary. Popover name 16 semibold.

## Accent

`Accent` derives one colour from the dot's colour: same hue and saturation, lightness moved into the luminance
band 0.145 to 0.183, where white text on it reads at 4.5:1 and it stands out at 3:1 on light and dark windows.
Text and marks on a dark window use `Accent.mark` (at least 4.5:1). The default logo, custom avatars and an
undesigned dot use Frost violet (#7B61FF, adjusted to #6E51FF). It tints the primary pill, focus rings, progress
dots, tuning rings and ticks, `FrostChoice`, the popover's level bars and listening dot, and option-cell
selection. The menu bar icon never uses it. Since round 7 the accent is the dot's own colour; see "Theme from dot"
for labels and marks.

## Theme from dot

`Theme` (`Kit/UI/Theme.swift`) derives the whole look from the dot, deterministically, in OKLCH. The goal is the
dot's own main colour, not a blend of its colours.

1. **Palette** from the design data, not pixels: the main colour (the dot body), then the accessory colour when it
   wears one in a colour (charcoal and brown count as ink). The HeyDot logo follows its violet main colour; imported avatars keep
   Frost exactly.
2. **Accent = the main colour itself** (`Accent.pill`). It is nudged in lightness only when it would vanish into a
   window: under 1.15:1 against the light window (near-white) or 1.3:1 against the dark one (near-black).
3. **Pill label** (`Accent.label`): white when it reads at 4.5:1 (navy, deep blue); otherwise a near-black ink
   tinted with the accent's hue (OKLCH L 0.16, C 0.02) when that reads at 4.5:1 (lime, yellow, coral, pastels);
   otherwise white at 3:1 or more, which pill labels meet as large text (15 pt bold), as on a mid red or violet.
4. **Marks** (focus rings, progress, rings, level bars, the listening dot, option selection; `Accent.mark`): the
   accent, moved in OKLCH lightness at the same hue and chroma only as far as 3:1 against the window needs. Lime
   deepens a little on a light window and stays as it is on a dark one.
5. **Backdrop:** the main colour leads. An even wash of it (14 % light, 10 % dark) sits under three blobs whose
   weights are 1.4, 0.6 and 0.45: the main colour at the dot's own lightness and chroma (light L 0.77 to 0.90, dark
   0.57 to 0.72, chroma at most 0.17, or 0.14 dark), then quieter supports (chroma 0.09, or 0.08 dark). The supports are:
   - one hue h: its split complement h + 150° and an analogous h - 40°;
   - two or more: the second colour and one hue in the middle of the widest gap on the hue wheel;
   - none (grey, near-black): a quiet slate theme, hues 262°, 222° and 302° at chroma 0.035, no wash.
   Every colour is brought into sRGB by reducing chroma at constant hue and lightness.

A new dot crossfades over 0.6 s (wash and blobs in the render server, views with a SwiftUI animation). Tests cover
a spread of dots for label contrast, mark contrast, the lightness and chroma bounds, hue placement, the main colour
leading, and determinism.

## Motion

Core Animation on plain layers only: the tile floats 9 pt with a 1.2° sway on a 6 s loop, two blobs drift on 26 s
and 32 s loops, rings follow the microphone level only while tuning listens. Nothing animates in the popover or
while idle in the menu bar; closing a window releases its content, so all motion stops. Reduce Motion turns the
float and drift off. State changes use 0.12 to 0.2 s ease-out.

## Icons

SF Symbols only, regular weight, sized to the text beside them. Icon-only buttons carry an accessibility label and
a tooltip.

## Native by design

Kept native because macOS draws them or users expect them: menus (pause timer menu, microphone list), steppers and the time picker, switches, Settings' inline text fields, the grouped Settings form
itself, the microphone permission prompt, the import file panel, ChatGPT's own page in the sign-in window, and
tooltips. HeyDot's main menu (Quit, Close Window, Edit) is never shown, since HeyDot is a menu bar app, but its
shortcuts work in every HeyDot window.

## Open-cradle logo

The default mic uses round 3’s owner-selected “8. Open cradle” geometry on the same 96-unit grid.
The flat violet body uses same-family eyes derived with `Accent.ink`; menu bar templates use
wider-set 10-unit eye holes and a 4-unit gutter. The welcome and default tiles use the designer’s
original violet glass PNG, embedded in the executable so signed assembly needs no resource bundle.

`Kit/Resources/Logo8_{1024,32,16}.png` come from the marketing design’s
`logos-r3/r8-open-cradle/icon-{1024,32,16}.png` (generator `src/r3-mic.mjs`).
The 16/32 PNGs were rendered from `icon-small.svg`. Neither `rsvg-convert` nor `resvg`
is installed on the implementation host; intermediate iconset sizes downsample the provided
lossless master with AppKit. `--render-icon DIR` writes those reps for build-app’s `iconutil` step.
`--qa-render DIR --logo-only` renders light/dark welcome, default popover, 16/18/32 px glyphs
and the iconset without launching the app normally.
