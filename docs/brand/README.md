# Helm's brand

| File | What it is |
|---|---|
| `spark.svg`, `spark.png` | The spark, the mark of AI mode: four points in amber, coral and violet. It is the shape every spark in the app draws (`Sources/HelmUI/Agent/SparkMark.swift`). |
| `banner-light.png`, `banner-dark.png` | The README's banner: the app icon with the spark beside it. |
| `logo-variants/` | The five icons Huseyn chose from on 2026-11-08. He chose variant 4, Isometric, which is the app icon. Kept as the record of that choice. |

The app icon is not changed (Huseyn, 2026-11-13), and no variant of it was made for AI mode.

`bash scripts/readme/make_readme_images.sh` draws the spark and the banner again, through `scripts/readme/make_brand.swift`, from `App/AppIcon.icns`. Nothing comes from an image service.
