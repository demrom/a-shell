#!/bin/sh
# Run in a disposable working directory after the user answers the Photos prompt.
# The Simulator host can drive the two public photos commands separately, then
# run these same cache assertions against its installed app's data container.
read_root() {
    root=$(cat "$1") || return 1
    test "$root" = \~/Documents/Photos || return 1
    root="$HOME/${root#\~/}"
}
photos_before() {
    read_root photos-root.txt || return 1
    test -f "$root/.photos-index.json" || return 1
    ls "$root" > photos-list.txt || return 1
    find "$root" -type f > photos-find.txt || return 1
    originals=0
    video_checked=0
    : > photos-before.txt
    for file in "$root"/*/*; do
        test -f "$file" || continue
        test ! -w "$file" || return 1
        if test "$originals" = 0; then
            rm -f photos-copy.original || return 1
            cp "$file" photos-copy.original || return 1
            test "$(cksum < "$file")" = "$(cksum < photos-copy.original)" || return 1
        fi
        case "$file" in
            *.MOV|*.mov|*.MP4|*.mp4)
                if test "$video_checked" = 0; then
                    ffprobe -v error -show_entries format=format_name "$file" > photos-video.txt 2> photos-video.err || return 1
                    video_checked=1
                fi
                ;;
        esac
        originals=$((originals + 1))
        stat -f '%N %i %m %z %Sp' "$file" >> photos-before.txt || return 1
    done
    test "$originals" != 0 || return 1
    test -s photos-before.txt || return 1
    printf 'PHOTOS_GREEN originals=%s video_checked=%s\n' "$originals" "$video_checked" > photos-success.txt
}
photos_after() {
    read_root photos-root.txt || return 1
    expected_root=$root
    read_root photos-root-repeat.txt || return 1
    test "$root" = "$expected_root" || return 1
    : > photos-after.txt
    for file in "$root"/*/*; do
        test -f "$file" || continue
        stat -f '%N %i %m %z %Sp' "$file" >> photos-after.txt || return 1
    done
    test -s photos-after.txt || return 1
    test "$(cksum < photos-before.txt)" = "$(cksum < photos-after.txt)" || return 1
    cat photos-success.txt
}
case ${1:-all} in
    before) photos_before ;;
    after) photos_after ;;
    all)
        photos > photos-root.txt 2> photos-first.err && photos_before &&
            photos > photos-root-repeat.txt 2> photos-repeat.err && photos_after
        ;;
    *) printf 'usage: sh photos.sh [before|after]\n' >&2; exit 2 ;;
esac
