# gix package launcher for a-Shell: sh gix.sh [gix args...]
# The sandbox answers EPERM (not ENOENT) for /etc/gitattributes and $HOME/.config/git/attributes,
# and gix only tolerates NotFound. Point gix at an existing directory and skip the system files.
# The variables are set for this command only and restored afterwards; nothing goes into a profile.
pkg="${GIX_WASM:-$HOME/Documents/herdr-pkg509/gix.wasm}"
mkdir -p "$HOME/Documents/.config"
old_xdg="$XDG_CONFIG_HOME"
export XDG_CONFIG_HOME="$HOME/Documents/.config" GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1
wasmtime "$pkg" "$@"
status=$?
if [ -n "$old_xdg" ]; then export XDG_CONFIG_HOME="$old_xdg"; else unset XDG_CONFIG_HOME; fi
unset GIT_ATTR_NOSYSTEM GIT_CONFIG_NOSYSTEM
exit $status
