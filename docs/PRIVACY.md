# Privacy

**Helm collects nothing.** It has no servers, accounts, analytics or crash reports, so nothing you do in Helm reaches its makers. AI mode talks to one place, the provider you choose, straight from your Mac, and only while AI mode is on. It is off until you turn it on.

**What is sent.** Your requests, and the names and details of files (size, dates and kind). Never what's inside a file, unless you turn on Read contents. The top of every thread says what it sends, and each request says how many names it sent. With Whole Mac on, the names can come from anywhere in your home folder, your cloud folders and your disks, but never from your Library, hidden files or system folders.

- **Read contents** is off until you turn it on, under the AI panel's composer or at the end of AI search's kind row, and it lasts for that thread or that search. Helm then reads inside files on your Mac with Apple's own frameworks (ImageIO, PDFKit, Vision and AVFoundation), and the model gets:
  - **Documents:** the first 1,500 characters of text files, RTF, Word (.docx) and OpenDocument (.odt) documents and PDFs. Older Word files (.doc) aren't read.
  - **Pictures:** a small copy, 512 pixels on its longer side, made on your Mac with no location, camera or date in it.
  - **Videos:** small copies of three to five frames taken through it.
  - **Scanned PDFs:** their first page as a small copy.
  - With each picture and frame, what Apple's on-device recognition found in it: up to five things it shows, and any text.

  The files themselves never leave your Mac, and neither do full-size pictures. With Ollama or LM Studio nothing leaves your Mac at all, and the thread's first line says "Reads text, pictures and video frames inside files on this Mac; nothing leaves your Mac." With any other provider, what Helm reads goes to it, and the first line says "Sends your requests, file names and what it reads inside files to" that provider. A model that can't take pictures gets the on-device description instead. LM Studio says which of its models see pictures, and Settings › AI shows it under the model; a model that reads text only, such as gpt-oss, is never sent pictures, only their description. Text and pictures from inside a file are handed over as data, and the model is told never to follow instructions in them. Whatever it proposes, Helm checks every change, and nothing happens until you press Apply.
- In the AI panel, Read contents reads 50 files a request at most and sends 24 pictures at most. It reads text and PDFs up to 20 MB, .docx and .odt files that unpack to 16 MB at most, and pictures up to 50 MB and 100 megapixels.
- In AI search, Read contents first reads up to 200 candidates on your Mac. Then the model looks at 48 of them at most, or on your Mac 24 with a model that sees pictures and 12 with one that reads text only, and their small copies and first lines are sent with the question: across the whole Mac only files the search or the on-device recognition matched, in a folder its newest files too. Code goes only when you choose Code, and settings files such as JSON or YAML only with Code or Document. Helm forgets what it read when the search closes.
- Read contents never downloads a file to read it, never follows a link, never reads a key, password or wallet file, and doesn't listen to the speech in a video.
- AI search without Read contents sends your words and the names of files that match. A match can come from text inside a file, found by Spotlight on this Mac. That text is never sent.
- A path you type in the middle of a message is sent as you typed it, your home folder's name included. A folder at the end of a message is added to the panel and sent only as an id.

**Where it goes.** Only to the one you picked:

| Provider | Address |
|---|---|
| Claude | `https://api.anthropic.com` |
| OpenAI | `https://api.openai.com/v1`. Signing in with ChatGPT also goes to OpenAI's sign-in host, `https://auth.openai.com`, which gets no file names |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` |
| Grok | `https://api.x.ai/v1` |
| Ollama, LM Studio | Loopback, `127.0.0.1`, on this Mac. Ports 11434 and 1234 unless you change them |
| Other | The https address you type |

