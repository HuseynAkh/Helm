# HelmAgent

AI mode's own module: the model providers, the transport that reaches them, the loop that carries a request to a model and back, the folders a request may see, the change plans it ends in, and the planning side of AI search. It imports `Foundation`, `Security` and `HelmCore`, and nothing else: no AppKit, no SwiftUI and no other Helm module. So the code that can reach a model provider has no way to change or open a file. It learns about the disk only through HelmCore's read-only `AgentDisk`, and turning an approved plan into file changes belongs to HelmUI. `scripts/static_checks.py` fails when the module imports another Helm module, AppKit or SwiftUI.

Helm's promise with AI mode is: it connects only to the model provider the person chose, and only while AI mode is on. Most of what follows is how this module keeps that promise in a way a check can prove.

## Rules the module keeps

Each rule has a check behind it, in `scripts/privacy_check.py` or `scripts/static_checks.py`. Comments and strings count, so a banned word fails wherever it is written.

| Rule | Where it is allowed |
|---|---|
| A network connection | `Transport/HTTPTransport.swift`, and nowhere else in Helm |
| A web address | `Transport/Endpoints.swift`: four lines, one a provider. A model on this Mac is reached by number and a port, with no address written |
| A keychain call | `Secrets/KeychainSecretStore.swift` |
| Turning a key into text (`revealSecret`) | `Contracts/AgentSecrets.swift`, the keychain store and the transport |
| Any way to change, open or look inside a file, or to start a tool | Nowhere in this module. The word lists are the rules `agent-no-write` and `agent-no-read` |
| A string literal with a path from the Mac that built Helm | Nowhere. Stand-ins use `/home/helm` |

Four values carry authority, and each has an initializer whose first label may be written in one or two files only, so `.init(` and type inference can't get round it:

| Value | Label | Who may make one |
|---|---|---|
| `AgentPersonInput`, a message | `typedByPerson` | the panel's model |
| `AgentRootInput`, a folder to use | `fromPerson` | the panel's model and the window |
| `HTTPTransport` | `liveProfile` | `Runtime/AgentLiveParts.swift` |
| `AgentApprovedPlan` (in HelmUI), a plan to apply | `tickedByPerson` | the plan card |

Two more values can only be made by initializers that check what they are given. An `AgentEndpoint` is a provider's fixed address, a port on this Mac, or an https host name the person typed; an IP address, a one-word host and a `.local` name are refused, and plain http is only ever this Mac. An `AgentSecret` is a pasted key of printing ASCII characters that prints as `AgentSecret(hidden)` however it is printed.

## Where things are

| Folder | What it holds |
|---|---|
| `Contracts/` | Every public protocol and value: JSON, providers and endpoints, the model client, the transport, the wire adapter, keys, folders and handles, plans, the conversation, and the limits |
| `Text/` | `AgentText`: every sentence AI mode shows. Windows and panes use these members and never write a sentence themselves |
| `Transport/` | `HTTPTransport`, `Endpoints` (the provider catalog and the four addresses) and the reader that cuts a stream into lines |
| `Secrets/` | `MemorySecretStore` for tests and fixture runs, `KeychainSecretStore` for real keys |
| `Providers/` | One adapter for each wire format, the model lists, the mapping from a provider's errors to `AgentFailure`, and the live client that joins an adapter to a transport |
| `Runtime/` | `AgentRuntime`: whether AI mode is on, the chosen provider and model, and the one client. `AgentLiveParts` wires the live pieces |
| `Scope/` | Which folders a request may use, and the handles that stand for items |
| `Tools/` | `AgentToolCatalog` (the three tools and their schemas), `AgentToolCode`, and the code that runs a tool call |
| `Loop/` | The conversation: the prompt, the note Helm writes about the folders, the turns of a request |
| `Plan/` | Checking what a model proposed: names, places, and what must be left out |
| `Suggest/` | The three suggestions, worked out from counts with no model asked |
| `Search/` | The two questions AI search asks a model, and their schemas |
| `Scripted/` | A model that answers from a script, a disk in memory and a conversation with no model, for tests and fixture runs |

## How a request goes

