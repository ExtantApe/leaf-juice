# LeafJuice brand kit: draft, 2026-11-14

**A draft for the owner's yes.** Nothing here replaces the current icon or brand until he approves it (K628, D150).

## The idea

The same glass of green juice with a leaf, now drawn as 16 × 16 pixel art. That puts it in the Minecraft family
without borrowing anything from the game. A grapefruit wedge on the rim is the one pop of colour, as in the app.

No Minecraft family theme exists yet, and none was found in the plugin repos. EXTANT APE has no shared kit to inherit
from either. So this draft follows the family rules in `ops/rules/brand-families.md`, and it could become the start of
a Minecraft family theme if the owner likes it.

## One master

`mark.txt` is the only drawn file: a grid of 16 rows, one character per pixel, with a palette. To build the kit:

```bash
swift scripts/brand-kit.swift brand/drafts/2026-11-14
```

The builder checks every pair first and refuses to write anything if one fails (D149):

- Large text, the name: 3:1.
- Small text, the tagline: 4.5:1.
- The mark's outline on each light background: 3:1.
- On dark backgrounds, where the outline is dark too, the glass and juice carry the shape: 3:1.

The last build passed all 11 pairs. The lowest was the juice on the dark tile, at 5.3:1.

## What's in `out/`

| File | Size | For |
| --- | --- | --- |
| `mark.svg` | vector | The mark itself, pixel for pixel |
| `mark-circle-{light,dark}-{1024,400}.png` | 1024, 400 | Profile marks shown as circles (X, Bluesky) |
| `mark-square-{light,dark}-{1024,400}.png` | 1024, 400 | Profile marks shown as squares (LinkedIn company, GitHub) |
| `app-icon-1024.png`, `app-icon-32.png` | 1024, 32 | The Mac app icon, on Apple's 824-point tile |
| `github-social-preview-*-1280x640.png` | 1280 × 640 | GitHub's social preview |
| `readme-header-*-1280x320.png` | 1280 × 320 | The top of the README |
| `x-header-*-1500x500.png` | 1500 × 500 | X header |
| `bluesky-banner-*-3000x1000.png` | 3000 × 1000 | Bluesky banner, under its 1 MB limit |
| `linkedin-banner-*-1584x396.png` | 1584 × 396 | LinkedIn personal banner |
| `linkedin-company-banner-*-1128x191.png` | 1128 × 191 | LinkedIn page banner, name only, since a tagline wouldn't fit |

## Platform sizes, checked 2026-11-14

- **GitHub social preview:** 1280 × 640.
- **X:** profile 400 × 400, header 1500 × 500.
- **LinkedIn:** profile 400 × 400, personal banner 1584 × 396. Guides disagree on the company page banner: most say
  1128 × 191, and one says 1128 × 376. This kit uses 1128 × 191; check LinkedIn's upload preview.
- **Bluesky:** it publishes no official pixel sizes. Guides give 400 × 400 or 1000 × 1000 for the avatar, which shows
  as a circle, and 1500 × 500 or 3000 × 1000 for the banner. The image limit is 1,000,000 bytes. This kit uses the
  larger sizes, and the builder fails if a banner goes over the limit.

Sources: [Buffer](https://buffer.com/resources/social-media-image-sizes/),
[Hootsuite](https://blog.hootsuite.com/social-media-image-sizes/),
[Constant Contact](https://www.constantcontact.com/blog/social-media-image-sizes/),
[OpenTweet's Bluesky guide](https://opentweet.io/tools/bluesky-banner-size),
[Sendcove's Bluesky guide](https://www.sendcove.app/integrations/bluesky/image-sizes).

## Still to do, once the direction is approved

- **The `.icns`:** build it from `app-icon-1024.png` and replace `brand/AppIcon.icns`.
- **A release post template,** in square and landscape.
- **The decision on Minecraft plugins:** whether they share this pixel style as the family theme.
- **The dark-mode leaf.** Its dark outline sits close to the dark tile. The light green carries the shape, but the owner
  should judge it at real sizes.
- **Real devices.** Nothing has been seen at size on a phone or in the Dock.
