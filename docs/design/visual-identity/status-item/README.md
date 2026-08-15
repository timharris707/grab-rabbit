# Grab Rabbit menu-bar status-item template

- Decision item: [#17](https://github.com/timharris707/grab-rabbit/issues/17)
- Family selection: Tim selected Viewfinder Ears as the basis for the separate menu-bar identity.
- Approval status: derived template awaiting Tim's final approval; it is not installed in the application.
- Source raster: [`../masters/rejected-viewfinder-ears.png`](../masters/rejected-viewfinder-ears.png), SHA-256 `9a21c3007fb60160eb5be8e44e41f2e7bfecdc8387a1de345a65810671ab5c4a`

## Recommended status mark

![Template sizes on representative light and dark surfaces](previews/exact-size-strip.png)

The template keeps Viewfinder Ears' strongest family cue: one compact rounded
camera body whose top outline becomes a pair of rabbit ears. It removes the
full-color tile, gradients, inner-ear shapes, rabbit face/body, highlight, and
other detail that cannot survive menu-bar scale. A transparent circular lens and
the small rounded viewfinder cutout are retained because both remain visible at
the required sizes and make the camera read faster than a solid rabbit-eared box.

This is the strongest status companion to Lens Leap because the two marks share
the same camera-plus-rabbit vocabulary without shrinking the detailed app icon or
pretending a full-color Dock icon is a macOS template image.

## Deliverables

- Canonical transparent PNG: [`master/grab-rabbit-status-template-1024.png`](master/grab-rabbit-status-template-1024.png), SHA-256 `d5fcad548760147f36e4182a3a0a88038061bd6170165b46156ff05cf3626086`
- Deterministic 18-point PDF: [`master/grab-rabbit-status-template.pdf`](master/grab-rabbit-status-template.pdf), SHA-256 `4119627ea18ba1c5c26f32d165ce5e4453a106bacc9aa32dddbbba33595874d8`
- Exact PNG exports: [`exports/`](exports/)
- Light/dark menu-bar previews: [`previews/menu-bar-comparison.png`](previews/menu-bar-comparison.png)
- Pixel-level inspection sheet: [`previews/pixel-inspection.png`](previews/pixel-inspection.png)
- Reproduction script: [`derive-status-icon.sh`](derive-status-icon.sh)

| Asset | Pixels | SHA-256 |
|---|---:|---|
| `grab-rabbit-status-16pt.png` | 16 × 16 | `1382c686c8706516c1d933996c69b77f88ea31cea0e96033c666af91fc87922a` |
| `grab-rabbit-status-18pt.png` | 18 × 18 | `736444cc15ea72c0bfbdcba89fdddf5aa3eae608b5b169bf5e8a7e054c28cd71` |
| `grab-rabbit-status-22pt.png` | 22 × 22 | `51179f60875f6e496fae3bb31ac8bdc5208f4293fbf978c13b800b0b6f4af8b4` |
| `grab-rabbit-status-16pt@2x.png` | 32 × 32 | `3204eaf057d7553afd418a0711b180d3b9e78dab4afa37b6ad978369c00f8051` |
| `grab-rabbit-status-18pt@2x.png` | 36 × 36 | `e746a92b901c5b43e221c5247b77e2536f3a5a2c8bb35428ecef570becc9d9a7` |
| `grab-rabbit-status-22pt@2x.png` | 44 × 44 | `cabd16215a037f1e279e78091108d3693d53d4ec6fede0f3fda238f0470b1df7` |

## Deterministic derivation

Run from anywhere inside the repository:

```bash
docs/design/visual-identity/status-item/derive-status-icon.sh
```

The script performs these exact operations locally with ImageMagick and
ReportLab; it makes no API or model call:

1. Convert the selected Viewfinder Ears source to HSL and threshold its lightness channel at 40%, forming the union of its camera-and-rabbit artwork.
2. Subtract the source lens circle (`512,690` through `563,690`) and rounded viewfinder rectangle (`225,433` through `301,476`, radius `20`) as transparent negative detail.
3. Trim the source background, resize the silhouette proportionally into an 896-pixel box, and center it on a 1024 × 1024 canvas.
4. Copy the binary mask to alpha and force every RGB pixel to black. The PNG therefore has one template color plus antialiased alpha, never a visual gradient.
5. Downsample the canonical master with Lanczos to the six exact PNG sizes.
6. Wrap the 1024 master in a deterministic 18 × 18-point PDF with its soft alpha mask intact.
7. Strip date/time chunks from every final PNG so repeated runs are byte-identical.

Two consecutive clean derivations produced identical hashes for all 13 PNG/PDF
artifacts.

## QA results

![Nearest-neighbor pixel inspection; top row light, bottom row dark](previews/pixel-inspection.png)

- The 1024 master is grayscale plus alpha. RGB is black everywhere; alpha spans 0–255 only for transparency and edge antialiasing.
- Visible master bounds are 896 × 893 at `(64,65)`, leaving 64 px left/right, 65 px top, and 66 px bottom padding. All four corners are fully transparent.
- At 16, 18, 22, 32, 36, and 44 pixels the rounded camera body, paired rabbit ears, circular lens hole, and left viewfinder mark remain distinguishable. The 16/18-pixel viewfinder intentionally resolves to roughly one pixel; the Retina exports preserve its pill shape.
- Light previews render the template near-black (`#202124`); dark previews render it near-white (`#F5F5F5`). This previews macOS template tinting without baking either color into separate product assets.
- The one-page PDF is 18 × 18 points and contains a 1024 × 1024 grayscale image plus a 1024 × 1024 soft mask. Poppler rendered it back at 144 dpi as the expected 36 × 36 mark with no clipping or missing transparency detail.
- No text, color tile, gradient, orange treatment, or CodeRabbit-like robot/circuit detail is present.

![Representative Retina menu bars; light above, dark below](previews/menu-bar-comparison.png)

Final integration must set the status asset as a macOS template image and retest it
in the built application. Issue #18 owns installing artwork; issue #20 owns status
behavior and controls. This package makes neither change.
