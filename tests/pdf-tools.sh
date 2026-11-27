#!/bin/sh
# Run with sh in a-Shell, in a directory where mktemp can create a workspace.
set -eu
work=$(mktemp -d "${TMPDIR:-/tmp}/pdf-tools.XXXXXX")
trap 'cd /; rm -r "$work"' EXIT
cd "$work"

# Generate an ASCII PDF with a real cross-reference table (no fixture tools needed).
LC_ALL=C awk '
function line(s) { print s; offset += length(s) + 1 }
function object(n, s) {
    offsets[n] = offset
    line(n " 0 obj")
    line(s)
    line("endobj")
}
function stream(n, contents) {
    object(n, "<< /Length " length(contents) " >>\nstream\n" contents "endstream")
}
BEGIN {
    line("%PDF-1.4")
    object(1, "<< /Type /Catalog /Pages 2 0 R >>")
    object(2, "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
    font = "/Resources << /Font << /F1 5 0 R >> >>"
    object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] " font " /Contents 6 0 R >>")
    object(4, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 120 80] /Rotate 90 " font " /Contents 7 0 R >>")
    object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")
    stream(6, "BT /F1 12 Tf 10 70 Td (First page) Tj 110 0 Td (Right) Tj ET\n")
    stream(7, "BT /F1 12 Tf 10 50 Td (Second page) Tj ET\n")
    xref = offset
    print "xref\n0 8\n0000000000 65535 f "
    for (i = 1; i <= 7; i++) printf "%010d 00000 n \n", offsets[i]
    print "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n" xref "\n%%EOF"
}' > 'sample file.pdf'

pdftotext -f 2 -l 2 'sample file.pdf' - > actual.txt
printf 'Second page\n\n\f' > expected.txt
diff expected.txt actual.txt
pdftotext -f 2 'sample file.pdf'
diff expected.txt 'sample file.txt'
pdftotext -layout -l 1 'sample file.pdf' layout.txt
grep -E '^First page {3,}Right$' layout.txt

pdftoppm -r 72 -png 'sample file.pdf' image
check_png() {
    # PNG signature and big-endian IHDR width/height.
    header=$(xxd -p -l 24 "$1")
    test "$header" = "$(printf '89504e470d0a1a0a0000000d49484452%08x%08x' "$2" "$3")"
}
check_png image-1.png 200 100
check_png image-2.png 80 120
pdftoppm -f 2 -l 2 -r 72 -png 'sample file.pdf' selected
check_png selected-2.png 80 120
test ! -f selected-1.png
pdftoppm -f 2 -r 144 -png 'sample file.pdf' scaled
check_png scaled-2.png 160 240

pdfinfo 'sample file.pdf' > info.txt
grep -Ex 'Pages:[[:space:]]+2' info.txt
if pdftotext -bogus 'sample file.pdf' - > rejected.txt 2> error.txt; then
    echo 'pdftotext unexpectedly accepted -bogus' >&2
    exit 1
fi
grep -F -e '-bogus' error.txt
test ! -s rejected.txt
printf 'PDF tools regression passed\n'
