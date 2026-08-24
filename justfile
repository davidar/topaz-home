# topaz-home — the userland companion to topaz-os.
# `just apply` installs the layer; component verbs below enable the pieces.

default:
    @just --list

# Scripts and share/ are symlinked into the checkout (a git pull is instantly
# live); unit files are copied (unit edits need a daemon-reload anyway, and a
# dangling symlinked unit silently unloads — copies cannot).

# Install the layer: symlink scripts and share/, copy units, daemon-reload
apply:
    #!/usr/bin/bash
    set -euo pipefail
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.config/systemd/user"
    for f in "$PWD"/bin/*; do
        ln -sfn "$f" "$HOME/.local/bin/$(basename "$f")"
    done
    ln -sfn "$PWD/share" "$HOME/.local/share/topaz-home"
    cp -f "$PWD"/units/* "$HOME/.config/systemd/user/"
    systemctl --user daemon-reload
    echo "Applied. Enable components with the verbs below (just --list)."

# Drift report: read-only, exits 1 if the installed layer diverges from here
check:
    #!/usr/bin/bash
    set -uo pipefail
    drift=0
    for f in "$PWD"/bin/*; do
        link="$HOME/.local/bin/$(basename "$f")"
        target=$(readlink "$link" 2>/dev/null || echo missing)
        if [ "$target" != "$f" ]; then
            echo "STALE: $link -> $target"
            drift=1
        fi
    done
    share_target=$(readlink "$HOME/.local/share/topaz-home" 2>/dev/null || echo missing)
    if [ "$share_target" != "$PWD/share" ]; then
        echo "STALE: ~/.local/share/topaz-home -> $share_target"
        drift=1
    fi
    for f in "$PWD"/units/*; do
        if ! diff -u "$f" "$HOME/.config/systemd/user/$(basename "$f")"; then
            drift=1
        fi
    done
    if [ "$drift" -eq 0 ]; then
        echo "[ ok ] topaz-home applied and current"
    else
        echo "[FAIL] drift detected (see above; re-run: just apply)"
    fi
    exit "$drift"

# A daily timer digests system events into a morning report via your
# configured TRIAGE_CMD (see share/nightshift.conf.example).

# Night-shift triage: enable|disable|run|status|report
nightshift action="status": apply
    #!/usr/bin/bash
    set -euo pipefail
    case "{{ action }}" in
    enable)
        systemctl --user enable --now topaz-nightshift.timer
        echo "Night shift enabled (daily, ~05:00; 'just nightshift report' reads the latest)."
        conf="$HOME/.config/topaz/nightshift.conf"
        if [ ! -f "$conf" ]; then
            echo "No triage command configured yet — reports will be raw digests."
            echo "Copy ~/.local/share/topaz-home/nightshift.conf.example to $conf and edit."
        fi
        ;;
    disable)
        systemctl --user disable --now topaz-nightshift.timer
        ;;
    run)
        "$HOME/.local/bin/topaz-nightshift"
        ;;
    status)
        systemctl --user status topaz-nightshift.timer --no-pager || true
        ;;
    report)
        latest=$(ls -1 "${XDG_STATE_HOME:-$HOME/.local/state}/topaz/reports"/*.md \
            2>/dev/null | tail -1 || true)
        if [ -z "$latest" ]; then
            echo "No night-shift reports yet — enable with: just nightshift enable"
            exit 1
        fi
        echo "== $(basename "$latest") =="
        cat "$latest"
        ;;
    *)
        echo "usage: just nightshift enable|disable|run|status|report" >&2
        exit 1
        ;;
    esac

# Make Qt Flatpaks on the KDE runtime follow GNOME dark mode (Kvantum)
qt-dark:
    #!/usr/bin/bash
    set -euo pipefail
    branches=$(flatpak list --runtime --columns=application,branch 2>/dev/null \
        | awk '$1 == "org.kde.Platform" {print $2}' | sort -u)
    if [ -z "$branches" ]; then
        echo "No KDE runtimes installed; installing Kvantum for 6.9 as a default."
        branches="6.9"
    fi
    for branch in $branches; do
        # --system: with flathub configured as both a system and a user
        # remote, an unqualified install aborts on the ambiguity prompt
        flatpak install -y --system flathub "org.kde.KStyle.Kvantum//$branch" \
            || echo "No Kvantum build for runtime $branch (skipped)"
    done
    mkdir -p "$HOME/.config/Kvantum"
    printf '[General]\ntheme=KvGnomeDark\n' > "$HOME/.config/Kvantum/kvantum.kvconfig"
    flatpak override --user \
        --env=QT_STYLE_OVERRIDE=kvantum \
        --env=QT_QPA_PLATFORMTHEME=gtk3 \
        --env=GTK_THEME=Adwaita:dark \
        --filesystem=xdg-config/Kvantum:ro \
        --nofilesystem=xdg-config/kdeglobals
    echo "Done. Restart Qt Flatpak apps to pick up the dark theme."
    echo "Background: README.md (Qt dark theme) in the topaz-home repo."

# Tailscale tray icon in the panel (StatusNotifier; ships with tailscale)
tailscale-tray: apply
    systemctl --user enable --now tailscale-systray.service
    @echo "Tailscale tray enabled (unit: tailscale-systray.service)."

# COSMIC wallpaper follows Bluefin's monthly artwork with day/night flips
wallpaper: apply
    systemctl --user enable --now topaz-bluefin-wallpaper.timer
    systemctl --user start topaz-bluefin-wallpaper.service
    @echo "Wallpaper synced; flips at 04:40/17:50, month rollover at 00:05."

# Dropbox via Flatpak with a working tray icon under COSMIC
dropbox: apply
    #!/usr/bin/bash
    set -euo pipefail
    flatpak install -y flathub com.dropbox.Client
    systemctl --user enable --now topaz-dropbox.service
    systemctl --user enable --now topaz-dropbox-restart.path
    echo "Dropbox installed and started. Link the account via the app window."
    echo "If the tray icon shows as a broken image, restart the panel once:"
    echo "  pkill cosmic-panel   # cosmic-session respawns it"
    echo "Flatpak updates restart the daemon automatically (the stale binary"
    echo "would otherwise keep running with a dead tray registration)."
    echo "Manual restarts need 'flatpak kill com.dropbox.Client' first (the"
    echo "daemon lives in a Flatpak scope, outside the unit's cgroup)."

# Run Electron Flatpaks Wayland-native (grants the Wayland socket + ozone hint;
# note Discord stable ignores it — its bootstrap forces the platform post-argv)
electron-wayland apps="com.discordapp.Discord":
    #!/usr/bin/bash
    set -euo pipefail
    for app in {{ apps }}; do
        flatpak override --user --socket=wayland --env=ELECTRON_OZONE_PLATFORM_HINT=auto "$app"
        echo "$app: wayland socket + ELECTRON_OZONE_PLATFORM_HINT=auto (restart the app to apply)"
    done

# Chrome overrides for automation: WebGPU via Vulkan, read-only Claude Code state
chrome-integration:
    #!/usr/bin/bash
    set -euo pipefail
    flatpak override --user \
        --filesystem=/tmp \
        --filesystem=~/.claude:ro \
        --filesystem=~/.local/share/claude:ro \
        --env=CHROME_FLAGS="--enable-unsafe-webgpu --use-angle=vulkan --enable-features=Vulkan,VulkanFromANGLE" \
        com.google.Chrome
    echo "Chrome overrides applied (restart Chrome to pick them up)."

# Claude Desktop (Linux beta): rootless install/update into ~/.local
claude-desktop: apply
    "{{ home_directory() }}/.local/bin/topaz-claude-desktop-update"

# kitty terminal via the official installer (user-scoped, ~/.local/kitty.app)
kitty:
    #!/usr/bin/bash
    set -euo pipefail
    curl -fsSL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
    ln -sf "$HOME/.local/kitty.app/bin/kitty" "$HOME/.local/kitty.app/bin/kitten" \
        "$HOME/.local/bin/"
    cp "$HOME"/.local/kitty.app/share/applications/kitty*.desktop \
        "$HOME/.local/share/applications/"
    sed -i "s|Icon=kitty|Icon=$HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g; s|Exec=kitty|Exec=$HOME/.local/kitty.app/bin/kitty|g" \
        "$HOME"/.local/share/applications/kitty*.desktop
    echo "kitty installed to ~/.local/kitty.app (re-run to update)."

# Build the pinned COSMIC applets from source and install them to ~/.local
applets applet="all":
    #!/usr/bin/bash
    set -euo pipefail
    # Pinned commits, same discipline as the topaz-os compositor fork's REF
    # (its ledger 0015): updates arrive as deliberate bumps here, and a
    # re-run rebuilds. minimon is a fork (NVML no-wake fix + combined GPU
    # charts) until those changes land upstream.
    declare -A repo ref bin
    repo[minimon]="https://github.com/davidar/minimon-applet"
    ref[minimon]="155971bf22f13ebddf626ce14d1b970b20e63ed5"
    bin[minimon]="cosmic-ext-applet-minimon"
    repo[caffeine]="https://github.com/tropicbliss/cosmic-ext-applet-caffeine"
    ref[caffeine]="e427a1a903fd612a09477d0e90bd4aed4a494a08"
    bin[caffeine]="cosmic-ext-applet-caffeine"
    repo[observatory]="https://github.com/cosmic-utils/observatory"
    ref[observatory]="f62326dc4a00074e8c72f307ca9df4858f2b3ad9"
    bin[observatory]="observatory"
    sel="{{ applet }}"
    [ "$sel" = all ] && sel="minimon caffeine observatory"
    for a in $sel; do
        if [ -z "${repo[$a]:-}" ]; then
            echo "unknown applet: $a (minimon|caffeine|observatory|all)" >&2
            exit 1
        fi
        src="$HOME/.cache/topaz-applets/$a"
        [ -d "$src/.git" ] || git init -q "$src"
        git -C "$src" fetch -q --depth=1 "${repo[$a]}" "${ref[$a]}"
        git -C "$src" checkout -q FETCH_HEAD
        # Build in a disposable container on the image's Fedora release:
        # the binary links the container's glibc, which must not be newer
        # than the image's (the compositor-builder rule, topaz-os ledger
        # 0015) — bump the release together with the base image. target/
        # lives in the mounted checkout and the cargo registry in a named
        # volume, so only the first build is cold (libcosmic is heavy —
        # expect ~15 minutes per applet; later runs are incremental).
        podman run --rm -v "$src":/src:Z -w /src \
            -v topaz-applets-cargo:/root/.cargo \
            registry.fedoraproject.org/fedora:44 \
            bash -c 'dnf -y -q install gcc cargo rust just git-core \
                pkgconf-pkg-config libxkbcommon-devel wayland-devel \
                fontconfig-devel mesa-libgbm-devel libglvnd-devel \
                expat-devel && just build-release'
        # Each repo's own install target does the placement (they all
        # honor rootdir/prefix). Note: caffeine's upstream install target
        # resets the applet's own config directory.
        (cd "$src" && just rootdir='' prefix="$HOME/.local" install)
        # The panel's PATH may not include ~/.local/bin: applet desktop
        # files need absolute Exec paths (same fix as the kitty verb).
        desk=$(grep -rlE "^Exec=${bin[$a]}( |$)" \
            "$HOME/.local/share/applications" | head -1)
        if [ -n "$desk" ]; then
            sed -i "s|^Exec=${bin[$a]}|Exec=$HOME/.local/bin/${bin[$a]}|" "$desk"
        fi
        echo "$a installed at ${ref[$a]:0:7}"
    done
    echo "Restart the panel to load new applet binaries: pkill cosmic-panel"
    echo "(cosmic-session respawns it)"

# Keep the touchpad active while typing (libinput disables it by default)
touchpad-dwt enabled="false":
    #!/usr/bin/bash
    set -euo pipefail
    case "{{ enabled }}" in true | false) ;; *)
        echo "enabled must be 'true' or 'false'" >&2
        exit 1
        ;;
    esac
    cfg="$HOME/.config/cosmic/com.system76.CosmicComp/v1/input_touchpad"
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || printf '(\n    state: Enabled,\n)\n' > "$cfg"
    if grep -q 'disable_while_typing:' "$cfg"; then
        sed -i "s/disable_while_typing: Some([a-z]*)/disable_while_typing: Some({{ enabled }})/" "$cfg"
    else
        sed -i "0,/^(/s//(\n    disable_while_typing: Some({{ enabled }}),/" "$cfg"
    fi
    echo "disable-while-typing -> {{ enabled }} (cosmic-comp applies it live)"

# Reopen last session's windows on niri: enable|disable|snapshot|replay|status
session-restore action="status": apply
    #!/usr/bin/bash
    set -euo pipefail
    cfg="$HOME/.config/niri/config.kdl"
    inc='include optional=true "topaz-session.kdl"'
    plan="${XDG_STATE_HOME:-$HOME/.local/state}/topaz/session.json"
    show_plan() {
        jq -r '.windows | group_by([.output, .ws])[] | "\(.[0].output) workspace \(.[0].ws): " + (map(.entry + (if .floating then " (floating)" else "" end)) | join(" | "))' "$plan" 2>/dev/null \
            || echo "(no snapshot yet; not running under niri?)"
    }
    case "{{ action }}" in
    enable)
        mkdir -p "$(dirname "$cfg")"
        if ! grep -qxF "$inc" "$cfg" 2>/dev/null; then
            printf '\n// Reopen the previous session'"'"'s windows (topaz-home session-restore).\n%s\n' "$inc" >> "$cfg"
            echo "Appended to $cfg: $inc"
        fi
        systemctl --user enable --now topaz-session-snapshot.timer
        systemctl --user start topaz-session-snapshot.service || :
        echo "Session snapshots every 2 minutes; next niri login replays the last one."
        ;;
    disable)
        systemctl --user disable --now topaz-session-snapshot.timer
        rm -f "$HOME/.config/niri/topaz-session.kdl" "$plan"
        echo "Snapshots stopped; include line left in config (harmless: optional=true)."
        ;;
    snapshot)
        systemctl --user start topaz-session-snapshot.service
        show_plan
        ;;
    replay)
        "$HOME/.local/bin/topaz-session-restore"
        ;;
    status)
        systemctl --user list-timers topaz-session-snapshot.timer --no-pager
        grep -qxF "$inc" "$cfg" 2>/dev/null && echo "config.kdl includes the snapshot" || echo "config.kdl does NOT include the snapshot (run: just session-restore enable)"
        show_plan
        ;;
    *)
        echo "action must be enable|disable|snapshot|replay|status" >&2
        exit 1
        ;;
    esac

# KDE Connect from a distrobox: daemon, SMS app, and indicator at git
# speed. Image-hosted history: baked while no Flatpak channel existed,
# evicted 2026-08-14 (topaz-os ledger 0026) after the image's unmaintained
# sshfs stopped mounting. The firewall ports (1714-1764) stay open — the
# kdeconnect service definition and zone enablement ship with firewalld
# itself, not the kde-connect package. Pairing state lives in
# ~/.config/kdeconnect on the host and carries over unchanged.
# Phone storage mounts under ~/Phone via topaz-kdeconnect-mount (host-side
# rclone; the daemon's own sshfs mount is trapped in the container's mount
# namespace), wired to "Browse device" through an x-scheme-handler.

# Phone integration via distrobox: install|enable|disable|status|mount|unmount
kdeconnect action="install": apply
    #!/usr/bin/bash
    set -euo pipefail
    # Shadows the image's D-Bus activation (user services dir wins) so
    # anything asking the bus for org.kde.kdeconnect goes through the
    # container unit, never a leftover baked daemon. SystemdService=
    # routes activation through topaz-kdeconnectd.service so activation
    # and the unit cannot race each other with competing daemons.
    write_activation() {
        mkdir -p "$HOME/.local/share/dbus-1/services"
        printf '[D-BUS Service]\nName=org.kde.kdeconnect\nSystemdService=topaz-kdeconnectd.service\nExec=/usr/bin/distrobox-enter -n kdeconnect -- /usr/bin/kdeconnectd\n' \
            > "$HOME/.local/share/dbus-1/services/org.kde.kdeconnect.service"
    }
    case "{{ action }}" in
    install)
        if ! podman container exists kdeconnect; then
            distrobox create --yes --name kdeconnect \
                --image registry.fedoraproject.org/fedora-toolbox:44
        fi
        # cutecosmic-qt6/qt6ct/sonnet ride along: the apps are Qt, and the
        # COSMIC theming that used to live image-side now themes them from
        # inside the container (Qt picks the platformtheme plugin by the
        # XDG_CURRENT_DESKTOP the exported launcher passes through).
        # xdg-utils: "Browse device" hands its kdeconnect:// URL to
        # xdg-open inside the container, and fedora-toolbox ships
        # xdg-open without xdg-mime — the handler never resolves and the
        # URL dies in xdg-open's terminal-browser fallback list.
        distrobox enter -n kdeconnect -- sudo dnf install -y \
            kde-connect cutecosmic-qt6 qt6ct kf6-sonnet-hunspell xdg-utils
        # Absolute desktop-file paths: distrobox-export's name search does
        # not match reverse-DNS names. (No .settings entry exists — the
        # settings KCM opens from inside the app.)
        for app in org.kde.kdeconnect.app org.kde.kdeconnect.sms \
                   org.kde.kdeconnect.nonplasma; do
            distrobox enter -n kdeconnect -- distrobox-export \
                --app "/usr/share/applications/$app.desktop"
        done
        distrobox enter -n kdeconnect -- distrobox-export \
            --bin /usr/bin/kdeconnect-cli --export-path "$HOME/.local/bin"
        write_activation
        # "Browse device" opens a kdeconnect:// URL meant for KDE's KIO
        # worker; without a handler xdg-open falls through its browser
        # list and the URL ends up mangled in a web browser. Route it to
        # our own host-side mount (topaz-kdeconnect-mount) instead.
        printf '[Desktop Entry]\nType=Application\nName=KDE Connect device browser\nExec=%s/.local/bin/topaz-kdeconnect-mount open %%u\nMimeType=x-scheme-handler/kdeconnect;\nNoDisplay=true\n' \
            "$HOME" > "$HOME/.local/share/applications/topaz-kdeconnect-browse.desktop"
        xdg-mime default topaz-kdeconnect-browse.desktop x-scheme-handler/kdeconnect
        echo "Installed. Hand over from any baked daemon: just kdeconnect enable"
        ;;
    mount | unmount)
        exec "$HOME/.local/bin/topaz-kdeconnect-mount" "{{ action }}"
        ;;
    enable)
        pkill -x kdeconnectd 2>/dev/null || true
        write_activation
        systemctl --user enable --now topaz-kdeconnectd.service
        # The indicator autostarts per session; point the autostart entry
        # at the exported (container) copy — distrobox-export prefixes it
        # with the container name. The already-running host indicator keeps
        # working meanwhile — it is only a D-Bus client.
        mkdir -p "$HOME/.config/autostart"
        cp -f "$HOME/.local/share/applications/kdeconnect-org.kde.kdeconnect.nonplasma.desktop" \
            "$HOME/.config/autostart/org.kde.kdeconnect.nonplasma.desktop"
        echo "Daemon enabled (topaz-kdeconnectd.service); pairing state is ~/.config/kdeconnect."
        ;;
    disable)
        systemctl --user disable --now topaz-kdeconnectd.service
        # Without this, any D-Bus request for the name would restart the
        # unit regardless of its enabled state. On a pre-eviction image
        # the baked activation becomes visible again and may start the
        # baked daemon instead.
        rm -f "$HOME/.local/share/dbus-1/services/org.kde.kdeconnect.service"
        ;;
    status)
        systemctl --user status topaz-kdeconnectd.service --no-pager || true
        "$HOME/.local/bin/kdeconnect-cli" --list-devices 2>/dev/null || true
        "$HOME/.local/bin/topaz-kdeconnect-mount" status
        ;;
    *)
        echo "action must be install|enable|disable|status|mount|unmount" >&2
        exit 1
        ;;
    esac
