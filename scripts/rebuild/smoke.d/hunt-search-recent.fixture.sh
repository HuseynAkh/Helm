#!/usr/bin/env bash
# A folder with a folder inside it and a file inside that, for Recent holding an item and the folder around it.
# Inner Folder's files read in a different order by name than by path.
mkdir -p "$fix/home/HuntSR/Inner Folder" "$fix/home/HuntSR/Other Folder"
for name in apple.txt Banana.txt file10.txt file2.txt; do echo "$name" > "$fix/home/HuntSR/Inner Folder/$name"; done
echo o > "$fix/home/HuntSR/Other Folder/o.txt"
echo z > "$fix/home/HuntSR/zeta.txt"
