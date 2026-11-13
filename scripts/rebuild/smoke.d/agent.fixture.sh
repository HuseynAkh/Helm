#!/usr/bin/env bash
# AI mode's fixture: a folder of mixed files to organize, a folder of 30 files in the Google Drive stand-in, a folder
# of 30 files that the steps make answer as a shared server, a file outside the home that no plan may reach, and the
# scripted model's answers. The app reads agent-script.json beside the home at launch; agent-hostile.json is loaded
# by a step (agent-script) and answers as a model that tries to get round Helm's rules, and agent-search-fails.json
# is the usual script with no answer for a search.
mess="$fix/home/AgentMess"
mkdir -p "$mess"
echo p1 > "$mess/photo-1.png"
echo p2 > "$mess/photo-2.jpg"
echo m > "$mess/memo.txt"
echo t > "$mess/todo.txt"
echo s > "$mess/scan.pdf"
echo d > "$mess/draft-old.txt"
drive="$fix/home/Library/CloudStorage/GoogleDrive-me@example.com/Shared/Drive Mess"
places="$fix/home/AgentPlaces"
share="$places/Share"
mkdir -p "$drive" "$share"
for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    echo "page $n" > "$drive/page-$n.txt"
    echo "share $n" > "$share/share-$n.txt"
done
echo outside > "$fix/outside.txt"
python3 - "$fix" <<'PY' || exit 1
import json, os, sys
fix = sys.argv[1]

def listing(folder="@root"):
    return {"calls": [{"name": "list_folder", "args": {"folder": folder, "depth": 1, "after": ""}}]}

def proposal(text, new_folders=(), moves=(), copies=(), renames=(), trash=()):
    return {"text": text, "calls": [{"name": "propose_changes", "args": {
        "new_folders": list(new_folders), "moves": list(moves), "copies": list(copies),
        "renames": list(renames), "trash": list(trash)}}]}

search = {"searchPlan": {"sort": "relevance", "queries": []}, "searchRank": {"ranked": []}, "models": ["scripted-1"]}
anything = {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}

numbers = ["%02d" % n for n in range(1, 31)]
places = [
    # In the Google Drive stand-in: all 30 pages into one new folder, and a copy of a page that isn't downloaded.
    {"when": "gather the pages", "turns": [listing(), proposal(
        "The pages go into one folder.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Pages"}],
        moves=[{"items": [], "all_in": "@root", "to": "n1"}])]},
    {"when": "copy the first page", "turns": [listing(), proposal(
        "A copy of the first page.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Copies"}],
        copies=[{"items": ["@name:page-01.txt"], "all_in": "", "to": "n1"}])]},
    # With Documents on show and its Reports folder answering as iCloud Drive: a file out of Reports into Documents.
    {"when": "file the report", "turns": [listing(), listing("@name:Reports"), proposal(
        "The report goes into Documents.",
        moves=[{"items": ["@name:q1.txt"], "all_in": "", "to": "@root"}])]},
    # On the shared server stand-in, which has no Trash.
    {"when": "share changes", "turns": [listing(), proposal(
        "One page to the Trash and a copy of another.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Copies"}],
        copies=[{"items": ["@name:share-02.txt"], "all_in": "", "to": "n1"}],
        trash=["@name:share-01.txt"])]},
    {"when": "rename the share", "turns": [listing(), proposal(
        "Every file gets a longer name.",
        renames=[{"item": "@name:share-%s.txt" % n, "name": "shared-%s.txt" % n} for n in numbers])]},
    {"when": "look around", "turns": [listing(), {"text": "That's everything in it."}]},
]

script = {"rules": places + [
    {"when": "organize", "turns": [listing(), proposal(
        "Photos go into Images and the text files into Notes.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Images"},
                     {"key": "n2", "parent": "@root", "name": "Notes"}],
        moves=[{"items": ["@name:photo-1.png", "@name:photo-2.jpg"], "all_in": "", "to": "n1"},
               {"items": ["@name:memo.txt", "@name:todo.txt"], "all_in": "", "to": "n2"}])]},
    {"when": "tidy", "turns": [listing(), proposal("The old draft can go.", trash=["@name:draft-old.txt"])]},
    anything], **search}

# Each rule tries one thing Helm refuses. "escape" names items by path, and one of them is outside the home.
hostile = {"rules": [
    {"when": "declined", "turns": [{"text": "No.", "stop": "refusal"}]},
    {"when": "too long", "turns": [{"text": "Here is a very long", "stop": "max_tokens"}]},
    {"when": "bad tools", "turns": [{"calls": [{"name": "run_command", "args": {"command": "list"}}]},
                                    {"calls": [{"name": "open_url", "args": {"address": "example"}}]}]},
    {"when": "escape", "turns": [listing(), proposal(
        "Moving those in here.",
        moves=[{"items": [os.path.join(fix, "outside.txt"), "~/Documents/notes.txt", "r999"], "all_in": "", "to": "@root"}])]},
    {"when": "make an app", "turns": [listing(), proposal(
        "Making a tool.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Tools.app"}],
        moves=[{"items": ["@name:scan.pdf"], "all_in": "", "to": "n1"}],
        renames=[{"item": "@name:memo.txt", "name": "memo.command"}])]},
    {"when": "broken", "turns": [], "failure": "unreachable"},
    anything], **search}

no_search = {key: value for key, value in script.items() if key != "searchPlan"}

for name, value in (("agent-script.json", script), ("agent-hostile.json", hostile), ("agent-search-fails.json", no_search)):
    with open(os.path.join(fix, name), "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1)
PY
