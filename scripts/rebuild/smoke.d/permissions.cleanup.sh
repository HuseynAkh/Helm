#!/usr/bin/env bash
# Unlocks anything the access steps locked and a failed step left that way, so the fixture can be removed.
for path in "$fix/home/Private" "$fix/home/Movies" "$fix/home/Library/Containers" "$fix/home/Library/Mobile Documents" "$fix/home/.Trash"; do
    [ -e "$path" ] && chmod -R u+rwX "$path" 2>/dev/null
done
true
