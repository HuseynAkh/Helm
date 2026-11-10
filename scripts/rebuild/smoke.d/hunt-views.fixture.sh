#!/usr/bin/env bash
# A folder of its own for the views checks: a folder three levels deep to open with Option, a folder of files to
# select, rename and move to the Trash inside, two apps, two files whose Best Match order isn't A to Z, and enough
# files to scroll the grid.
hv="$fix/home/HuntViews"
mkdir -p "$hv/Deep/Inner/Innermost" "$hv/Box" "$hv/Search" "$hv/Scroll"
mkdir -p "$hv/Apps/Tool.app/Contents/MacOS" "$hv/Apps/Gadget.app/Contents/MacOS"
echo d > "$hv/Deep/d.txt"
echo i > "$hv/Deep/Inner/i.txt"
echo z > "$hv/Deep/Inner/Innermost/z.txt"
for i in 1 2 3 4 5 6 7 8; do echo "$i" > "$hv/Box/item-$i.txt"; done
echo a > "$hv/Search/aq-file.txt"
echo q > "$hv/Search/q-file.txt"
for i in $(seq -w 1 60); do echo "$i" > "$hv/Scroll/file-$i.txt"; done
echo t > "$hv/top.txt"
