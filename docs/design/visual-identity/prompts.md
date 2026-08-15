# Grab Rabbit visual-identity generation prompts

- App-concept mode: bundled `scripts/image_gen.py` CLI through the OpenRouter OpenAI-compatible endpoint
- Model: `gpt-image-2`
- Quality: `low`
- Use case: `logo-brand`
- Asset type: macOS app-icon concept
- Source size: 1024 × 1024 pixels
- Prompt handling: `--no-augment`; each code block below is the exact API prompt
- Generation rule: one separate paid call per concept; no batch collage and no retry

The built-in generator was unavailable in this session. Tim authorized the CLI
fallback after a one-call billing/endpoint smoke test. These are the exact prompts
supplied to the API. The named colors are the intended palette for each direction;
generated raster color is conceptual until a selected mark is redrawn as
deterministic production artwork.

## Execution ledger

| Call | Operation | Result |
|---:|---|---|
| 1 | Generate Concept 3, Lens Leap | Succeeded; selected by Tim; master SHA-256 `d3fe2e13ab745ce47dbb990ee9e42b35b17f64c2dd7084d21ab2e0399cfa1895` |
| 2 | Generate Concept 1, Burrow Cutout | Succeeded; rejected alternative; SHA-256 `b92897bc95dd13787bf67854f6c3ab7b61cec3574c2f0722b67d34417149226b` |
| 3 | Generate Concept 2, Viewfinder Ears | Succeeded; rejected alternative; SHA-256 `9a21c3007fb60160eb5be8e44e41f2e7bfecdc8387a1de345a65810671ab5c4a` |
| 4 | Generate Concept 4, Camcorder Sentinel | Succeeded; rejected alternative; SHA-256 `f6949f3a6151eb98c3217dcc78bdbae07f38a760d7d1dc5b1ed46e62f2db9183` |
| 5 | Generate Concept 5, Focus Eye | Succeeded; rejected alternative; SHA-256 `eb704e8efa881bd8bba60573bb70515378452ef5d7d90331746ce766478f6705` |
| 6 | Edit selected Lens Leap for a 16/32 px optical master | OpenRouter returned `404 Not Found`; no output; not retried |
| 7 | Generate Viewfinder Ears status reference through OpenRouter (`gpt-image-2`, 2048/high) | Succeeded once; raw SHA-256 `32e409950273f6b75d937fd2e475a8a4d0ec4d0274af58be7e4bc790818ab196`; transparent derivative produced locally |

## Concept 1 — Burrow Cutout

```text
Use case: logo-brand
Asset type: macOS app-icon concept
Primary request: Create one original square app-icon mark for Grab Rabbit. Form a readable white rabbit silhouette entirely from negative space cut into the center of a compact rounded camera body. The camera must read immediately through a small viewfinder bump and one simple lens ring, while the rabbit must read immediately through two ears, head, back, and tail. This is one integrated symbol, not separate camera and rabbit illustrations.
Scene/backdrop: solid deep navy square field, edge to edge
Style/medium: simple vector-friendly flat logo design, crisp geometric curves, no texture
Composition/framing: one centered mark, symmetrical visual weight, generous outer padding, thick shapes and open counters designed to remain legible at 16 pixels
Color palette: deep navy #0B1F33, teal #12B8A6, white #FFFFFF only
Constraints: exactly one icon mark; the rabbit silhouette is pure white; camera-centered; original drawing and composition; no text, letters, wordmark, watermark, collage, border, badge, app mockup, device mockup, shadow, reflection, gradient, transparency, 3D, photorealism, mascot face, robot motif, circuit motif, orange, coral, red-orange, or yellow-orange
Avoid: CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress; avoid thin lines and tiny detail
```

## Concept 2 — Viewfinder Ears

```text
Use case: logo-brand
Asset type: macOS app-icon concept
Primary request: Create one original square app-icon mark for Grab Rabbit. Design a compact front-facing camera whose two upward viewfinder fins also form the ears of a readable white front-facing rabbit silhouette. Integrate the rabbit face and shoulders into the camera's central negative space; use one small circular lens as the rabbit's nose so camera and rabbit share geometry without becoming a mascot.
Scene/backdrop: solid midnight indigo square field, edge to edge
Style/medium: simple vector-friendly flat logo design with bold modular geometry and rounded corners
Composition/framing: one centered near-symmetrical mark, generous outer padding, large white areas and thick features optimized for 16-pixel recognition
Color palette: midnight indigo #1E1B4B, vivid violet #7C3AED, white #FFFFFF only
Constraints: exactly one icon mark; rabbit silhouette is pure white and unmistakable; camera-centered; original drawing and composition; no text, letters, wordmark, watermark, collage, border, badge, app mockup, device mockup, shadow, reflection, gradient, transparency, 3D, photorealism, mascot body, robot motif, circuit motif, orange, coral, red-orange, or yellow-orange
Avoid: CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress; avoid thin ear gaps, facial detail, and tiny controls
```

