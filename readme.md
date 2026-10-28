<p align="left">
  <img src="content/logo.png" width="175" alt="Workstation Logo">
</p>

# Workstation
![Linux Mint](https://img.shields.io/badge/Linux%20Mint-23%2B-success?logo=linuxmint&logoColor=white)
![Shell Script](https://img.shields.io/badge/Bash-Automation-blue?logo=gnubash)
![License](https://img.shields.io/badge/License-MIT-green)

Runneth Over Studio's default Linux Mint Cinnamon workstation configurations.

There are two post-install scripts:

| Script | For | What it does |
| --- | --- | --- |
| `mint-general-setup.sh` | Every user, after a fresh Linux Mint Cinnamon install | Updates, fonts, everyday apps, desktop themes & preferences |
| `mint-developer-setup.sh` | Developer machines | Developer tools |

On a developer machine, run the general script first and then the developer script. The developer script doesn't depend on the general one, though, so either can be run on its own.

## General Setup
Performs system updates, turns on Mint's automatic updates, installs document-compatibility and desktop fonts, applies themes & desktop preferences, and installs & configures:

- **Brave** - Web Browser (replaces Firefox and becomes the default browser)
- **LibreOffice** - Office Suite (Flatpak, replaces the distro build; tabbed UI)
- **Joplin** - Note-Taking
- **MDHero** - Markdown Editor (default app for `.md` files)
- **BleachBit** - System Cleaner
- **Bitwarden** - Password Vault
- **Flameshot** - Screenshot Utility
- **FreeCAD** - Parametric CAD
- **Inkscape** - Vector Graphics
- **Krita** - Raster Art
- **Kdenlive** - Video Editing
- **OBS** - Screen Recording

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main/scripts/mint-general-setup.sh)
```

## Developer Setup
Performs system updates, turns on Mint's automatic updates, and installs & configures:

- **git** - Version Control (creates `~/source`)
- **.NET SDK** - Latest LTS SDK from APT (only that one; older and odd-numbered SDKs are removed)
- **MonoGame** - Project templates (`dotnet new mgdesktopgl`, etc.)
- **VS Code** - Code Editor, with extensions, settings, and keybindings
- **Blender** - 3D Modeling & Rendering

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main/scripts/mint-developer-setup.sh)
```

> 💡 These commands fetch a script from GitHub and run it with `bash`. The script downloads the rest of this repository (shared library and resource files) to a temp folder and runs from there. You'll be prompted for your sudo password once.

## Running After Cloning
```bash
git clone https://github.com/Runneth-Over-Studio/Workstation.git
cd Workstation
bash scripts/mint-general-setup.sh
bash scripts/mint-developer-setup.sh
```

When run from a clone, the scripts use the clone's resource files, so local edits take effect.

### Testing a branch
Set `WORKSTATION_REF` so the one-liner downloads that branch's resources instead of `main`:

```bash
WORKSTATION_REF=my-branch bash <(curl -fsSL https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/my-branch/scripts/mint-general-setup.sh)
```

## Keeping Machines Current
Things are installed from official channels so they keep themselves updated without re-running these scripts:

| Source | Covers | Updated by |
| --- | --- | --- |
| Mint / Ubuntu APT archive | System, fonts, git, .NET SDK, BleachBit, Papirus | Mint Update Manager (automatic updates turned on) |
| Vendor APT repos | Brave, VS Code | Mint Update Manager |
| Flathub | LibreOffice, Bitwarden, Flameshot, FreeCAD, Inkscape, Krita, Kdenlive, OBS, Blender | Mint Update Manager |
| NuGet | MonoGame templates | Re-run the script |
| GitHub release `.deb` | MDHero | Re-run the script |
| Vendor installer | Joplin | Re-run the script (or Joplin's own update prompt) |

Re-running either script is safe. Installed software is skipped or updated. Settings files that are merged (VS Code) or replaced (BleachBit) get a timestamped `.bak` copy when they change. Each run writes a log to `~/mint-general-setup.log` or `~/mint-developer-setup.log`. If any step fails, the script carries on, lists the failed steps at the end, and exits non-zero.

## Pinned & Archived Upstreams
A few theming pieces come from upstream projects that are archived or have no versioned packages. They're pinned to a fixed version so a re-run always gets the same result. These are the replacements we plan to investigate:

| Component | Status | Pinned to | Possible replacement |
| --- | --- | --- | --- |
| [Catppuccin GTK](https://github.com/catppuccin/gtk) | Archived upstream (2024) | `v1.0.3` | [Fausto-Korpsvart/Catppuccin-GTK-Theme](https://github.com/Fausto-Korpsvart/Catppuccin-GTK-Theme), or another maintained Cinnamon theme |
| [Neofetch](https://github.com/dylanaraps/neofetch) | Archived upstream (2024) | `7.1.0` (distro package if available) | [Fastfetch](https://github.com/fastfetch-cli/fastfetch), packaged in recent Ubuntu bases |
| [Catppuccin Xed](https://github.com/catppuccin/xed) | Active, no releases | commit `88807d1` | Keep; bump the pin when needed |
| [Catppuccin GNOME Terminal](https://github.com/catppuccin/gnome-terminal) | Active | `v1.0.0` | Keep; bump the pin when needed |

The pins are defined near the top of `scripts/mint-general-setup.sh`.

## Repository Layout
```
scripts/
  mint-general-setup.sh      # every user
  mint-developer-setup.sh    # developer machines
  lib/common.sh              # shared bash helpers (logging, apt, flatpak, step runner)
  lib/helpers.py             # JSON/GVariant/LibreOffice config editors
  resources/                 # app lists and config files the scripts apply
content/                     # logo and wallpaper
```

To add or remove a Flatpak app or VS Code extension, edit the matching list in `scripts/resources/`.

## Verification
```bash
dotnet --info
code --version
dotnet new list monogame
flatpak list --app
```
