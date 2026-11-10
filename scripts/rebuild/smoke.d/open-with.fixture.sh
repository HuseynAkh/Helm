#!/usr/bin/env bash
# For the Open With steps: two plain-text files, which share a default app, a Markdown file, whose default is often
# another app, a folder, and a link to one of the text files. All inside the fixture home, in a folder of their own.
set -u
rm -rf "$fix/home/OpenWith"
mkdir -p "$fix/home/OpenWith/Project"
echo letter > "$fix/home/OpenWith/letter.txt"
echo notes > "$fix/home/OpenWith/notes.txt"
echo "# Read me" > "$fix/home/OpenWith/readme.md"
echo inside > "$fix/home/OpenWith/Project/inside.txt"
ln -s notes.txt "$fix/home/OpenWith/notes-link"
true