## Concept 3 — Lens Leap

```text
Use case: logo-brand
Asset type: macOS app-icon concept
Primary request: Create one original square app-icon mark for Grab Rabbit. Build a bold circular camera lens as the dominant center of a minimal compact-camera silhouette, and place a readable white side-profile leaping rabbit silhouette inside the lens. The rabbit must have two clear swept-back ears, arched body, hind legs, and a round tail, all simplified into one solid white shape.
Scene/backdrop: solid cobalt blue square field, edge to edge
Style/medium: simple vector-friendly flat logo design, clean circles and decisive silhouette, no texture
Composition/framing: one centered mark, lens occupies most of the camera body, generous outer padding, rabbit enlarged to survive 16-pixel downscaling
Color palette: cobalt #164EAE, cyan #22D3EE, white #FFFFFF only
Constraints: exactly one icon mark; rabbit silhouette is pure white; camera-centered; original drawing and composition; no text, letters, wordmark, watermark, collage, border, badge, app mockup, device mockup, shadow, reflection, gradient, transparency, 3D, photorealism, mascot face, robot motif, circuit motif, orange, coral, red-orange, or yellow-orange
Avoid: CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress; avoid enclosing the entire icon in a circle, thin lens rings, and realistic camera detail
```

## Concept 4 — Camcorder Sentinel

```text
Use case: logo-brand
Asset type: macOS app-icon concept
Primary request: Create one original square app-icon mark for Grab Rabbit. Use a compact side-facing camcorder silhouette with a distinct short lens barrel on the left and a small flip-screen block on the right. Carve a large readable white front-facing seated rabbit silhouette into the camcorder body, with two tall ears and a simple body taper; the rabbit is calm and iconic, not anthropomorphic.
Scene/backdrop: solid dark plum square field, edge to edge
Style/medium: simple vector-friendly flat logo design, bold block shapes with restrained rounded corners
Composition/framing: one centered horizontal mark with generous outer padding; keep the rabbit and lens barrel large enough to read at 16 pixels
Color palette: dark plum #3B163C, magenta #D946EF, white #FFFFFF only
Constraints: exactly one icon mark; rabbit silhouette is pure white; camera-centered; original drawing and composition; no text, letters, wordmark, watermark, collage, border, badge, app mockup, device mockup, shadow, reflection, gradient, transparency, 3D, photorealism, cartoon expression, robot motif, circuit motif, orange, coral, red-orange, or yellow-orange
Avoid: CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress; avoid thin handles, buttons, and detailed camcorder controls
```

## Concept 5 — Focus Eye

```text
Use case: logo-brand
Asset type: macOS app-icon concept
Primary request: Create one original square app-icon mark for Grab Rabbit. Form the outer silhouette as a minimal compact camera with a clear top shutter bump. Within it, use a large readable white rabbit-head silhouette in three-quarter profile; one oversized mint camera lens replaces the rabbit's eye and is the single focal circle. The long paired ears, cheek, and small nose must remain readable as a rabbit at 16 pixels while the outer body remains unmistakably a camera.
Scene/backdrop: solid graphite square field, edge to edge
Style/medium: simple vector-friendly flat logo design, strong silhouette, soft geometric corners, no texture
Composition/framing: one centered mark, generous outer padding, very large rabbit head and lens, minimal internal detail for small-size legibility
Color palette: graphite #18202A, mint #34D399, white #FFFFFF only
Constraints: exactly one icon mark; rabbit silhouette is pure white; camera-centered; original drawing and composition; no text, letters, wordmark, watermark, collage, border, badge, app mockup, device mockup, shadow, reflection, gradient, transparency, 3D, photorealism, mascot body, robot motif, circuit motif, orange, coral, red-orange, or yellow-orange
Avoid: CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress; avoid a cute character expression, whiskers, thin outlines, and tiny controls
```

## Attempted optical small-size edit — no output

The following exact edit prompt used the selected Lens Leap master as Image 1.
The OpenRouter edit endpoint returned `404 Not Found`; the selected master was not
changed, and no alternative model, provider, or retry was used.

