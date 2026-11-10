#!/usr/bin/env bash
# Long names for the grid's labels: with spaces and without, CJK, Korean, emoji, combining accents, right to left, one
# over 200 characters and one that's just an extension, beside short names that must be left whole. GridNames/Folder
# holds a folder with a long name, for Recent's groups.
gn="$fix/home/GridNames"
mkdir -p "$gn" "$gn/Folder/A folder with a long name that needs more than two lines of the grid"
for name in \
    "notes.txt" \
    "Two words.md" \
    "Annual budget review.xlsx" \
    "Quarterly_Report_draft_v2_final_reviewed_by_finance.pdf" \
    "The quick brown fox jumps over the lazy dog and keeps on running far away.txt" \
    "Supercalifragilisticexpialidocious_without_any_spaces_at_all.docx" \
    "日本語のとても長いファイル名のテストです。これは表示の確認用.txt" \
    "Party planning 2026 — guests, food, music and more 🎉🎶.numbers" \
    "مستند طويل جدا للاختبار في عرض الشبكة مع اسم طويل.pdf" \
    "한국어 문서.txt" \
    "한국어 파일 이름이 아주 길어서 두 줄에 다 들어가지 않습니다.hwp" \
    ".pdf"; do
    echo x > "$gn/$name"
done
# Accents as combining marks, the way some disks store them: e and U+0301.
echo x > "$gn/$(printf 'Re\xcc\x81sume\xcc\x81 de\xcc\x81finitif avec beaucoup d\x27accents partout.pages')"
# 214 characters, still under the 255-byte limit for a name.
echo x > "$gn/$(printf 'A very long name with many words in it %.0s' 1 2 3 4 5)and then its end.md"
echo x > "$gn/Folder/Quarterly_Report_draft_v2_final_reviewed_by_finance_and_legal.pdf"
