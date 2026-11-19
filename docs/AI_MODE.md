# AI mode

AI mode is a model that works on your files through Helm: it finds files by what you describe, and plans changes you approve. It's off until you turn it on, and nothing changes until you press Apply.

## Open the panel

The trefoil at the top right opens the AI panel beside your files, or press ⌃⌘I. The panel works in the folder on show. **Organize** sorts it, or the items selected, into folders by kind. Or type what you want, such as "move the PDFs into Papers", or "write a packing list for the trip in a new Trip folder".

Under the composer, the model's name is a menu of the models your connected providers offer, when there's more than one. Drag the panel's left edge to make it 300 to 560 points wide, up to 45% of the window; a double click puts it back to 340.

## Plan, then Apply

Helm shows the plan before anything happens. A plan can make folders and new files, and move, copy, rename or put things in the Trash. New files can be plain text, Markdown, CSV, JSON, HTML, code, RTF or Word, with the text the model wrote. Each group of changes has a tick and its full list, and a group of moves, copies or new files says which folder it goes to. Moving to the Trash, anything that lands where others can see it, new files included, and code and web pages start unticked. Press Apply, and one Undo puts it all back.

## This Folder or Whole Mac

Every new thread starts in **This Folder**: the folder on show, plus any you add. Switch the folders row to **Whole Mac** and AI mode can look through your home folder, iCloud Drive, your cloud folders and your disks, and propose moving files to where they belong. It never sees system folders, your Library or other apps' data. The thread's first line then says so.

## Read contents

Names don't always say what a file is. Turn on **Read contents** under the composer, and the model reads and looks for itself: the text of documents (text, RTF, PDFs, .docx and .odt), the pictures, and a few frames of each video. Helm makes a small copy of each picture and frame on your Mac, without its location or camera details, and sends it with the request. So the model can file a scan by what it says, and a photo by what it shows. Read contents is off in every new thread, and turning it on or off starts the thread over.

## Find with AI

Turn on the trefoil in the search field and describe the file. The model plans the searches, Helm runs them on your Mac, and the status bar says how it read your words. Point at a result to see why it matched.

Results come in order of how well they fit. A name that matches your words beats one that only holds them, and the words you typed count as well as the model's. Between files that match about as well, the one nearer the folder you searched comes first: what's in the folder, then a folder down, and so on. Across the whole Mac, nearness is measured from your home folder. A file deep down whose name matches better still comes first, and the model then puts the best fits at the top.

The row under the header keeps a search to one kind: Photo, Video, Document, Folder, Code, Audio or Archive. With nothing typed, a kind lists every file of that kind in the place searched, a folder at a time: what's in the folder first, newest first, then a folder down, and so on. Any goes back to the folder. Turn on **Read contents** at the end of the row and the model also looks at up to 48 photos, videos and documents and says which match: 24 with a model on your Mac that sees pictures, four a question so each fits a small context, and 12 with one that reads text only. Across the whole Mac it looks only at files the search or Apple's on-device recognition matched; in a folder, also at the nearest that fit the rest of your words, newest first among those at the same depth. So "photos of my dog at the beach" finds the four beach photos in a camera roll named IMG_3740 to IMG_4152, by what they show, whatever their names, and pointing at one says what the model saw. While it reads and looks, the status bar says so, and if the model didn't answer for some files it says how many and why.

## How it works

- **AI mode** is a model that works on your files through Helm. It lists folders and proposes changes, new files included. Helm checks every change, and only Helm touches the disk. Code and web pages start unticked, and a new file can't be an app, a Windows script, a link or an installer.
- **Bring your own model.** OpenAI with your ChatGPT plan: click **Continue with ChatGPT**, with no key to paste. Claude, Gemini and Grok with your key. Ollama and LM Studio on your Mac. Or any OpenAI-compatible API, by its https address.
- **It can read and look.** With Read contents on, the model reads documents and looks at pictures and video frames, so it can sort and find files by what's in them.
- **Only the folders you give it.** The folder on show, plus any you add: type `/add` and a folder, type or drop a path, or drop a folder on the panel. Whole Mac adds your home folder, cloud folders and disks. `/clear` starts over, back in This Folder.
- **Remote and cloud folders.** iCloud Drive, Google Drive, Dropbox, OneDrive, servers and external disks work too. The folder's chip says where it is, and the plan says when changes will sync or reach other people. Helm never downloads files to do it.
- **Nothing changes until you press Apply.** Changes run through Helm's own file operations, so conflicts keep both files, removals go to the Trash, and one Undo puts everything back.

## Connect a provider

AI mode is off until you turn it on. The onboarding's AI Mode step and Settings › AI hold the same choices. Beside each provider, the ⓘ button says in one line what it uses and what it costs, and **How to connect** opens the provider's own page in your browser.

| Provider | How to connect |
|---|---|
| OpenAI | Click **Continue with ChatGPT** and sign in in your browser. Your ChatGPT plan pays for the requests. **Use an API key instead** takes a key from [OpenAI's platform](https://developers.openai.com/api/docs/quickstart) |
| Claude | Paste an API key from the [Claude Console](https://platform.claude.com/docs/en/manage-claude/authentication#api-keys). Anthropic requires a key for apps like Helm and doesn't allow them to use a Claude plan |
| Gemini | Paste an API key from [Google AI Studio](https://aistudio.google.com/docs/api-key) |
| Grok | Paste an API key made as [xAI's quickstart](https://docs.x.ai/docs/quickstart) shows |
| Ollama | Open [Ollama](https://docs.ollama.com/quickstart) and download a model. Helm finds it on this Mac |
| LM Studio | Turn on LM Studio's [local server](https://lmstudio.ai/docs/developer/core/server) and load a model. **Refresh Models** in Settings › AI picks up one loaded later |
| Other | Type the service's https address, and its key if it needs one |

