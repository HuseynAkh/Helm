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
# Every picture at the sharpest screen's scale, whichever screen is the main one; the windows stay invisible
screen sharpest
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
go @FIX@/home/Pictures/Camera Roll
wait 3
go @FIX@/home/Downloads
wait 2
go @FIX@/home/Documents
wait 2
go @FIX@/home/Documents/Invoices
wait 2
# The file manager, with AI mode off, as Helm starts
# The camera roll in the grid, dark and light
appearance dark
go @FIX@/home/Pictures/Camera Roll
view grid
select IMG_4098.jpg
wait 3
screenshot @SHOTS@/hero-dark.png
appearance light
wait 1.5
screenshot @SHOTS@/hero-light.png
# Typing a path from Home: ~ for the home folder, and the suggestions for what's typed, folders first, with the rest
# of the first one in grey, ready for Tab
appearance dark
go @FIX@/home
view grid
wait 1
type ~/Documents/Pro
wait 1
typed-rows Projects,Proposals,Prototypes,Product Roadmap.pdf,Progress Report.pdf
screenshot-popups @SHOTS@/path-dark.png
appearance light
wait 1.5
screenshot-popups @SHOTS@/path-light.png
location-escape
location @FIX@/home
# AI mode: the plan, the result and AI search, taken in light and dark, for the README's pairs.
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
# Done opens the AI panel on the folder on show, with Organize to press
ai-screen-press Done
ai-screen-is closed
setting-is aiModeEnabled true
agent-is open
agent-phase idle
agent-scope-is thisFolder
agent-contents-is off
agent-suggests Organize 10 items
appearance light
wait 1
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
agent-close
agent-is closed
# AI search from Home, kept to photos, with Read contents on: Helm finds the photos with a dog in them by what Apple's
# on-device recognition sees, on this Mac, and the model looks at them and keeps the four at the beach
appearance dark
go @FIX@/home
view grid
wait 1
agent-script @FIX@/agent-dogs.json
search-open
search-ai on
search-ai-is on
search-kinds-shown true
search-kind Photo
search-kind-is Photo
search-contents on
search-contents-is on
search photos of my dog at the beach
search-return
search-status-reads Looked at
has IMG_4127.jpg
has IMG_4133.jpg
has IMG_4140.jpg
has IMG_4152.jpg
lacks IMG_3988.jpg
lacks IMG_3861.jpg
lacks IMG_4120.jpg
result-reason IMG_4127.jpg=Model saw: A golden retriever running along the water's edge on a beach
# A click on the files: the search keeps its words and results, and its field rests, as a finished search does
focus-files
search-shown true
search-looks resting
has IMG_4152.jpg
wait 3
screenshot @SHOTS@/ai-search-dark.png
appearance light
wait 1.5
screenshot @SHOTS@/ai-search-light.png
quit
