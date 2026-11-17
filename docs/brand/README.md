# Helm's brand

| File | What it is |
|---|---|
| `spark.svg`, `spark.png` | The mark of AI mode, the trefoil: one line in amber, coral and violet that loops three times, passing over and under itself. It is the shape every mark of AI mode in the app draws (`Sources/HelmUI/Agent/SparkMark.swift`); the files keep the name of the four-point spark it replaced, and Huseyn chose it on 2026-11-17 from the four options `scripts/brand/ai-mark` draws. The SVG is flat, without the shade the pictures have where the line goes under. |
| `banner-light.png`, `banner-dark.png` | The README's banner: the app icon with the mark beside it. |
| `logo-variants/` | The five icons Huseyn chose from on 2026-11-08. He chose variant 4, Isometric, which is the app icon. Kept as the record of that choice. |

The app icon is not changed (Huseyn, 2026-11-13), and no variant of it was made for AI mode.

`bash scripts/readme/make_readme_images.sh` draws the mark and the banner again, through `scripts/readme/make_brand.swift`, from `App/AppIcon.icns`. Nothing comes from an image service.
