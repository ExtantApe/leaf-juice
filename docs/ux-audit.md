# UX and accessibility audit

## 2026-11-14

Asked for by the owner through Helm: a full UX audit, with a WCAG color evaluation of every text and UI pair in
light and dark mode, enforced in code where possible.

**How it was done.** A sweep of every view in `Sources/LeafJuice` for layout, wording, defaults, empty states, error
messages, keyboard use, VoiceOver labels, focus and motion, plus a computed check of every color pair. The app itself
was not driven by hand: a sandboxed copy was built for that, but screen control wasn't granted, so nothing here was
seen in the running app with VoiceOver or a keyboard. That pass is the first item under "Bigger items".

### Colors: enforced in code

The palette now lives in `Sources/LeafJuiceCore/Palette.swift`, and the app's theme is built from it. Every pair the
app draws is listed there with its minimum:

- **Text:** 4.5:1 (WCAG 1.4.3). All text is held to this, large or not.
- **Controls and icons:** 3:1 (WCAG 1.4.11). Button and field outlines, focus rings, toggles, status icons.

`leafjuice-check` tests all 47 pairs in light, dark, and both increased-contrast appearances, each as seen with
typical vision and with protanopia, deuteranopia, tritanopia (Machado, Oliveira and Fernandes 2009, full strength) and
achromatopsia. That's 940 combinations. CI runs the check, so a color change that breaks any of them fails the build.
The check also tests itself: black on white is 21:1, `#777` on white is 4.48:1, gray keeps its lightness under every
simulation, and red and green move together under protanopia and deuteranopia.

What the first run found, and what changed:

| Problem | Before | After |
|---|---|---|
| Button and field outlines used the card border color | 1.3 to 1.5:1 light, 1.5 to 2.3:1 dark | New `controlBorder`: 3.5:1 light, 3.4:1 dark. Cards and dividers keep the softer border, which is decoration. |
| The main button's grapefruit fill against the page | 2.2 to 2.5:1 light | Outline in grapefruit text color: 5.6:1 light, 5.4:1 dark. The fill and its text (6.5:1) are unchanged. |
| Grapefruit text with red-green color blindness | 4.20 to 4.48:1 | `#A33C25` light, `#FFB8A6` dark: passes under every simulation. |

Every other text pair already passed in all four appearances. Status is never shown by color alone: every badge and
callout carries an icon and a word, so the tones don't need to look different to someone who can't tell them apart.

Not covered: disabled controls are drawn at half opacity. WCAG exempts them, but they're hard to read; see below.

### What was checked in the views

- **Keyboard.** No tap-only gestures anywhere; everything clickable is a real button. 45 keyboard shortcuts, with
  Return and Escape on sheets. Inline Cancel buttons outside sheets don't take Escape, which is right, since they
  aren't dialogs.
- **VoiceOver.** 81 explicit labels before this pass. Icon-only buttons (pack order arrows) are labelled. Decorative
  icons are hidden. Disclosure rows on the Configs page and in the Issues panel say Expanded or Collapsed, and the
  folder picker marks the chosen folder as selected. Cards are headers, so VoiceOver can jump between them.
- **Reduced motion.** The only animation, the button hover, turns off with Reduce Motion.
- **Destructive actions.** 26 confirmation dialogs. Each says what stays and what goes, such as "The server's folder
  stays where it is".
- **Wording.** Errors say what failed and what to do next ("Couldn't start Java: …", "Download one on the Software
  page"). No bare "Error" anywhere a person sees it.
- **Empty states.** Lists on eight pages have an empty message saying what would appear there and how to add it.
- **Defaults.** Risky features are off until turned on: plugin commands, the Advisor, pack serving to everyone (the
  joining-only gate is on), checking connections from outside.

### Small fixes made in this pass

- Rows with repeated buttons now name their row for VoiceOver, such as "Remove Survival pack", so each one can be
  told apart in a list. Fixed on the Configs player lists, player snapshots, cleanups, Lab saves, the Shelf, resource packs,
  allowlist group pairs and the new Connections editor.
- A decorative file icon in pack contributions is hidden from VoiceOver.
- The Connections editor's on/off switch reads as the connection's name, and its Remove button names the connection.
- The product is spelled LeafJuice in the app, window title, menu bar, README, docs and release notes (D185). The
  data folder stays `~/Library/Application Support/Leaf Juice`, so nobody's settings move, and the bundle identifier
  is unchanged, so macOS permissions carry over.

### Bigger items, as tasks for Helm

1. **A hands-on VoiceOver and keyboard pass in the running app.** Tab through every page and sheet, check the focus
   order follows the layout, and listen to each card with VoiceOver. It needs screen control or a person. A sandboxed
   copy that touches no real server is ready to build: `scripts/build-app.sh`, then run it with `LEAFJUICE_HOME` and
   `LEAFJUICE_SERVERS` pointed at a scratch folder.
2. **Disabled controls at half opacity.** Exempt from WCAG, but hard to read in light mode. A disabled style with its
   own colors, held to 3:1 by the same check, would fix it. It touches every button, so it wants its own change.
3. **Layout at small window sizes.** Cards use an adaptive grid from 250 points, which should reflow, but narrow
   windows and large text haven't been looked at.
4. **The repo name.** The repo is already at `ExtantApe/leaf-juice`, so it can become `ExtantApe/LeafJuice` now (D185).
   GitHub redirects the old name. Nothing in the code depends on it. Left for Helm to confirm the timing, since other
   sessions build from this checkout.
