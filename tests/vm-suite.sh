#!/usr/bin/env bash
# Suite: apply topaz-home inside the topaz-os test VM and verify the
# layer actually works in a live COSMIC-on-niri session — units load,
# and the pieces that can run in a bare VM leave the state they promise.
#
# Rides the topaz-os VM harness (see topaz-os/tests/README.md):
#     bash <topaz-os>/tests/run.sh all "$PWD/tests/vm-suite.sh"
# The harness hands down TESTS_DIR; a standalone invocation can point
# TOPAZ_OS_TESTS at a topaz-os checkout's tests/ directory instead.
#
# Out of scope by design: components needing credentials or containers
# the VM does not have (dropbox, tailscale-tray, kdeconnect's distrobox)
# — their units still get the load check, just no start.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TESTS_DIR:-${TOPAZ_OS_TESTS:-$HOME/git/topaz-os/tests}}"
# shellcheck disable=SC1090,SC1091
source "$TESTS_DIR/lib.sh" || exit 2

echo "waiting for ssh..."
wait_ssh 420 || exit 1
echo "waiting for the user session..."
wait_user_graphical 180 || exit 1

# Ship the working tree into the VM: tar over ssh tests these exact
# bytes — no git and no network needed in the guest.
tar -C "$REPO_DIR" --exclude=.git --exclude=tests -cf - . |
    tssh 'rm -rf ~/topaz-home && mkdir ~/topaz-home && tar -xf - -C ~/topaz-home' ||
    { echo "failed to copy the checkout into the VM" >&2; exit 1; }

check "just apply installs the layer" \
    tssh 'cd ~/topaz-home && just apply'
check "just check reports no drift" \
    tssh 'cd ~/topaz-home && just check'

# Every shipped unit must parse and resolve once the layer is applied —
# a rename or a typo'd Exec path shows up here, not at next login.
# shellcheck disable=SC2016  # $(...) expands in the guest shell
check "every unit file loads" \
    is_empty tssh 'cd ~/topaz-home/units && for u in *; do
        state=$(systemctl --user show -p LoadState --value "$u")
        [ "$state" = loaded ] || echo "$u: $state"
    done'

# Behavioral smoke on the pieces a bare VM session can actually run.
# The snapshot skips an empty session by design ("just logged in" beats
# "closed everything"), so give it one window to record; the settle
# override skips its fresh-compositor grace period the same way.
# shellcheck disable=SC2016  # $(...) expands in the guest shell
check "session snapshot plans an open window" \
    tssh 'export NIRI_SOCKET=$(systemctl --user show-environment | sed -n "s/^NIRI_SOCKET=//p")
        niri msg action spawn -- cosmic-term >/dev/null || exit 1
        for _ in $(seq 20); do
            [ "$(niri msg -j windows | jq length)" -gt 0 ] && break
            sleep 1
        done
        TOPAZ_SESSION_SETTLE=0 "$HOME/.local/bin/topaz-session-snapshot" &&
        grep -q CosmicTerm "$HOME/.local/state/topaz/session.json"'
check "wallpaper sync writes cosmic config" \
    tssh 'systemctl --user start topaz-bluefin-wallpaper.service &&
        test -s ~/.config/cosmic/com.system76.CosmicBackground/v1/all'

shot="$(screendump "$ART/screens/topaz-home.png" || true)"
[[ -n "$shot" ]] && echo "screendump: $shot"

suite_verdict topaz-home
