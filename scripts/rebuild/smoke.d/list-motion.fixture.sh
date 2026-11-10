#!/usr/bin/env bash
# Folders to open and close in the list: one with many files, one with a folder inside it.
mkdir -p "$fix/home/Unfold/Many" "$fix/home/Unfold/Nested/Inner"
for i in $(seq -w 1 40); do echo "$i" > "$fix/home/Unfold/Many/file-$i.txt"; done
echo n > "$fix/home/Unfold/Nested/n.txt"
echo d > "$fix/home/Unfold/Nested/Inner/deep.txt"
echo t > "$fix/home/Unfold/top.txt"
# A folder made slow on purpose, and one holding a hidden file, for the Loading row and Show Hidden checks.
mkdir -p "$fix/home/Listing/Slow" "$fix/home/Listing/Dotted"
echo a > "$fix/home/Listing/Slow/a.txt"
echo b > "$fix/home/Listing/Slow/b.txt"
echo s > "$fix/home/Listing/Dotted/.secret"
echo v > "$fix/home/Listing/Dotted/visible.txt"
echo p > "$fix/home/Listing/plain.txt"
