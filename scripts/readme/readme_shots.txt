# The README's pictures, over the made-up home that make_demo_home.swift draws. Nothing in them comes from a real Mac.
# Run by scripts/readme/make_readme_images.sh, which fills in @FIX@ and @SHOTS@.
windows 1
free-space hidden
window-size 1240 800
activate
app-icon docs/brand/logo-variants/variant-4-isometric.png
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
# The view options popover
go @FIX@/home/Documents
view grid
wait 1
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
