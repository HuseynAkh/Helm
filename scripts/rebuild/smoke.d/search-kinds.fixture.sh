#!/usr/bin/env bash
# One word in the names of a photo, a video and a note, and a photo without it, for a plain search kept to one kind.
mkdir -p "$fix/home/KindCase"
for name in beach-photo.jpg beach-clip.mov beach-notes.txt other.jpg; do echo "$name" > "$fix/home/KindCase/$name"; done
