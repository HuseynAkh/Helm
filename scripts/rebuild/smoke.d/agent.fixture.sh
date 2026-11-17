#!/usr/bin/env bash
# AI mode's fixture: a folder of mixed files to organize, a folder of 30 files in the Google Drive stand-in, a folder
# of 30 files that the steps make answer as a shared server, a file outside the home that no plan may reach, a
# Pictures/Screenshots folder for Whole Mac to file a screenshot into, a folder of made-up files for Read contents to
# look inside, and the scripted model's answers. The app reads agent-script.json beside the home at launch; agent-hostile.json is loaded
# by a step (agent-script) and answers as a model that tries to get round Helm's rules, and agent-search-fails.json
# is the usual script with no answer for a search. agent-contents.json answers the Read contents steps.
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
# Read contents: the made-up files of Tests/HelmUITests/Fixtures/Contents (scripts/rebuild/make_content_fixtures.swift
# draws them): a note, a file that tries to give orders, a scanned invoice, a photo of a receipt, a sky with no words
# and a short video, plus a copy of the receipt that the steps mark as not downloaded.
look="$fix/home/AgentLook"
mkdir -p "$look"
cp Tests/HelmUITests/Fixtures/Contents/* "$look/" || exit 1
cp "$look/receipt-photo.png" "$look/receipt-copy.png"
mkdir -p "$fix/home/Pictures/Screenshots"
echo older > "$fix/home/Pictures/Screenshots/older.png"
python3 - "$fix" <<'PY' || exit 1
import json, os, sys
fix = sys.argv[1]

def listing(folder="@root"):
    return {"calls": [{"name": "list_folder", "args": {"folder": folder, "depth": 1, "after": ""}}]}

def proposal(text, new_folders=(), new_files=(), moves=(), copies=(), renames=(), trash=()):
    return {"text": text, "calls": [{"name": "propose_changes", "args": {
        "new_folders": list(new_folders), "new_files": list(new_files), "moves": list(moves), "copies": list(copies),
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
    # Whole Mac, with Documents on show: the home folder's listing finds Pictures/Screenshots, and the screenshot in
    # Documents goes there.
    {"when": "file the screenshot", "turns": [
        {"calls": [{"name": "list_folder", "args": {"folder": "@home", "depth": 2, "after": ""}},
                   {"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
        proposal("The screenshot goes into Screenshots in Pictures.",
                 moves=[{"items": ["@name:Screenshot 2026-11-02 at 09.15.00.png"], "all_in": "", "to": "@name:Screenshots"}])]},
    # A new folder and one file into it: two changes, one command each, so Stop can come between them.
    {"when": "stop halfway", "turns": [listing(), proposal(
        "A folder, then the memo into it.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Halfway"}],
        moves=[{"items": ["@name:memo.txt"], "all_in": "", "to": "n1"}])]},
]

script = {"rules": places + [
    {"when": "organize", "turns": [listing(), proposal(
        "Photos go into Images and the text files into Notes.",
        new_folders=[{"key": "n1", "parent": "@root", "name": "Images"},
                     {"key": "n2", "parent": "@root", "name": "Notes"}],
        moves=[{"items": ["@name:photo-1.png", "@name:photo-2.jpg"], "all_in": "", "to": "n1"},
               {"items": ["@name:memo.txt", "@name:todo.txt"], "all_in": "", "to": "n2"}])]},
    {"when": "tidy", "turns": [listing(), proposal("The old draft can go.", trash=["@name:draft-old.txt"])]},
    # A new file with the text the model wrote, made only on Apply.
    {"when": "packing list", "turns": [listing(), proposal(
        "A packing list for the trip.",
        new_files=[{"parent": "@root", "name": "Packing List.txt", "text": "Passport\nCharger\nSocks\n"}])]},
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
        new_files=[{"parent": "@root", "name": "launch.command", "text": "open -a Calculator\n"}],
        moves=[{"items": ["@name:scan.pdf"], "all_in": "", "to": "n1"}],
        renames=[{"item": "@name:memo.txt", "name": "memo.command"}])]},
    {"when": "broken", "turns": [], "failure": "unreachable"},
    anything], **search}

no_search = {key: value for key, value in script.items() if key != "searchPlan"}

# Read contents, in AgentLook: a look inside six files, and a plan that files the two invoices, which only what is
# inside them tells apart. AI search's plan looks inside files for one word of the request each time; a query whose
# word isn't in the request is dropped, so one plan serves every search.
inside = ["@name:" + name for name in ("receipt-photo.png", "IMG_0042.png", "invoice-scan.pdf", "beach-day.mov",
                                       "groceries.md", "hostile-note.txt")]
looks = {"rules": [
    {"when": "look inside", "turns": [listing(), {"calls": [{"name": "read_contents", "args": {"ids": inside}}]},
                                      {"text": "Two of these are invoices, one is a sky and one is a beach video."}]},
    {"when": "look at the copy", "turns": [listing(), {"calls": [{"name": "read_contents", "args": {
        "ids": ["@name:receipt-copy.png", "@name:groceries.md"]}}]}, {"text": "The copy isn't on this Mac."}]},
    {"when": "file the invoices", "turns": [listing(), {"calls": [{"name": "read_contents", "args": {"ids": inside[:3]}}]},
                                            proposal("The receipt and the scan are invoices.",
                                                     new_folders=[{"key": "n1", "parent": "@root", "name": "Invoices"}],
                                                     moves=[{"items": ["@name:receipt-photo.png", "@name:invoice-scan.pdf"],
                                                             "all_in": "", "to": "n1"}])]},
    anything],
    "searchPlan": {"sort": "relevance", "queries": [
        {"content_all": [word], "name_all": [], "name_any": [], "folder_any": [], "kinds": [], "extensions": [],
         "date_field": "none", "date_from": "", "date_to": "", "size_min_bytes": 0, "size_max_bytes": 0}
        for word in ("invoice", "sky", "beach")]},
    "searchRank": {"ranked": []}, "models": ["scripted-1"]}

for name, value in (("agent-script.json", script), ("agent-hostile.json", hostile), ("agent-search-fails.json", no_search),
                    ("agent-contents.json", looks)):
    with open(os.path.join(fix, name), "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1)
PY
