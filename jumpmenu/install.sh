#!/usr/bin/env bash
# Install jumpmenu for the current user on the jumphost.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${BIN_DIR:-$HOME/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/jumpmenu"

install -d -m 755 "$BIN_DIR"
install -m 755 jumpmenu "$BIN_DIR/jumpmenu"
install -d -m 700 "$CONF_DIR"
for f in jumpmenu.conf hosts.conf; do
    if [[ -e $CONF_DIR/$f ]]; then
        echo "keeping existing $CONF_DIR/$f"
    else
        install -m 600 "$f.example" "$CONF_DIR/$f"
        echo "created $CONF_DIR/$f  <- edit this"
    fi
done

missing=()
for c in ssh curl jq; do command -v "$c" >/dev/null || missing+=("$c"); done
if (( ${#missing[@]} )); then
    echo
    echo "missing: ${missing[*]}  (Debian/Ubuntu: sudo apt install ${missing[*]/ssh/openssh-client})"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo; echo "note: $BIN_DIR is not in PATH; use the full path $BIN_DIR/jumpmenu";; esac
echo
echo "done. test with:  $BIN_DIR/jumpmenu"
