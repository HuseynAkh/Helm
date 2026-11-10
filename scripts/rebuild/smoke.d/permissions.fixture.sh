#!/usr/bin/env bash
# Folders for the access steps, made readable here. The steps lock each one with fixture-chmod 000 just before it's
# used and unlock it straight after: in Private that's an ordinary permissions refusal, and in the places macOS
# guards (its TV library, another app's data, iCloud Drive) it stands in for a macOS privacy refusal, which a
# fixture can't create. Nothing is locked before the build, so a failed build leaves nothing the next run can't remove.
set -u
# A run that was stopped part-way can leave a folder locked, which the clean-up before this couldn't remove.
# Unlock and remove those first, so this run starts from scratch.
for leftover in "$fix/home/Private" "$fix/home/Movies" "$fix/home/Library/Containers" "$fix/home/Library/Mobile Documents" "$fix/home/.Trash"; do
    [ -e "$leftover" ] && chmod -R u+rwX "$leftover" 2>/dev/null
done
rm -rf "$fix/home/Private" "$fix/home/Movies" "$fix/home/Library/Containers" \
       "$fix/home/Library/Mobile Documents/com~apple~CloudDocs/Drafts" "$fix/home/.Trash/Stuck"
mkdir -p "$fix/home/Private" "$fix/home/Movies/TV" "$fix/home/Movies/Empty" \
         "$fix/home/Library/Containers/com.example.notes" "$fix/home/Library/Mobile Documents/com~apple~CloudDocs/Drafts"
echo plans > "$fix/home/Private/plans.txt"
echo episode > "$fix/home/Movies/TV/episode.txt"
true
