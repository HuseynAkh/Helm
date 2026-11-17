# The README's pictures, over the made-up home that make_demo_home.swift draws. Nothing in them comes from a real Mac.
# Run by scripts/readme/make_readme_images.sh, which fills in @FIX@ and @SHOTS@ and writes the scripted model's
# answers to @FIX@/agent-script.json. AI mode's pictures use that scripted model, so no request leaves the Mac.
windows 1
free-space hidden
# One size for every window picture, so they keep the same proportions down the page
window-size 1240 760
# Each picture draws its window as the window in front: window buttons in colour, the accent on Apply, Continue and
# the switches. The run itself stays in the background
active-look on
app-icon docs/brand/logo-variants/variant-4-isometric.png
setting-is aiModeEnabled false
# A bookmark, a starred file and a few things opened lately, as on a Mac in use
bookmark @FIX@/home/Documents/Projects
go @FIX@/home/Documents
star-now Quarterly Report.pdf
recent-record @FIX@/home/Documents/Product Roadmap.pdf
recent-record @FIX@/home/Downloads/Concert Poster.jpg
recent-record @FIX@/home/Documents/Meeting Notes.md
recent-record @FIX@/home/Pictures/Wallpapers
recent-record @FIX@/home/Pictures/Sunset over the Bay.jpg
recent-record @FIX@/home/Documents/Invoices
recent-record @FIX@/home/Documents/Quarterly Report.pdf
recent-record @FIX@/home/Documents/Projects/Lighthouse
# Thumbnails are made in the background, so look at each folder once before its picture is taken
go @FIX@/home/Pictures
view grid
wait 4
go @FIX@/home/Downloads
wait 2
go @FIX@/home/Documents
wait 2
go @FIX@/home/Documents/Invoices
wait 2
# The file manager, with AI mode off, as Helm starts
# Pictures in the grid, dark and light
appearance dark
go @FIX@/home/Pictures
view grid
select Sunset over the Bay.jpg
wait 3
screenshot @SHOTS@/hero-dark.png
appearance light
wait 1.5
screenshot @SHOTS@/hero-light.png
# Folders that open in place in the list
go @FIX@/home/Documents
view list
disclose Projects
disclose Invoices
select Quarterly Report.pdf
wait 1.5
screenshot @SHOTS@/list-light.png
# Recent, folders apart from files
appearance dark
cmd recents
view grid
wait 3
screenshot @SHOTS@/recent-dark.png
# Searching from Home
go @FIX@/home
view grid
search-type invoice
wait 3
screenshot @SHOTS@/search-dark.png
search-key escape
# AI mode, after Recent's picture so Recent shows none of its folders. The plan, the result, Whole Mac, Read contents
# and AI search are taken in light and dark, for the README's pairs.
# The AI Mode screen, switched on with a stand-in key, which the screen never draws
appearance dark
go @FIX@/home/Downloads
view grid
wait 1
ai-screen open
ai-screen-is open
ai-screen-press AI Mode
wait 0.5
ai-screen-press Claude
ai-key readme-stand-in-key
ai-state-is connected
wait 0.5
# Done opens the AI panel: the folder on show, This Folder and Whole Mac, the consent line, three suggestions, the
# composer with the model and Read contents
ai-screen-press Done
ai-screen-is closed
setting-is aiModeEnabled true
agent-is open
agent-phase idle
agent-scope-is thisFolder
agent-contents-is off
agent-suggests Organize 10 items|Move everything to…|Copy everything to…
wait 1.5
screenshot @SHOTS@/ai-panel-dark.png
appearance light
wait 1.5
screenshot @SHOTS@/ai-panel-light.png
# A plan: nothing changes until Apply, and the Trash group starts unticked
agent-press Organize 10 items
agent-phase plan
agent-plan-reads 9 moves · 3 new folders
agent-group Move 1 item to the Trash off
agent-group-path Move 3 items to “Images”=~/Downloads/Images new folder
wait 1
screenshot @SHOTS@/ai-plan-light.png
appearance dark
wait 1.5
screenshot @SHOTS@/ai-plan-dark.png
appearance light
wait 1
exists @FIX@/home/Downloads/Beach Day.jpg
# Apply, then one Undo puts everything back
agent-press Apply
agent-phase result
agent-reads Moved 9 items into 3 folders.
wait 1.5
screenshot @SHOTS@/ai-undo-light.png
appearance dark
wait 1.5
screenshot @SHOTS@/ai-undo-dark.png
appearance light
wait 1
exists @FIX@/home/Downloads/Images/Beach Day.jpg
exists @FIX@/home/Downloads/Read Me.txt
agent-undo
agent-reads Everything is back where it was.
exists @FIX@/home/Downloads/Beach Day.jpg
missing @FIX@/home/Downloads/Images
agent-say /clear
# Whole Mac, from the Desktop, with the panel's edge dragged out to 440 points: the consent line names the home
# folder and disks, and the screenshots go to the Screenshots folder in Pictures, which only the home folder's listing
# shows.
# Cancel leaves them where they are, and a double click on the edge puts back 340 points
go @FIX@/home/Desktop
wait 1
agent-drag-edge 100
agent-width 440
agent-scope wholeMac
agent-scope-is wholeMac
agent-reads Sends your requests and file names from your home folder and disks to Claude, never file contents.
agent-say file my screenshots
agent-phase plan
agent-group Move 2 items to “Screenshots” on
agent-group-path Move 2 items to “Screenshots”=~/Pictures/Screenshots
wait 1
screenshot @SHOTS@/ai-whole-mac-light.png
appearance dark
wait 1.5
screenshot @SHOTS@/ai-whole-mac-dark.png
appearance light
wait 1
agent-press Cancel
exists @FIX@/home/Desktop/Screenshot 14.20.05.png
agent-scope thisFolder
agent-edge-double-click
agent-width 340
# Read contents, in a folder of scans whose names say nothing: Helm reads inside them on this Mac and hands the model
# short summaries, and the plan files the receipts and the invoice by what they say
go @FIX@/home/Documents/Scans
wait 1
agent-contents on
agent-contents-is on
agent-reads Sends your requests, file names and what it reads inside files to Claude: text, and small copies of pictures and video frames.
agent-say sort these scans
agent-phase plan
agent-reads and 6 summaries to Claude.
agent-group Move 4 items to “Receipts” on
wait 1
screenshot @SHOTS@/ai-contents-light.png
appearance dark
wait 1.5
screenshot @SHOTS@/ai-contents-dark.png
appearance light
wait 1
agent-press Cancel
missing @FIX@/home/Documents/Scans/Receipts
agent-say /clear
agent-contents-is off
agent-close
agent-is closed
# AI search from Home, kept to photos, with Read contents on: Helm looks inside the pictures on this Mac for the word
# typed, and finds the receipts by the word printed on them. Nothing it reads is sent
appearance dark
go @FIX@/home
view grid
wait 1
agent-script @FIX@/agent-receipts.json
search-open
search-ai on
search-ai-is on
search-kinds-shown true
search-kind Photo
search-kind-is Photo
search-contents on
search-contents-is on
search the photo of the receipt
search-return
search-status-reads Photos
has IMG_2041.jpg
has IMG_1988.jpg
has IMG_2102.jpg
has IMG_2066.jpg
has IMG_2079.jpg
has IMG_2110.jpg
lacks Sunset over the Bay.jpg
result-reason IMG_2041.jpg=Text in image: “receipt” · Image
# A click on the files: the search keeps its words and results, and its field rests, as a finished search does
focus-files
search-shown true
search-looks resting
has IMG_2110.jpg
wait 3
screenshot @SHOTS@/ai-search-dark.png
appearance light
wait 1.5
screenshot @SHOTS@/ai-search-light.png
agent-script @FIX@/agent-script.json
# The header with the panel open: one button for Grid and List, the sort button, the mark, lit, and the main menu
appearance dark
go @FIX@/home/Documents
view grid
wait 1
agent-open
agent-is open
wait 1
header-shot @SHOTS@/header-dark.png 64
agent-close
# Settings › AI
appearance light
settings-shot ai @SHOTS@/settings-ai-light.png
setting aiModeEnabled false
wait 0.5
appearance dark
go @FIX@/home/Documents
view grid
wait 1
# The view options popover
popover-shot @SHOTS@/view-options-dark.png
view-options close
# Settings › Sidebar
appearance light
settings-shot sidebar @SHOTS@/settings-sidebar-light.png
# The Trash without Full Disk Access
fixture-chmod 000 @FIX@/home/.Trash
open-trash
wait 1
screenshot @SHOTS@/trash-card-light.png
fixture-chmod 755 @FIX@/home/.Trash
# The onboarding, one step at a time, against the fixture's stand-ins: Full Disk Access, then AI mode as a step of
# its own, with OpenAI picked to show Continue with ChatGPT
appearance light
onboarding open
setup-step welcome
onboarding-press Continue
setup-step access
onboarding-shot @SHOTS@/onboarding-access-light.png
onboarding-press Continue
setup-step viewer
onboarding-press Continue
wait 2
setup-step ai
onboarding-press AI mode
ai-provider openAI
wait 0.5
onboarding-shot @SHOTS@/onboarding-ai-light.png
onboarding close
quit
