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

# Screendumps bracket the visual changes: the stock session first, then
# after each piece that repaints something. Each one is a counted check:
# a failed or empty capture fails the suite, and the stock shot waits
# for the shell to actually paint (the target goes active well before).
wait_session_painted 120 || exit 1
check "screendump: stock session" \
    screendump "$ART/screens/topaz-home-0-stock.png"

# Ship the working tree into the VM: tar over ssh tests these exact
# bytes — no git and no network needed in the guest.
tar -C "$REPO_DIR" --exclude=.git --exclude=tests -cf - . |
    tssh 'rm -rf ~/topaz-home && mkdir ~/topaz-home && tar -xf - -C ~/topaz-home' ||
    { echo "failed to copy the checkout into the VM" >&2; exit 1; }

check "just apply installs the layer" \
    tssh 'cd ~/topaz-home && just apply'
check "just check reports no drift" \
    tssh 'cd ~/topaz-home && just check'

# The session in the VM is COSMIC-on-niri with a live panel, so the
# watchdog must come back green; a red verdict here means the shell never
# came up and every later visual check would be looking at a bare niri.
check "shell watchdog sees the COSMIC shell" \
    tssh 'cd ~/topaz-home && just shell-watchdog enable >/dev/null &&
        systemctl --user start topaz-shell-watchdog.service &&
        systemctl --user is-active topaz-shell-watchdog.service'

# Same live panel, seen through the other watchdog: its layer surfaces
# must be known to niri (exit 0), and the timer must be schedulable.
check "panel watchdog sees the panel's layer surfaces" \
    tssh 'cd ~/topaz-home && just panel-watchdog enable >/dev/null &&
        TOPAZ_PANEL_WATCHDOG_GRACE=0 systemctl --user start topaz-panel-watchdog.service &&
        systemctl --user is-active topaz-panel-watchdog.timer'

# Every shipped unit must parse and resolve once the layer is applied —
# a rename or a typo'd Exec path shows up here, not at next login.
# shellcheck disable=SC2016  # $(...) expands in the guest shell
check "every unit file loads" \
    is_empty tssh 'cd ~/topaz-home/units && for u in *; do
        state=$(systemctl --user show -p LoadState --value "$u")
        [ "$state" = loaded ] || echo "$u: $state"
    done'

check "wallpaper sync writes cosmic config" \
    tssh 'systemctl --user start topaz-bluefin-wallpaper.service &&
        test -s ~/.config/cosmic/com.system76.CosmicBackground/v1/all'
# Live, cosmic-bg repaints on its 5-minute rotation tick; the suite
# can't wait that out, so respawn it for a deterministic screendump.
tssh 'pkill -x cosmic-bg || true'

# The dash-to-panel layout: applied files must match the repo's copies
# (the recipe restarts cosmic-panel itself when anything changed) — the
# screendump after the settle shows the merged bar over the Bluefin
# artwork, minus the applets the image doesn't ship.
check "just panel applies the layout" \
    tssh 'cd ~/topaz-home && just panel &&
        diff -r desktop/cosmic/com.system76.CosmicPanel.Panel \
            ~/.config/cosmic/com.system76.CosmicPanel.Panel'
sleep 5
check "screendump: merged panel" \
    screendump "$ART/screens/topaz-home-1-panel.png"

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

check "screendump: final with window" \
    screendump "$ART/screens/topaz-home-2-final.png"

suite_verdict topaz-home