```text
Use case: precise-object-edit
Asset type: macOS app-icon optical small-size master for 16 px and 32 px only
Input images: Image 1 is the user-approved Lens Leap full-size app-icon concept and edit target
Primary request: Preserve the approved icon and change only the white leaping-rabbit silhouette enough to remain unmistakably rabbit-like at 16 and 32 pixels. Make the rabbit slightly larger and bolder inside the lens, simplify it to one compact solid white silhouette, make the paired swept-back ears clearly separated and substantial, keep a clearly round tail, and remove or merge thin limb details that collapse during downscaling. Preserve the same right-facing leaping pose and energetic identity.
Composition/framing: preserve the exact centered camera silhouette, lens placement, icon framing, and outer padding from Image 1
Color palette: preserve the exact existing blue/cyan palette, white rabbit, and existing gradients from Image 1
Constraints: change only the rabbit silhouette; keep the camera body, viewfinder bump, shutter detail, lens circle, backdrop, blue/cyan colors, gradients, lighting, and composition unchanged; exactly one camera-and-rabbit mark; no text, letters, wordmark, watermark, collage, border, badge, mockup, orange, coral, red-orange, yellow-orange, mascot face, robot motif, or circuit motif
Avoid: restyling or replacing the approved icon; avoid thin legs, thin paws, tiny gaps, added detail, CodeRabbit-like rabbit drawing, enclosing shape, composition, orange treatment, or trade dress
```

## High-quality Viewfinder Ears status reference

Exactly one additional generation was authorized for status-item source reference.
No retries or further model calls were made.

- Route: bundled `scripts/image_gen.py` through the OpenRouter OpenAI-compatible endpoint
- Model: `gpt-image-2`
- Quality: `high`
- Size: 2048 × 2048
- Duration: 103.2 seconds
- Raw reference: `status-item/references/grab-rabbit-viewfinder-ears-gpt-image-2-v2.png`, SHA-256 `32e409950273f6b75d937fd2e475a8a4d0ec4d0274af58be7e4bc790818ab196`
- Chroma-removed reference: `status-item/references/grab-rabbit-viewfinder-ears-gpt-image-2-v2-transparent.png`, SHA-256 `bf3abd7280195f3b8db513abf3d516b13e298e57fc8ba2f6aaf7ad3fa0cd669c`

The bundled CLI assembled this exact prompt:

```text
Use case: logo-brand
Primary request: Create a premium master source concept for the selected Grab Rabbit Viewfinder Ears macOS menu-bar icon. Preserve the simple idea shown in the user reference: a compact rounded camera silhouette whose top forms two unmistakable rabbit ears, with a circular camera lens cut out of the body. It is a simplified monochrome companion to the approved full-color Lens Leap app icon, not a literal miniature. Refine it to the level of a first-party macOS system icon.
Style/medium: world-class Apple-quality monochrome vector pictogram; geometrically precise smooth Bézier curves; optically balanced at 16–22 pt
Composition/framing: one centered front-facing glyph with generous even padding and perfect bilateral balance
Color palette: one solid matte black glyph on a perfectly flat solid #00ff00 chroma-key background
Constraints: single camera body fused naturally with two clean rabbit ears; centered circular lens as true negative-space cutout; tiny rounded viewfinder cutout; strong silhouette; camera proportions and curve language visibly related to the approved Lens Leap app icon; every curve deliberate; background and both cutouts exactly #00ff00; no text; no watermark
Avoid: pixelation, jagged edges, blur, fuzzy contours, shadows, gradients, texture, lighting, 3D, perspective, multiple icons, outlines, facial features, whiskers, paws, letters, mockup framing
```

Invocation route, with environment-variable names only:

```bash
OPENAI_API_KEY="$OPENROUTER_API_KEY" \
OPENAI_BASE_URL='https://openrouter.ai/api/v1' \
uv run --with openai python <bundled-image_gen.py> generate \
  --model gpt-image-2 --quality high --size 2048x2048
```

The reference was then processed locally, with no model call:

```bash
uv run --with pillow python <bundled-remove_chroma_key.py> \
  --input <raw-reference> \
  --out <transparent-reference> \
  --auto-key border \
  --soft-matte \
  --transparent-threshold 12 \
  --opaque-threshold 220 \
  --despill
```

The helper sampled border color `#11F715`: 3,293,017 of 4,194,304 pixels became
fully transparent and 6,955 remained partially transparent for edge antialiasing.
Both rasters are retained only as provenance/reference. The production template was
redrawn as editable Bézier geometry; neither generated raster is a shippable asset.
