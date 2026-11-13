#!/usr/bin/env bash
# AI mode's fixture: a folder of mixed files to organize, a file outside the home that no plan may reach, and the
# scripted model's answers. The app reads agent-script.json beside the home at launch; agent-hostile.json is loaded
# by a step (agent-script) and answers as a model that tries to get round Helm's rules.
mess="$fix/home/AgentMess"
mkdir -p "$mess"
echo p1 > "$mess/photo-1.png"
echo p2 > "$mess/photo-2.jpg"
echo m > "$mess/memo.txt"
echo t > "$mess/todo.txt"
echo s > "$mess/scan.pdf"
echo d > "$mess/draft-old.txt"
echo outside > "$fix/outside.txt"
python3 - "$fix" <<'PY' || exit 1
import json, os, sys
fix = sys.argv[1]

def listing():
    return {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]}

def proposal(text, new_folders=(), moves=(), copies=(), renames=(), trash=()):
    return {"text": text, "calls": [{"name": "propose_changes", "args": {
        "new_folders": list(new_folders), "moves": list(moves), "copies": list(copies),
        "renames": list(renames), "trash": list(trash)}}]}

search = {"searchPlan": {"sort": "relevance", "queries": []}, "searchRank": {"ranked": []}, "models": ["scripted-1"]}
anything = {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}

script = {"rules": [
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

for name, value in (("agent-script.json", script), ("agent-hostile.json", hostile)):
    with open(os.path.join(fix, name), "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1)
PY
