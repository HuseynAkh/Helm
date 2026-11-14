# The README's pictures, over the made-up home that make_demo_home.swift draws. Nothing in them comes from a real Mac.
# Run by scripts/readme/make_readme_images.sh, which fills in @FIX@ and @SHOTS@ and writes the scripted model's
# answers to @FIX@/agent-script.json. AI mode's pictures use that scripted model, so no request leaves the Mac.
windows 1
free-space hidden
window-size 1240 800
activate
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
# AI mode, after Recent's picture so Recent shows none of its folders.
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
ai-screen-shot @SHOTS@/ai-mode-screen.png
# Done opens the AI panel: the folder on show, the consent line and three suggestions for it
ai-screen-press Done
ai-screen-is closed
setting-is aiModeEnabled true
agent-is open
agent-phase idle
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
wait 1
screenshot @SHOTS@/ai-plan-light.png
exists @FIX@/home/Downloads/Beach Day.jpg
# Apply, then one Undo puts everything back
agent-press Apply
agent-phase result
agent-reads Moved 9 items into 3 folders.
wait 1.5
screenshot @SHOTS@/ai-undo-light.png
exists @FIX@/home/Downloads/Images/Beach Day.jpg
exists @FIX@/home/Downloads/Read Me.txt
agent-undo
agent-reads Everything is back where it was.
exists @FIX@/home/Downloads/Beach Day.jpg
missing @FIX@/home/Downloads/Images
agent-say /clear
agent-close
agent-is closed
# AI search from Home: the model plans the searches, Helm runs them on this Mac and says why each one matched
appearance dark
go @FIX@/home
view grid
wait 1
search-open
search-ai on
search-ai-is on
search the invoices from this fall
search-return
search-status-reads invoice
result-reason Invoice October.pdf=Name has “invoice” · PDF
wait 3
screenshot @SHOTS@/ai-search-dark.png
search-key escape
# Settings › AI
appearance light
settings-shot ai @SHOTS@/settings-ai-light.png
setting aiModeEnabled false
wait 0.5
# The header: one button for Grid and List, the sort button, the spark and the main menu
appearance dark
go @FIX@/home/Documents
view grid
wait 1
header-shot @SHOTS@/header-dark.png 64
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
# The setup screen
onboarding open
onboarding-shot @SHOTS@/setup-light.png
onboarding close
quit
