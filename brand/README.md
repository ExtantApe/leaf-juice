# LeafJuice brand

## The idea

A cool glass of juice on a sunny day: fresh, friendly and unfussy. Pastel green and cream do most of the
work, with one bright note of pink grapefruit, like the slice on the rim of the glass.

## Icon

A 16 × 16 pixel-art glass of green juice with a leaf, and a grapefruit wedge on the rim as the one pop of colour.
Adopted by the owner on 2026-11-14. The only drawn file is [`kit/mark.txt`](kit/mark.txt), a grid with its palette.
Everything else is built from it, so change that and rebuild rather than editing the outputs:

```bash
swift scripts/brand-kit.swift brand/kit
```

That checks every text and outline pair against WCAG first, and writes nothing if one fails. It puts the app icon
here in `brand/`, where the app build and the README look for it:

- `icon.svg`: the master. `icon-small.svg`: the master for 16 to 32 px, where the tile runs to the edge and each art
  pixel is a whole screen pixel.
- `icon-1024.png`: drawn from the master.
- `AppIcon.icns`: macOS, every size at 1× and 2×. `LeafJuice.ico`: Windows, 16 to 256.
- Pale pistachio tile, `#EDF5D6` to `#CDE3A5`, top to bottom.

Profile marks, banners, release images and the README header are built into `kit/out/`. [`kit/README.md`](kit/README.md)
lists them, with the platform sizes and where they came from.

## Fonts

Open-licence fonts only (owner, 2026-11-14). They live in [`fonts/`](fonts/), each with its SIL Open Font License,
and the builder refuses a font without one. **Lilita One** sets the name and **Fredoka** everything else. The app's
own interface uses the system font through Apple's APIs, which is a different thing from setting a logo in it.

## Color

**Green is structure. Grapefruit is the pop.**

- **Pink grapefruit** marks the one thing to do next: the main button on a page. Used sparingly, it stays meaningful. Never
  use it for state, warnings or decoration.
- **Juice green** is for icons, toggles, selection, focus and links.
- **Cream and sage** are the surfaces. Avoid pure black and neutral gray.
- **Danger is crimson, never coral**, and danger buttons are outlined. A destructive action should never look like the main action.

| Role | Light | Dark | Lowest contrast (light / dark) |
|---|---|---|---|
| Background | `#F8F6E9` | `#2A3225` | |
| Surface | `#FFFEF8` | `#343E2E` | |
| Raised | `#ECF1DA` | `#414D39` | |
| Border (cards and dividers only) | `#CDD5B6` | `#5A6950` | Decoration |
| Control outline (buttons, fields) | `#76845F` | `#95A487` | 3.5 / 3.4 |
| Ink | `#2A3520` | `#F4F6E9` | 11.2 / 8.2 |
| Muted | `#55614A` | `#CBD4BC` | 5.7 / 5.8 |
| Juice green | `#4A6E22` | `#C3E491` | 5.1 / 6.3 |
| Pink grapefruit (fill) | `#F4846B` | `#FF9E86` | Text on it, `#3A140B`: 6.5 / 8.2 |
| Pink grapefruit (text, and the main button's outline) | `#A33C25` | `#FFB8A6` | 5.6 / 5.4 |
| Warning | `#85540A` | `#F8CC72` | 5.6 / 5.9 |
| Danger | `#A8202E` | `#FFB3B0` | 6.2 / 5.3 |
| Info | `#1C6478` | `#9ADAEE` | 5.8 / 5.8 |

Every pair the app draws meets WCAG AA (4.5:1 for text, 3:1 for controls and icons) in light, dark and both increased-contrast
appearances, and still does with protanopia, deuteranopia, tritanopia or achromatopsia simulated. `leafjuice-check` fails
if any pair drops below, so CI catches it. Source of truth: `Sources/LeafJuiceCore/Palette.swift`. Details: `docs/ux-audit.md`.
Artwork colors, for illustration only: line `#3F5236`, juice `#93A255`, cream `#F5E8CF`.

## Voice

Plain and specific. Say what happened and what to do next. Friendly without being cute: the name carries the fun, so the
interface doesn't need to.

## Shape

Soft rounded tiles and controls, labels beside every icon, and state shown by shape and word as well as colour.

- Tile: 896 × 896 on a 1024 canvas, corner radius 200.
- Controls: 32 pt buttons, radius 8, 1 pt border. Cards radius 10. 2 pt focus ring.
- Icons with labels. An icon alone gets an accessibility label and a tooltip.
- State is shown by **shape and word as well as color**.

SwiftUI's prominent button sets its own text color, which can't be relied on for contrast here, so `JuiceButtonStyle` sets it
explicitly. Increase Contrast in System Settings gets stronger ink, muted text and borders.

## Accessibility

- Uses system text styles, standard controls and SF Symbols, so VoiceOver and keyboard navigation work as expected.
- The console is a real text view: selectable across lines and readable by VoiceOver.
- Animation respects Reduce Motion.
- Destructive actions are never the default button. Deleting a world means typing its name.
