#!/bin/bash
# Draws the four options for Helm's AI mark, A to D, and the sheet that compares them.
# usage: bash build.sh <app-icon.icns> <out-dir>
# Assembles one self-contained script per option from src/core.swift and src/<letter>.swift (each runs alone with
# `swift <file> <out-dir>` and draws <letter>.png, 512 px on a clear background), and sheet.swift, which draws
# sheet.png (the comparison at 2x) and zoom-small.png (the 16 and 22 pt marks enlarged, for checking pixels).
# Everything is drawn with CoreGraphics; nothing comes from the network or an image service.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
icon="${1:?usage: bash build.sh <app-icon.icns> <out-dir>}"
out="${2:?usage: bash build.sh <app-icon.icns> <out-dir>}"
mkdir -p "$out"
names=(A_wheel_rosette B_compass_loops C_looped_spark D_trefoil_knot)
for name in "${names[@]}"; do
    letter="${name:0:1}"
    {
        echo "// $name.swift: option $letter of Helm's AI mark, assembled by build.sh from src/core.swift and src/$letter.swift."
        echo "// usage: swift $name.swift <out-dir>, which draws $letter.png, 512 px on a clear background."
        cat "$here/src/core.swift" "$here/src/$letter.swift"
        echo 'let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."'
        echo "writePNG(markImage(mark$letter, size: 512, scale: 1, paint: .lit(turn: 0)), to: outDir + \"/$letter.png\")"
    } > "$out/$name.swift"
    swift "$out/$name.swift" "$out"
done
{
    echo "// sheet.swift: the four options of Helm's AI mark side by side, assembled by build.sh from src/."
    echo "// usage: swift sheet.swift <app-icon.icns> <out-dir>, which draws sheet.png and zoom-small.png."
    cat "$here/src/core.swift" "$here/src/A.swift" "$here/src/B.swift" "$here/src/C.swift" "$here/src/D.swift" "$here/src/sheet_main.swift"
    echo 'sheet([markA, markB, markC, markD], iconPath: CommandLine.arguments[1], outDir: CommandLine.arguments[2])'
} > "$out/sheet.swift"
swift "$out/sheet.swift" "$icon" "$out"