**Signing in with ChatGPT.** Your browser opens OpenAI's sign-in page, and comes back to Helm on this Mac: Helm listens on `127.0.0.1` for that one visit, for up to five minutes, then stops. Helm sends OpenAI a random ID for this Mac and the name Helm, never your name or your Mac's. Your email is shown in Settings › AI and is never sent to a model. The sign-in's tokens stay in your Mac's keychain, never in a file, a log or `ai.json`, and Helm renews them as they run out. **Remove** in Settings › AI signs out and asks OpenAI to revoke them; if OpenAI doesn't confirm, disconnect Helm under **Sign in with ChatGPT** in ChatGPT's settings. [OpenAI's help](https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites) explains plan use in other apps, and [ChatGPT's usage page](https://chatgpt.com/settings/usage) shows what Helm used.

**Keys.** Claude requires a key: Anthropic doesn't allow apps like Helm to sign in with a Claude account or use a Claude plan. Each key is saved in your Mac's keychain, never in a file, a log or a picture. Removing the app doesn't remove keys or a sign-in: click **Remove Key** or **Remove** in Settings › AI first, or delete the items named **Helm AI key** and **Helm ChatGPT sign-in** in Keychain Access (their place is `com.helm.filemanager.ai-key`). Helm is signed ad hoc, so macOS may ask for your keychain password after an update.

Keys are made on each provider's site, as the table under [Connect a provider](AI_MODE.md#connect-a-provider) shows. What a provider keeps, and for how long, is up to its own terms. On Gemini's free tier, Google may use what you send to improve its products.

The help pages open in your browser. Helm itself never connects to them.

**Limits.**

- **No downloads in cloud folders.** A file that isn't downloaded is left out of any change that needs its contents, and isn't read by Read contents, and Helm says how many.
- **Places with no Trash**, such as some servers: copies and new folders there can't be undone, and the plan says so before you press Apply.
- **Small local models** can miss files in big folders. Many load a small context by default.
- **A mirrored cloud folder with no shortcut reads as This Mac.** A sync app that keeps a plain folder in step and marks nothing, such as an older Dropbox, isn't recognized, so the plan won't say that changes sync.
- **Folders outside the home folder and the volumes** can't be used, such as `/opt` or `/usr/local`. AI mode works in your home folder, on disks under `/Volumes`, and in the Shared folder.

**Nothing is saved.** Threads, added folders and plans stay in memory. They're gone after `/clear`, when the window closes, when AI mode turns off, or when Helm quits.

Helm makes no other connections, not even update checks, and it doesn't read your name, your Mac's name or its serial number. It reads each disk's ID only to list the disk once, and never keeps or sends it. Otherwise files leave your Mac only when you send them: Share, AirDrop, Connect to Server, Open With, Services, drag and drop, the clipboard, or by putting them in iCloud Drive, a cloud provider's folder or a server.

What Helm keeps stays on your Mac, in `~/Library/Application Support/Helm`:

| File | What it holds |
|---|---|
| `recent.json` | Folders and files you opened, for Recent. Settings › General › **Remember recent items** turns it off, and **Go › Clear Recent** empties it. |
| `open-with.json` | Apps you've used for each kind of file, for Open With. Clear Recent empties it too. |
| `session.json` | Your windows and tabs, only while **Reopen windows and tabs** is on. |
| `bookmarks.json`, `stars.json`, `sidebar.json`, `tag-catalog.json` | Your sidebar and tags. A star or bookmark you remove leaves nothing in them. |
| `view-options.json` | Views you set for particular folders. |
| `ai.json` | AI mode's provider, models, ports, the address you typed for Other, whether OpenAI uses a key in place of your ChatGPT sign-in, and which build of Helm saved each key. Never a key, a token, a folder or a conversation. |
| `trash-origins.json` | Where trashed items came from, for Put Back. A record goes when its item leaves the Trash through Helm, or at Helm's next launch once it sees the item is gone. Without Full Disk Access Helm can't look in the Trash, so a Trash emptied in Finder leaves its records, up to 1,000. |

Settings live in `~/Library/Preferences/com.helm.filemanager.dev.plist`, the AI panel's width and how far the onboarding got among them. To remove everything, first click **Restore Finder** in Settings › General and turn off **Show next to Finder in the Dock** and **Open at login**. Click **Remove Key**, or **Remove** for a ChatGPT sign-in, in Settings › AI. Then quit Helm and delete that file and the folder above.

Checks keep it this way. `scripts/privacy_check.py` reads the source and fails if network code appears outside AI mode's one transport file, if a socket appears outside the one file that listens on `127.0.0.1` for a ChatGPT sign-in, if a web address appears that isn't one of the providers', OpenAI's sign-in host or the listed help pages, if anything but one file looks inside files with PDFKit, Vision or AVFoundation, if rich text could be read as HTML or a web archive, if anything but Read contents' two switches can turn reading on, if AI mode's own module could open a file, or if tracking or identifier code appears; the release script and workflow run it before they build. Every release then passes `scripts/release/check_binary_privacy.sh`, which checks the built app's libraries, its network and identifier calls (it may listen, never connect a socket), web addresses, paths from the build machine, Info.plist and signature. Smoke runs block Helm's networking, so any try at it fails the run, and one run turns AI mode on with the shipped code to prove the block bites.
