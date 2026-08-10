# topaz-home

The userland companion to [topaz-os](https://github.com/davidar/topaz-os):
everything that belongs with the OS but has no reason to be baked into the
immutable image. The image carries what needs atomic updates, signatures, and
rollback — the boot path, the compositor, the package set. This repo carries
the layer above it — opt-in per-user services, desktop fixes, and installers —
where a change should be a `git pull`, not an image build and a reboot.

Nothing here runs automatically. Every component is enabled deliberately, per
user, by a `just` verb.

## Install

On topaz-os, `ujust topaz-home` clones this repo (it never applies it). Or by
hand:

```bash
git clone https://github.com/davidar/topaz-home && cd topaz-home
just apply     # symlink scripts into ~/.local, copy units, daemon-reload
just --list    # see the component verbs
```

`just apply` installs the plumbing but enables nothing. Scripts and `share/`
are symlinked into the checkout, so a `git pull` is instantly live; systemd
unit files are copied into `~/.config/systemd/user/` (a dangling symlinked
unit silently unloads — copies cannot). `just check` reports drift between
this checkout and what is installed, read-only, exit 1 on divergence.

## Components

- **`just nightshift enable`** — a daily user timer digests system events
  since the last run (failed units, journal errors, kernel warning
  signatures, OOM activity, deployment status, disk usage, and `topaz check`
  where present) and pipes it through a triage command you configure —
  an AI agent, a local model, or a plain script (`TRIAGE_CMD` in
  `~/.config/topaz/nightshift.conf`; see `share/nightshift.conf.example`).
  The digest carries memory: the previous morning's report, plus standing
  notes you keep in `~/.config/topaz/nightshift-notes.md` (known-benign
  signatures, expected transitional failures, watch items). Unconfigured, it
  saves raw digests. `just nightshift report` reads the latest (they live in
  `~/.local/state/topaz/reports/`).
- **`just wallpaper`** — keeps COSMIC's wallpaper on Bluefin's monthly
  artwork, flipping day/night variants at the midpoints of the GNOME
  timed-XML transitions (04:40 / 17:50) and rolling the month at 00:05.
  COSMIC has no timed-wallpaper support of its own; the script points
  cosmic-config at the image's own jxl files, so new art arrives with image
  updates. Skips gracefully on non-Bluefin hosts.
- **`just dropbox`** — Dropbox Flatpak with a working tray icon under
  COSMIC. Three hard-won fixes are encoded: the launcher unit is `oneshot`
  because `dropbox start` hands the daemon to the Flatpak session helper and
  exits (the daemon lives outside the unit's cgroup — restarts need
  `flatpak kill`); a helper syncs the sandbox-private tray icons into the
  user icon theme, without which COSMIC's panel renders a missing-image
  placeholder; and a path unit watches the Flatpak's deploy symlink and
  bounces the app on update — otherwise the old daemon keeps running against
  replaced files and its tray registration silently dies.
- **`just tailscale-tray`** — user unit running `tailscale systray` (ships
  with tailscale; native StatusNotifier).
- **`just qt-dark`** — Qt Flatpaks on the KDE runtime follow GNOME dark mode
  via Kvantum, with a `--nofilesystem=xdg-config/kdeglobals` negation so
  KDE-runtime apps cannot read a host kdeglobals that fights the theme.
- **`just electron-wayland`** — per-app `ELECTRON_OZONE_PLATFORM_HINT=auto`
  overrides. Electron apps default to XWayland, and image pastes into them
  cross the compositor's X11 selection bridge, which drops large transfers
  (Discord's "file cannot be empty"); Wayland-native avoids the bridge.
- **`just chrome-integration`** — Chrome Flatpak overrides for automation
  workflows: WebGPU via Vulkan, read-only visibility of Claude Code state.
- **`just claude-desktop`** — rootless installer/updater for the Debian-only
  Claude Desktop package, extracted into `~/.local` (no layering, no root
  beyond the chrome-sandbox setuid fixup it prompts for).
- **`just kitty`** — kitty via the official user-scoped installer, with
  desktop-file integration fixes.
- **`just applets`** — builds a pinned set of COSMIC panel applets (minimon —
  a fork carrying an NVML no-wake fix and combined GPU charts pending
  upstreaming — plus caffeine and observatory) from source in a disposable
  container on the image's Fedora release, installing into `~/.local`.
  Commit pins live in the recipe and move only by deliberate edit.
- **`just touchpad-dwt`** — opt out of libinput's disable-while-typing
  (keyboard-plus-touchpad play, e.g. FPS controls); `enabled=true` restores
  the default.

## Relationship to topaz-os

The image keeps boot-path configuration, hardware fixes, and the `topaz`
CLI with its provenance ledger; its only reference to this repo is the
`ujust topaz-home` bootstrap verb. This repo assumes a Bluefin-family base
for some components (wallpaper artwork, tailscale) and degrades gracefully
elsewhere; nothing hard-requires topaz-os itself.
