# Helm's brand

| File | What it is |
|---|---|
| `spark.svg`, `spark.png` | The mark of AI mode, the trefoil: one line in amber, coral and violet that loops three times, passing over and under itself. It is the shape every mark of AI mode in the app draws (`Sources/HelmUI/Agent/SparkMark.swift`); the files keep the name of the four-point spark it replaced, and Huseyn chose it on 2026-11-17 from the four options `scripts/brand/ai-mark` draws. The SVG is flat, without the shade the pictures have where the line goes under. |
| `banner-light.png`, `banner-dark.png` | The README's banner, 2400 by 800 pixels, for light and dark pages: one centred lockup of the unchanged app icon and a text column, the mark leading the words "AI mode" as it leads AI mode's lines in the app, then the name in SF Pro Display Semibold and "An agentic file manager for your Mac." "AI mode" is set in the mark's colours, amber to coral to violet from left to right, deepened a little on the light banner so the word reads. The field is white warming to cream in light, with soft tints of amber, coral and violet; in dark it is a deep neutral with violet and coral, never amber, which turns brown over black. It was chosen on 2026-11-17 from four concepts (a halo of the mark behind the icon, this lockup, the icon set inside a large knot, and a line of coloured light along the bottom edge). |
| `logo-variants/` | The five icons Huseyn chose from on 2026-11-08. He chose variant 4, Isometric, which is the app icon. Kept as the record of that choice. |

The app icon is not changed (Huseyn, 2026-11-13), and no variant of it was made for AI mode.

`bash scripts/readme/make_readme_images.sh` draws the mark and the banner again, through `scripts/readme/make_brand.swift`, from `App/AppIcon.icns`. Nothing comes from an image service.