1. The person types. `AgentComposerIntent.parse` reads the text and nothing else: `/add` and a folder, `/clear`, a path or a file address alone, a server address alone, or a message. A message that holds a word shaped like a provider's key is never sent. A message may end in a path; every word that could start one is a candidate, leftmost first.
2. The conversation (`AgentConversing`) sends the message to the model with the tools of `AgentToolCatalog`. A model names existing items by handles Helm issued (`r1`, `d7`, `f12`) and writes text only for new names. No tool takes a path or an address.
3. `list_folder` and `find_items` answer with names and details. Nothing inside a file is ever sent. The only words a model gets when a tool goes wrong are the cases of `AgentToolCode`.
4. `propose_changes` is decoded exactly (`AgentProposedChanges.decodeStrictly`) and checked into an `AgentChangePlan`. Helm builds everything on the plan's card from the checked steps: the title, the counts, the groups and the notes (`Contracts/AgentPlanShape.swift`). A group that removes something, or puts files where other people or other devices see them, carries a guard and starts unticked.
5. Nothing changes until the person presses Apply. The conversation hands the plan over once, for its own id and ticks (`beginApply`), and HelmUI runs it through the operation engine, so Undo, the Trash and Keep Both all hold.

## AI mode on and off

`AgentRuntime` starts off. While it is off, `client()` answers `.off`, `makeSession()` answers nil and nothing is built. Turning it on builds nothing either: the client is made the first time it is needed, for a provider with an address, a model, and a key where the provider needs one. Turning it off shuts the client down, which forgets the key it had cached, and stops and clears every conversation.

A changed provider, local port or typed address drops the client and starts every conversation over, so names listed for one provider are never sent to another. A changed model keeps the threads.

A fixture run gives the runtime a scripted client and no way to make a live one. The state is then ready as soon as AI mode is on, and `clientBuildCount` stays at 0.

## Seams

| Protocol | Live | Stand-in |
|---|---|---|
| `AgentModelClient` | `LiveModelClient` | `ScriptedModelClient` |
| `AgentTransport` | `HTTPTransport` | a recording transport in tests |
| `AgentSecretStoring` | `KeychainSecretStore` | `MemorySecretStore` |
| `AgentDisk` (HelmCore) | `FileSystemAgentDisk` (HelmFileSystem) | `MemoryAgentDisk` |
| `AgentConversing` | `AgentSession` | `StandInConversation` |
| `AgentPlanValidating` | `AgentPlanValidator` | a fake in tests |

The stand-ins are part of the module, not of a test target, because a fixture run of the app uses them. No target here declares resources: a resource bundle would put the build folder's path in the app.

## The scripted model

`ScriptedModelClient` answers from an `AgentScript`, which a fixture run loads from a JSON file:

```json
{"rules": [
  {"when": "organize", "turns": [
    {"calls": [{"name": "list_folder", "args": {"folder": "@root", "depth": 1, "after": ""}}]},
    {"text": "Images go into a new Images folder.",
     "calls": [{"name": "propose_changes", "args": {
        "new_folders": [{"key": "n1", "parent": "@root", "name": "Images"}],
        "moves": [{"items": ["@name:a.png", "@name:b.png"], "all_in": "", "to": "n1"}],
        "copies": [], "renames": [], "trash": []}}]}]},
  {"when": "broken", "turns": [], "failure": "unreachable"},
  {"when": "*", "turns": [{"text": "I can organize, move and copy files in these folders."}]}],
 "searchPlan": {"sort": "relevance", "queries": []},
 "searchRank": {"ranked": [{"row": 1, "why": ["name"]}]},
 "models": ["scripted-1"]}
```

- The first rule whose `when` is in the person's message answers it, without regard to case. `*` is in every message. Helm's own note about the folders, on lines that start with `[Helm]`, is not part of the message.
- Each of a rule's turns is one model turn of the request. Which turn is next is read from the history, so the client keeps no place of its own.
- `@root` is the folder marked "(on show)" in Helm's note. `@name:<file>` is the id that a tool result gave the item of that name, so a script doesn't depend on how ids are numbered. A mark that can't be filled in is left as it is, and the tool refuses it.
- `stop` may be `refusal` or `max_tokens`. `failure` is an `AgentFailure` by its raw value, and the request fails with it once the rule's turns are used up.
- `searchPlan` and `searchRank` answer AI search's two questions. Without one, that question fails.

The client keeps everything it was sent. `allSentText()` gives it back as one text, with every string inside the JSON spelled out again, so a test can show that a path or an account's name never left the app.

`MemoryAgentDisk` is a disk by path with the marks a real one can carry: hidden, not downloaded, not loaded, refused by macOS, slow, on a server or in a cloud folder. It notes every path it is asked about (`asked`).

## Tests

```
swift test --filter HelmAgentTests
bash scripts/static_checks.sh
```

`Tests/HelmAgentTests/Foundation` covers what is described above: the endpoint rules against trick spellings of an address, that a key never prints, JSON depth, the runtime's on and off, the scripted model, the memory disk, the tool schemas, every sentence of `AgentText` word for word, the composer, the suggestions and the plan's card. `Tests/HelmAgentTests/Fixtures` holds fixed files the tests read; it is copied into the test bundle only.
