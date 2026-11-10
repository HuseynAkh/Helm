#!/usr/bin/env bash
# An archive that a step hands to Archive Utility by name only: nothing ever opens it.
mkdir -p "$fix/home/RouteCase"
echo "not really a zip" > "$fix/home/RouteCase/bundle.zip"
echo "kept" > "$fix/home/RouteCase/kept.txt"
