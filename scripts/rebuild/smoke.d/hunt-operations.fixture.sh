#!/usr/bin/env bash
# Files for the file-operations steps, in a folder of their own so no other step sees them. The steps lock
# Source/1-locked.txt with fixture-chmod 000 just before it's used and unlock it straight after.
set -u
ops="$fix/home/HuntOps"
[ -e "$ops" ] && chmod -R u+rwX "$ops" 2>/dev/null
rm -rf "$ops"
mkdir -p "$ops/Source" "$ops/Target" "$ops/Inside/Sub" "$ops/Bin/One" "$ops/Bin/Two" "$ops/Nest/Open/Gone"
echo new > "$ops/Source/1-locked.txt"
echo two > "$ops/Source/2-open.txt"
echo keep > "$ops/Target/1-locked.txt"
echo q > "$ops/Inside/Sub/q1.txt"
echo a > "$ops/Inside/alpha.md"
echo o > "$ops/Bin/One/one.txt"
echo t > "$ops/Bin/Two/two.txt"
echo n > "$ops/Bin/notes.txt"
echo g > "$ops/Nest/Open/Gone/g.txt"
echo k > "$ops/Nest/Open/keep.txt"
true
