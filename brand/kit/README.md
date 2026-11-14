# LeafJuice brand kit

**Adopted** by the owner on 2026-11-14 (K628): the icon, and the banners, headers and release images. The tagline is **A little pulp goes a long way.** On banners the mark sits on its pistachio square with a ring in the tagline's colour (5.99:1 on cream, 8.00:1 on dark), and the tagline is set to the wordmark's exact width. The README header and app icon are copied into `brand/`; the rest are built into `out/`.

## The idea

The same glass of green juice with a leaf, now drawn as 16 × 16 pixel art, with a grapefruit wedge on the rim as the
one pop of colour. It keeps LeafJuice's own colours.

## Which rules it follows

No EXTANT APE kit exists yet, so this follows the rules for one: D147 (the minimum asset list), D148 (inheritance
and tiers) and D149 (WCAG). LeafJuice is a desktop app, so its tier is a Mac `.icns` and a Windows `.ico` from one
master, release images, a repo banner, the GitHub social preview and a README header, plus circle and square profile
marks. It isn't a family theme for anything else.

## One master

`mark.txt` is the only drawn file: a grid of 16 rows, one character per pixel, with a palette. To build the kit:

```bash
swift scripts/brand-kit.swift brand/kit
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
| `icon.svg` | vector | The app icon's master |
| `icon-small.svg` | vector, 32 | The master for 16 to 32 px: the tile runs to the edge and each art pixel is a whole screen pixel |
| `icon-1024.png`, `icon-32.png` | 1024, 32 | Drawn from the masters |
| `AppIcon.icns` | 16 to 1024 | macOS, every size at 1× and 2×, made with `iconutil` |
| `LeafJuice.ico` | 16 to 256 | Windows: 16, 24, 32, 48, 64, 128 and 256, read back to check every size is there |
| `release-square-1080.png`, `release-landscape-1200x675.png` | 1080, 1200 × 675 | Release posts, the mark on its ringed square. The second argument sets the version line: `swift scripts/brand-kit.swift brand/kit "Version 0.3.0"` |
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

## Still to do

- Upload the GitHub social preview (`out/github-social-preview-light-1280x640.png`) in the repo's settings. GitHub has no
  command for it, so it's done by hand.
- See the icon in the Dock, on a phone and on Windows.
