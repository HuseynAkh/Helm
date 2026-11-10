#!/usr/bin/env bash
# Two folders and two files to visit and open, for Recent's Folders and Files groups. Alpha Folder holds files whose
# A to Z order differs from their path order, so a folder opened in Recent's list shows how its files are sorted.
mkdir -p "$fix/home/RecentCase/Alpha Folder" "$fix/home/RecentCase/Beta Folder"
for name in inside.txt Banana.txt file10.txt file2.txt apple.txt; do echo "$name" > "$fix/home/RecentCase/Alpha Folder/$name"; done
echo 1 > "$fix/home/RecentCase/first.txt"
echo 2 > "$fix/home/RecentCase/second.txt"
