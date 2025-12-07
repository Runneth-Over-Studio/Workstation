#!/usr/bin/env bash

if [[ $EUID -eq 0 ]]; then
  echo "ERROR: Please run this script as a regular user with sudo privileges, not as root." >&2
  echo "       Log in as your normal account and run:" >&2
  echo "         bash <(curl -fsSL https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main/scripts/mint-workstation-setup.sh)"
  exit 1
fi

# Base URL for raw files in this repo (adjust if branch/path changes)
REPO_RAW_BASE="https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main"

# Log everything to a file as well as stdout/stderr
exec > >(tee -a "$HOME/mint-workstation-setup.log") 2>&1

# Keep sudo alive
if ! command -v sudo >/dev/null 2>&1; then
  echo "[ERR ] 'sudo' is required but not installed. Aborting." >&2
  exit 1
fi
if ! sudo -v; then
  echo "[ERR ] Unable to obtain sudo privileges. Aborting." >&2
  exit 1
fi
( while true; do sleep 60; sudo -n true || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# Enable strict error handling and useful debugging output
set -euo pipefail
trap 'echo -e "\n[ERR ] Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Ensures the script runs unattended by preventing interactive prompts during APT or DEB installs
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
#    Linux Mint Workstation Setup
#
#  - Args: --skip-vulkan | --gpu=auto|nvidia|amd|intel|none | --help
#
#  1) System Updates
#  2) GPU Driver Helper (auto/NVIDIA/AMD/Intel)
#  3) SDKs (.NET/Vulkan)
#  4) App Installs
#     • LibreOffice - Office Suite
#     • Brave - Web Browser
#     • git - Version Control
#     • VS Code - Code Editor
#     • Joplin - Note-Taking
#     • BleachBit - System Cleaner
#     • Bitwarden - Password Vault
#     • Blender - 3D Modeling & Rendering
#     • FreeCAD - Parametric CAD
#     • Inkscape - Vector Graphics
#     • Krita - Raster Art
#     • Kdenlive - Video Editing
#     • OBS - Screen Recording
#     • Flameshot - Screenshot Utility
#  5) App Configurations
#  6) "Rice" - Themes & Aesthetics
# =============================================================================

# ----- helpers ---------------------------------------------------------------
log()   { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
exists(){ command -v "$1" >/dev/null 2>&1; }
is_pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [--skip-vulkan] [--gpu=auto|nvidia|amd|intel|none] [--help]

Options:
  --skip-vulkan           Skip installing Vulkan development packages
  --gpu=MODE              Install/ensure GPU driver stack:
                            auto   (default) detect GPU and choose
                            nvidia proprietary via ubuntu-drivers
                            amd    Mesa Vulkan stack
                            intel  Mesa Vulkan stack
                            none   do nothing
  --help                  Show this help
EOF
}

print_final_reboot_notice() {
  # Always print a reboot recommendation; mark as required if the system flags it
  local need_reboot="no"
  if [[ -f /var/run/reboot-required ]]; then
    need_reboot="yes"
  fi
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$need_reboot" == "yes" ]]; then
    warn "A reboot is REQUIRED to finish applying updates and drivers."
  else
    log "A reboot is RECOMMENDED to ensure all changes are applied cleanly."
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

load_resource() {
  local rel="$1"        # e.g. "scripts/resources/vscode-settings.json"
  local script_dir=""

  # Try to resolve the script directory (works when run from a cloned repo)
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || script_dir=""
  fi

  # 1) If the resource exists next to the script (cloned repo case), use it
  if [[ -n "$script_dir" && -f "$script_dir/$rel" ]]; then
    cat "$script_dir/$rel"
    return 0
  fi

  # 2) Otherwise, try GitHub (curl | bash case)
  if ! curl -fsSL "$REPO_RAW_BASE/$rel"; then
    warn "Failed to load resource '$rel' from local path or GitHub; continuing without it."
    # Emit empty content but do NOT fail the script
    return 0
  fi
}

# ----- arg parsing -----------------------------------------------------------
SKIP_VULKAN=false
GPU_MODE="auto"

for arg in "$@"; do
  case "$arg" in
    --skip-vulkan) SKIP_VULKAN=true ;;
    --gpu=*)       GPU_MODE="${arg#*=}" ;;
    --help|-h)     usage; exit 0 ;;
    *)             warn "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

# =============================================================================
#  1) SYSTEM UPDATE
# =============================================================================
system_update() {
  log "Updating APT index and upgrading the system..."

  sudo apt-get update -y
  sudo apt-get -o Dpkg::Options::="--force-confnew" dist-upgrade -y
  sudo apt-get autoremove -y

  log "Installing common prerequisites..."
  sudo apt-get install -y     curl wget apt-transport-https ca-certificates gnupg lsb-release     software-properties-common python3-minimal jq unzip
}

final_updates() {
  log "==== FINALIZE: Refreshing all packages before completion ===="
  # Make sure everything we installed is on the latest revs
  sudo apt-get update -y
  sudo apt-get -o Dpkg::Options::="--force-confnew" dist-upgrade -y
  # Fix any partially configured packages (just in case)
  sudo apt-get -f install -y || true
  sudo apt-get autoremove -y

  # Update Flatpak apps (LibreOffice, Blender, etc.)
  if command -v flatpak >/dev/null 2>&1; then
    log "Updating Flatpak apps…"
    sudo flatpak update -y || true
  fi
}

# =============================================================================
#  2) GPU DRIVER HELPER
#      - auto: detect vendor; NVIDIA => proprietary driver, AMD/Intel => Mesa
#      - nvidia: force ubuntu-drivers autoinstall
#      - amd/intel: ensure Mesa Vulkan stack
#      - none: do nothing
# =============================================================================
install_gpu_drivers() {
  local mode="$GPU_MODE"

  if [[ "$mode" == "none" ]]; then
    log "GPU driver helper skipped (--gpu=none)."
    return 0
  fi

  # Auto-detect if requested
  if [[ "$mode" == "auto" ]]; then
    local pci
    pci="$(LC_ALL=C lspci -nnk | grep -iE 'VGA|3D|Display' || true)"
    if echo "$pci" | grep -qi nvidia; then
      mode="nvidia"
    elif echo "$pci" | grep -qi amd\|ati; then
      mode="amd"
    elif echo "$pci" | grep -qi intel; then
      mode="intel"
    else
      warn "Could not determine GPU vendor; defaulting to Mesa stack."
      mode="amd"
    fi
    log "Auto-detected GPU mode: $mode"
  fi

  case "$mode" in
    nvidia)
      log "Installing NVIDIA proprietary driver via ubuntu-drivers..."
      sudo apt-get install -y ubuntu-drivers-common
      sudo ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall did not complete successfully."
      log "NVIDIA driver install attempted. A reboot is usually required."
      # drop a hint file the user can check later
      touch "$HOME/.reboot-recommended-nvidia" || true
      ;;
    amd|intel)
      log "Ensuring Mesa Vulkan stack (works for AMD & Intel)..."
      sudo apt-get install -y mesa-vulkan-drivers || true
      # Helpful VA-API codec drivers (best-effort; may vary by base release)
      sudo apt-get install -y intel-media-va-driver-non-free || true
      log "Mesa Vulkan stack ensured."
      ;;
    *)
      warn "Unknown GPU mode '$mode'; skipping GPU driver helper."
      ;;
  esac
}

# =============================================================================
#  3) SDKs
# =============================================================================
install_sdks() {
  install_dotnet_sdk
  install_vulkan_sdk
}

install_dotnet_sdk() {
  log "Installing .NET SDK (current LTS) using dotnet-install.sh..."

  DOTNET_INSTALL_SCRIPT=$(mktemp)
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$DOTNET_INSTALL_SCRIPT"
  chmod +x "$DOTNET_INSTALL_SCRIPT"

  sudo mkdir -p /usr/share/dotnet
  sudo bash "$DOTNET_INSTALL_SCRIPT" --channel LTS --install-dir /usr/share/dotnet
  [[ -e /usr/bin/dotnet ]] || sudo ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet
  rm -f "$DOTNET_INSTALL_SCRIPT"

  if command -v dotnet >/dev/null 2>&1; then
    log "Installed .NET SDK (LTS) version: $(dotnet --version)"
  else
    error ".NET installation failed."; exit 1
  fi
}

install_vulkan_sdk() {
  if [[ "$SKIP_VULKAN" == true ]]; then
    log "Skipping Vulkan packages (--skip-vulkan)."
    return 0
  fi

  log "Installing Vulkan SDK (via distro packages)..."

  sudo apt-get install -y     libvulkan1 vulkan-tools     libvulkan-dev vulkan-validationlayers     glslang-tools spirv-tools glslc libshaderc-dev     mesa-vulkan-drivers

  # Optional X/Wayland dev headers, helpful for building sample apps with windows
  sudo apt-get install -y     libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxinerama-dev     libwayland-dev wayland-protocols libxkbcommon-dev || true

  if command -v vulkaninfo >/dev/null 2>&1; then
    log "vulkaninfo (first lines):"
    vulkaninfo | head -n 10 || true
  else
    warn "vulkaninfo not found; ensure 'vulkan-tools' installed and drivers support Vulkan."
  fi

  log "Vulkan (APT packages) install done."
}

# =============================================================================
#  4) APP INSTALLS
# =============================================================================
install_apps() {
  libreoffice_flatpak
  install_git
  install_vscode
  install_joplin
  install_bleachbit
  uninstall_firefox
  install_brave_browser
  install_flatpaks
}

libreoffice_flatpak() {
  log "Installing LibreOffice from Flathub (removing distro)..."

  sudo apt-get remove -y --purge libreoffice* libreoffice-core* || true
  sudo apt-get autoremove -y || true

  sudo apt-get install -y flatpak
  if ! flatpak remote-list | grep -qi flathub; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
  if ! command -v flatpak >/dev/null 2>&1; then
    warn "Flatpak installed; if 'flatpak' command is not found, open a new shell or re-login."
  fi

  sudo flatpak install -y flathub org.libreoffice.LibreOffice
}

install_git() {
  log "Installing Git..."

  sudo apt-get install -y git

  if command -v git >/dev/null 2>&1; then
    log "Git version: $(git --version)"
  else
    error "Git installation failed."
  fi

  log "Ensuring ~/source directory exists..."
  mkdir -p "$HOME/source"
}

install_vscode() {
  log "Installing VS Code (via Microsoft APT repo)..."

  if command -v flatpak >/dev/null 2>&1 && flatpak list --app | grep -qi 'com.visualstudio.code'; then
    sudo flatpak uninstall -y com.visualstudio.code || true
  fi
  if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -qi '^code '; then
    sudo snap remove code || true
  fi
  if is_pkg_installed code; then
    log "VS Code (deb) already installed."; return 0
  fi
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc     | gpg --dearmor | sudo tee /usr/share/keyrings/ms_vscode.gpg >/dev/null
  echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main"     | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y code
}

install_joplin() {
  log "Installing Joplin via official install/update script (no Flatpak)..."

  # Prevent AppImage launch issues on some bases
  sudo apt-get install -y libfuse2 || true

  JOPLIN_SCRIPT=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/laurent22/joplin/dev/Joplin_install_and_update.sh" -o "$JOPLIN_SCRIPT"
  chmod +x "$JOPLIN_SCRIPT"
  bash "$JOPLIN_SCRIPT"
  rm -f "$JOPLIN_SCRIPT"
}

install_bleachbit() {
  log "Installing BleachBit..."

  sudo apt-get install -y bleachbit
}

install_flatpaks() {
  log "Installing creative tools and utilities via Flatpak..."

  sudo flatpak install -y flathub com.bitwarden.desktop
  sudo flatpak install -y flathub org.blender.Blender
  sudo flatpak install -y flathub org.freecadweb.FreeCAD || sudo flatpak install -y flathub org.freecad.FreeCAD
  sudo flatpak install -y flathub org.inkscape.Inkscape
  sudo flatpak install -y flathub org.kde.krita
  sudo flatpak install -y flathub org.kde.kdenlive
  sudo flatpak install -y flathub com.obsproject.Studio
  sudo flatpak install -y flathub org.flameshot.Flameshot
}

uninstall_firefox() {
  log "Removing Firefox and related packages (if present)..."

  # Purge common Firefox package names; ignore failures if not present
  sudo apt-get remove -y --purge firefox firefox-esr firefox* || true
  sudo apt-get autoremove -y || true

  # Remove user profile (optional; keep backup if exists)
  if [[ -d "$HOME/.mozilla" ]]; then
    TS="$(date +%Y%m%d-%H%M%S)"
    mv "$HOME/.mozilla" "$HOME/.mozilla.bak.$TS"
    log "Backed up existing Firefox profile to ~/.mozilla.bak.$TS"
  fi
}

install_brave_browser() {
  log "Installing Brave Browser..."
  # Uses sudo internally when needed; our sudo keepalive covers it.
  curl -fsS https://dl.brave.com/install.sh | sh

  # Sanity check
  if [[ ! -f /usr/share/applications/brave-browser.desktop ]]; then
    warn "Brave desktop file not found; installation may have failed."
  fi
}

# =============================================================================
#  5) APP CONFIGURATIONS
# =============================================================================
configure_apps() {
  configure_libreoffice
  configure_bleachbit
  configure_browsers
  configure_vscode
  configure_favorites
}

configure_libreoffice() {
  log "Configuring LibreOffice..."

  cat > "$HOME/.configure-libreoffice-ui.sh" <<'EOF'
#!/usr/bin/env bash
echo "Open LibreOffice → View → User Interface → Tabbed to apply."
EOF
  chmod +x "$HOME/.configure-libreoffice-ui.sh"
}

configure_bleachbit() {
  log "Configuring BleachBit..."

  local CFG_DIR="$HOME/.config/bleachbit"
  local CFG_FILE="$CFG_DIR/bleachbit.ini"
  local TS; TS="$(date +%Y%m%d-%H%M%S)"

  mkdir -p "$CFG_DIR"

  # Backup an existing config if present
  if [[ -f "$CFG_FILE" ]]; then
    cp "$CFG_FILE" "$CFG_FILE.bak.$TS"
  fi

  # Minimal safe preset from resource file
  load_resource "scripts/resources/bleachbit-defaults.ini" > "$CFG_FILE"

  log "BleachBit defaults written to $CFG_FILE (backup kept if one existed)."
}

configure_browsers() {
  set_brave_default_browser
  pin_brave_to_panel_cinnamon
}

set_brave_default_browser() {
  log "Setting Brave as the default web browser..."
  # Best-effort default via xdg-settings (works for most desktop environments)
  if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser brave-browser.desktop || true
  fi

  # Cinnamon-specific (sets MIME handlers via gsettings if available)
  if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.cinnamon.desktop.default-applications.browser exec 'brave-browser' 2>/dev/null || true
    gsettings set org.cinnamon.desktop.default-applications.browser name 'Brave Browser' 2>/dev/null || true
  fi
}

pin_brave_to_panel_cinnamon() {
  # Only for Cinnamon sessions; best-effort edit of panel-launchers applet config.
  if [[ "$XDG_CURRENT_DESKTOP" != *"Cinnamon"* && "$XDG_CURRENT_DESKTOP" != *"X-Cinnamon"* ]]; then
    warn "Cinnamon not detected; skipping Brave pin to panel."
    add_brave_to_favorites
    return 0
  fi

  local BRAVE_DESKTOP="brave-browser.desktop"
  local NEMO_DESKTOP="nemo.desktop"
  # Common terminal desktop id on Mint Cinnamon; fallback if different
  local TERM_DESKTOP="org.gnome.Terminal.desktop"
  [[ -f "/usr/share/applications/org.xfce.terminal.desktop" ]] && TERM_DESKTOP="org.xfce.terminal.desktop"
  [[ -f "/usr/share/applications/gnome-terminal.desktop" ]] && TERM_DESKTOP="gnome-terminal.desktop"

  # Cinnamon stores applet settings here:
  local CFG_BASE="$HOME/.cinnamon/configs/panel-launchers@cinnamon.org"
  if [[ ! -d "$CFG_BASE" ]]; then
    warn "No panel-launchers config directory found; adding Brave to favorites instead."
    add_brave_to_favorites
    return 0
  fi

  # Pick the first panel-launchers instance (most systems have one)
  local INST_DIR
  INST_DIR="$(find "$CFG_BASE" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
  if [[ -z "$INST_DIR" ]]; then
    warn "panel-launchers instance not found; adding Brave to favorites instead."
    add_brave_to_favorites
    return 0
  fi

  # The settings file is commonly settings.json (older: xlet-settings.json)
  local CFG_FILE="$INST_DIR/settings.json"
  [[ -f "$CFG_FILE" ]] || CFG_FILE="$INST_DIR/xlet-settings.json"

  if [[ ! -f "$CFG_FILE" ]]; then
    warn "panel-launchers settings file not found; adding Brave to favorites instead."
    add_brave_to_favorites
    return 0
  fi

  log "Enabling Brave in Cinnamon panel launchers…"
  # This Python helper tries multiple known formats:
  # - { "launchers": { "value": [ ... ] } }
  # - { "launcherList": { "value": [ ... ] } }
  # - { "launchersList": [ ... ] }
  # - plain top-level list (rare, but we handle it)
  python3 - "$CFG_FILE" "$BRAVE_DESKTOP" "$NEMO_DESKTOP" "$TERM_DESKTOP" <<'PY'
import json, os, sys

cfg_path, brave, nemo, term = sys.argv[1:5]

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}

launcher_list = None
container_key = None
uses_value_wrapper = False

# Try a few likely keys in Cinnamon configs
for key in ("launchers", "launcherList", "launchersList"):
    if isinstance(data, dict) and key in data:
        val = data[key]
        # Newer-style: { "launchers": { "value": [ ... ] } }
        if isinstance(val, dict) and "value" in val and isinstance(val["value"], list):
            launcher_list = val["value"]
            container_key = key
            uses_value_wrapper = True
            break
        # Simpler style: { "launchersList": [ ... ] }
        if isinstance(val, list):
            launcher_list = val
            container_key = key
            break

# Fallback: whole file is a list
if launcher_list is None:
    if isinstance(data, list):
        launcher_list = data
        container_key = None
    else:
        launcher_list = []

# Normalize to strings only and drop any Firefox entries
launcher_list = [
    x for x in launcher_list
    if isinstance(x, str) and "firefox" not in x.lower()
]

def ensure(item, after=None):
    if item in launcher_list:
        return
    if after and after in launcher_list:
        idx = launcher_list.index(after) + 1
        launcher_list.insert(idx, item)
    else:
        launcher_list.append(item)

# Prefer to put Brave after Nemo if possible
ensure(brave, after=nemo)

# If Nemo isn't there but terminal is, try to put Brave before terminal
if nemo not in launcher_list and term in launcher_list and brave not in launcher_list:
    idx = launcher_list.index(term)
    launcher_list.insert(idx, brave)

# If still not added for whatever reason, append
if brave not in launcher_list:
    launcher_list.append(brave)

# Write back in the same structural shape we found
if container_key is None:
    out = launcher_list
else:
    if uses_value_wrapper:
        if not isinstance(data.get(container_key), dict):
            data[container_key] = {}
        data[container_key]["value"] = launcher_list
    else:
        data[container_key] = launcher_list
    out = data

tmp = cfg_path + ".tmp"
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(out, f, indent=2)
os.replace(tmp, cfg_path)
PY

  # Soft-reload panel to apply (no logout)
  pkill -HUP -f "cinnamon$" 2>/dev/null || true
}

add_brave_to_favorites() {
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not available; cannot add Brave to favorites."
    return 0
  fi

  local CURRENT NEW
  CURRENT="$(gsettings get org.cinnamon favorite-apps 2>/dev/null || echo "[]")"

  NEW="$(python3 - "$CURRENT" <<'PY'
import ast, sys

cur = sys.argv[1]
try:
    fav = ast.literal_eval(cur)
except Exception:
    fav = []

if not isinstance(fav, list):
    fav = []

if "brave-browser.desktop" not in fav:
    fav.append("brave-browser.desktop")

print(str(fav).replace('"', "'"))
PY
)"

  gsettings set org.cinnamon favorite-apps "$NEW" 2>/dev/null || true
}

configure_vscode() {
  install_vscode_extensions
  apply_vscode_settings
}

install_vscode_extensions() {
  if ! exists code; then
    warn "VS Code not detected; skipping extension installs."; return 0
  fi

  log "Installing VS Code extensions for .NET and web development..."

  # Headless warm-up (non-fatal) to ensure 'code' CLI is ready
  timeout 10s code --version >/dev/null 2>&1 || true

  code --install-extension formulahendry.auto-close-tag           || true
  code --install-extension AvaloniaTeam.vscode-avalonia           || true
  code --install-extension ms-dotnettools.csharp                  || true
  code --install-extension ms-dotnettools.csdevkit                || true
  code --install-extension JosKreativ.vscode-csharp-extensions    || true
  code --install-extension JeremyCaron.csharp-organize-usings     || true
  code --install-extension dbaeumer.vscode-eslint                 || true
  code --install-extension ecmel.vscode-html-css                  || true
  code --install-extension xabikos.JavaScriptSnippets             || true
  code --install-extension PKief.material-icon-theme              || true
  code --install-extension christian-kohler.path-intellisense     || true

  log "VS Code extension installation complete."
}

apply_vscode_settings() {
  log "Applying VS Code settings and keybindings..."

  USER_DIR="$HOME/.config/Code/User"
  mkdir -p "$USER_DIR"

  local NEW_SETTINGS NEW_KEYS
  NEW_SETTINGS="$(load_resource "scripts/resources/vscode-settings.json")"
  NEW_KEYS="$(load_resource "scripts/resources/vscode-keybindings.json")"

  local SETTINGS="$USER_DIR/settings.json"
  local KEYS="$USER_DIR/keybindings.json"
  local TS
  TS=$(date +%Y%m%d-%H%M%S)

  # Backups
  [[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$TS"
  [[ -f "$KEYS" ]] && cp "$KEYS" "$KEYS.bak.$TS"

  if command -v jq >/dev/null 2>&1; then
    # Merge settings: existing * new (new wins on conflicts)
    if [[ -f "$SETTINGS" ]]; then
      jq -s '.[0] * .[1]' "$SETTINGS" <(printf '%s\n' "$NEW_SETTINGS") > "$SETTINGS.tmp" \
        && mv "$SETTINGS.tmp" "$SETTINGS"
    else
      printf '%s\n' "$NEW_SETTINGS" > "$SETTINGS"
    fi

    # Merge keybindings: concatenate and de-duplicate by key+command
    if [[ -f "$KEYS" ]]; then
      jq -s '[.[0][], .[1][]] | unique_by(.key + ":" + .command)' \
        "$KEYS" <(printf '%s\n' "$NEW_KEYS") > "$KEYS.tmp" \
        && mv "$KEYS.tmp" "$KEYS"
    else
      printf '%s\n' "$NEW_KEYS" > "$KEYS"
    fi
  else
    warn "jq not found; writing VS Code settings/keybindings as-is."
    printf '%s\n' "$NEW_SETTINGS" > "$SETTINGS"
    printf '%s\n' "$NEW_KEYS" > "$KEYS"
  fi

  log "VS Code configuration updated in $USER_DIR."
}

configure_favorites() {
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not available; cannot configure favorites."
    return 0
  fi

  log "Updating Cinnamon favorites (remove Files/Terminal, add Joplin then VS Code)…"

  local CURRENT NEW
  CURRENT="$(gsettings get org.cinnamon favorite-apps 2>/dev/null || echo "[]")"

  NEW="$(python3 - "$CURRENT" <<'PY'
import ast, sys

cur = sys.argv[1]

try:
    fav = ast.literal_eval(cur)
except Exception:
    fav = []

if not isinstance(fav, list):
    fav = []

# Entries we want to remove from favorites (already pinned to panel or to be reinserted)
to_remove = {
    "nemo.desktop",
    "org.gnome.Terminal.desktop",
    "gnome-terminal.desktop",
    "org.xfce.terminal.desktop",
    "xterm.desktop",
    # We'll reinsert Joplin + VS Code in a specific order
    "code.desktop",
    "appimagekit-joplin.desktop",
    "joplin.desktop",
}

fav = [item for item in fav if item not in to_remove]

def ensure(lst, item):
    if item not in lst:
        lst.append(item)

# 1) Joplin first
joplin_candidates = [
    "appimagekit-joplin.desktop",  # common from official Joplin script
    "joplin.desktop",
]

# Prefer an existing candidate if any, otherwise use the first
existing_joplin = next((c for c in joplin_candidates if c in fav), None)
joplin_id = existing_joplin if existing_joplin is not None else joplin_candidates[0]
ensure(fav, joplin_id)

# 2) VS Code second
ensure(fav, "code.desktop")

print(str(fav).replace('"', "'"))
PY
)"

  gsettings set org.cinnamon favorite-apps "$NEW" 2>/dev/null || true
}

# =============================================================================
#  6) "RICE" – THEMES & AESTHETICS
# =============================================================================
cook_rice() {
  set_wallpaper
  set_icon_theme
  set_fonts
  set_themes
  tweak_time_and_date_prefs
  tweak_screensaver_prefs
  tweak_file_management_prefs
  tweak_behavior_prefs
  install_neofetch
  install_cinnamon_extensions
}

set_wallpaper() {
  log "Setting wallpaper..."

  local WALL_DIR="$HOME/Pictures/Wallpapers"
  local WALL_URL="https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main/content/wallpapers/Gnome-Desktop-851-Right-4K-No-Logo.jpg"
  local WALL_FILE="$WALL_DIR/Gnome-Desktop-851-Right-4K-No-Logo.jpg"

  mkdir -p "$WALL_DIR"

  if ! curl -fsSL "$WALL_URL" -o "$WALL_FILE"; then
    warn "Failed to download wallpaper; skipping wallpaper configuration."
    return 0
  fi

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping wallpaper configuration."
    return 0
  fi

  local URI="file://$WALL_FILE"
  local applied=false

  # 1) Try Cinnamon background schema
  if gsettings set org.cinnamon.desktop.background picture-uri "$URI" 2>/dev/null; then
    gsettings set org.cinnamon.desktop.background picture-options 'stretched' 2>/dev/null || \
      warn "Failed to set Cinnamon picture-options to stretched."
    log " • Wallpaper set via org.cinnamon.desktop.background (stretched)."
    applied=true
  fi

  # 2) If that didn’t work, try GNOME background schema
  if [[ "$applied" = false ]]; then
    if gsettings set org.gnome.desktop.background picture-uri "$URI" 2>/dev/null; then
      gsettings set org.gnome.desktop.background picture-options 'stretched' 2>/dev/null || \
        warn "Failed to set GNOME picture-options to stretched."
      log " • Wallpaper set via org.gnome.desktop.background (stretched)."
      applied=true
    fi
  fi

  # 3) Only warn if *both* attempts failed
  if [[ "$applied" = false ]]; then
    warn "Unable to apply wallpaper using Cinnamon or GNOME background schemas; wallpaper may not be updated."
  fi
}

set_icon_theme() {
  log "Installing and applying Papirus icon theme..."

  sudo add-apt-repository -y ppa:papirus/papirus || true
  sudo apt-get update -y
  sudo apt-get install -y papirus-icon-theme
  if exists gsettings; then
    gsettings set org.cinnamon.desktop.interface icon-theme 'Papirus-Dark' || true
  fi
}

set_fonts() {
  log "Installing and configuring fonts (Inter + JetBrains Mono)…"

  # Install from Ubuntu/Mint repos – much more robust than scraping Google Fonts
  if ! sudo apt-get install -y fonts-inter fonts-jetbrains-mono; then
    warn "Could not install fonts-inter and fonts-jetbrains-mono via apt; font configuration may not apply correctly."
  fi

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping font configuration."
    return 0
  fi

  # Global UI font
  gsettings set org.cinnamon.desktop.interface font-name 'Inter 10' 2>/dev/null || \
    warn "Could not set interface font to Inter."

  # Window title font (this one is valid on your system)
  if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.wm.preferences'; then
    if gsettings list-keys org.cinnamon.desktop.wm.preferences | grep -qx 'titlebar-font'; then
      gsettings set org.cinnamon.desktop.wm.preferences titlebar-font 'Inter Medium 10' 2>/dev/null || \
        warn "Could not set window title font to Inter Medium."
    fi
  fi
}

set_themes() {
  log "Applying themes…"

  set_terminal_theme
  set_system_theme
  set_text_editor_theme
}

set_terminal_theme() {
  log "Installing Catppuccin Frappé theme for GNOME Terminal…"

  # Make sure the essentials are present
  if ! command -v python3 >/dev/null 2>&1; then
    log " • Installing python3…"
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y python3 >/dev/null 2>&1 || {
      warn "Failed to install python3; cannot run Catppuccin installer."
      return 0
    }
  fi

  if ! command -v dconf >/dev/null 2>&1; then
    log " • Installing dconf-cli…"
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y dconf-cli >/dev/null 2>&1 || {
      warn "Failed to install dconf-cli; cannot configure GNOME Terminal profiles."
      return 0
    }
  fi

  # 1) Run the Catppuccin GNOME Terminal installer (Frappé & friends)
  log " • Running Catppuccin GNOME Terminal installer (v1.0.0)…"
  if ! curl -fsSL "https://raw.githubusercontent.com/catppuccin/gnome-terminal/v1.0.0/install.py" | python3 - >/dev/null 2>&1; then
    warn "Catppuccin gnome-terminal install.py failed; profiles may not have been created."
    return 0
  fi

  # 2) Set Catppuccin Frappé as the default GNOME Terminal profile
  #    UUID taken from install.py (frappe entry).
  local FRAPPE_UUID="71a9971e-e829-43a9-9b2f-4565c855d664"
  local PROFILE_PATH="/org/gnome/terminal/legacy/profiles:/:${FRAPPE_UUID}/"

  # Check that the profile actually exists and looks like Catppuccin Frappé
  local VISIBLE_NAME
  VISIBLE_NAME="$(dconf read "${PROFILE_PATH}visible-name" 2>/dev/null | tr -d "'")"

  if [[ -z "$VISIBLE_NAME" ]]; then
    warn "Catppuccin Frappé profile not found in dconf; leaving default profile unchanged."
    return 0
  fi

  log " • Found GNOME Terminal profile ${FRAPPE_UUID} (${VISIBLE_NAME}). Setting as default…"

  dconf write /org/gnome/terminal/legacy/profiles:/default "'${FRAPPE_UUID}'" 2>/dev/null || {
    warn "Failed to set Catppuccin Frappé as default GNOME Terminal profile."
    return 0
  }

  log " • Catppuccin Frappé is now the default GNOME Terminal profile."
}

set_system_theme() {
  log "Installing and applying Catppuccin Frappé (Blue) GTK theme…"

  # Make sure python3 is available
  if ! command -v python3 >/dev/null 2>&1; then
    log " • python3 not found; installing…"
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y python3 >/dev/null 2>&1 || {
      warn "Failed to install python3; cannot run Catppuccin GTK installer."
      return 0
    }
  fi

  # Make sure curl is available
  if ! command -v curl >/dev/null 2>&1; then
    log " • curl not found; installing…"
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y curl >/dev/null 2>&1 || {
      warn "Failed to install curl; cannot download Catppuccin GTK installer."
      return 0
    }
  fi

  # Use a temporary directory so we don't clutter the home folder
  local TMPDIR
  TMPDIR="$(mktemp -d)"
  if [[ ! -d "$TMPDIR" ]]; then
    warn "Could not create temporary directory for Catppuccin GTK installer."
    return 0
  fi

  log " • Downloading Catppuccin GTK install.py (v1.0.3)…"
  if ! curl -fsSL "https://raw.githubusercontent.com/catppuccin/gtk/v1.0.3/install.py" -o "$TMPDIR/install.py"; then
    warn "Failed to download Catppuccin GTK installer."
    rm -rf "$TMPDIR"
    return 0
  fi

  (
    cd "$TMPDIR" || exit 0
    log " • Running: python3 install.py frappe blue"
    if ! python3 install.py frappe blue >/dev/null 2>&1; then
      warn "Catppuccin GTK install.py failed; theme may not have been installed."
    else
      log " • Catppuccin GTK theme installation completed."
    fi
  )

  # We know from manual test that the theme name shown in the UI is:
  local THEME_NAME="catppuccin-frappe-blue-standard+default"

  # Try to find a matching theme directory (allowing suffixes like -xhdpi)
  local THEME_DIR=""
  if [[ -d "$HOME/.themes" ]]; then
    THEME_DIR="$(find "$HOME/.themes" -maxdepth 1 -type d -name "${THEME_NAME}*" | head -n1 || true)"
  fi
  if [[ -z "$THEME_DIR" && -d "/usr/share/themes" ]]; then
    THEME_DIR="$(find "/usr/share/themes" -maxdepth 1 -type d -name "${THEME_NAME}*" | head -n1 || true)"
  fi

  if [[ -n "$THEME_DIR" ]]; then
    log " • Found Catppuccin theme directory: $(basename "$THEME_DIR")"
  else
    warn "Catppuccin theme directory starting with '$THEME_NAME' not found in ~/.themes or /usr/share/themes, but attempting to apply it anyway."
  fi

  # Apply to Applications (GTK) and Desktop (Cinnamon) using the *theme name* as seen in the UI
  if ! gsettings set org.cinnamon.desktop.interface gtk-theme "$THEME_NAME" 2>/dev/null; then
    warn "Could not set GTK (Applications) theme to $THEME_NAME."
  else
    log " • Applications theme set to $THEME_NAME."
  fi

  if ! gsettings set org.cinnamon.theme name "$THEME_NAME" 2>/dev/null; then
    warn "Could not set Cinnamon (Desktop) theme to $THEME_NAME."
  else
    log " • Desktop theme set to $THEME_NAME."
  fi

  rm -rf "$TMPDIR"

  # Update Cinnamon’s preview thumbnails for the current theme
  update_catppuccin_theme_thumbnails
}

update_catppuccin_theme_thumbnails() {
  log "Updating Cinnamon theme preview thumbnails for Catppuccin…"

  local THEME_NAME="catppuccin-frappe-blue-standard+default"

  # Where Catppuccin likely lives
  local BASE1="$HOME/.local/share/themes/$THEME_NAME"
  local BASE2="$HOME/.themes/$THEME_NAME"
  local SRC_CIN SRC_GTK

  # Find cinnamon thumbnail.png
  if [[ -f "$BASE1/cinnamon/thumbnail.png" ]]; then
    SRC_CIN="$BASE1/cinnamon/thumbnail.png"
  elif [[ -f "$BASE2/cinnamon/thumbnail.png" ]]; then
    SRC_CIN="$BASE2/cinnamon/thumbnail.png"
  fi

  # Find gtk-3.0 thumbnail.png
  if [[ -f "$BASE1/gtk-3.0/thumbnail.png" ]]; then
    SRC_GTK="$BASE1/gtk-3.0/thumbnail.png"
  elif [[ -f "$BASE2/gtk-3.0/thumbnail.png" ]]; then
    SRC_GTK="$BASE2/gtk-3.0/thumbnail.png"
  fi

  # System thumbnail dirs used by cs_themes.py
  local DEST_CIN_DIR="/usr/share/cinnamon/thumbnails/cinnamon"
  local DEST_GTK_DIR="/usr/share/cinnamon/thumbnails/gtk-3.0"

  # Copy cinnamon thumbnail if we found one
  if [[ -n "$SRC_CIN" && -f "$SRC_CIN" ]]; then
    if [[ -d "$DEST_CIN_DIR" ]]; then
      log " • Copying Cinnamon theme thumbnail from $SRC_CIN → $DEST_CIN_DIR/thumbnail.png"
      sudo cp "$SRC_CIN" "$DEST_CIN_DIR/thumbnail.png" 2>/dev/null || \
        warn "Failed to copy Cinnamon thumbnail into $DEST_CIN_DIR."
    else
      warn "Cinnamon thumbnails directory $DEST_CIN_DIR not found; skipping Cinnamon preview."
    fi
  else
    warn "Catppuccin Cinnamon thumbnail.png not found under $BASE1 or $BASE2."
  fi

  # Copy GTK thumbnail if we found one
  if [[ -n "$SRC_GTK" && -f "$SRC_GTK" ]]; then
    if [[ -d "$DEST_GTK_DIR" ]]; then
      log " • Copying GTK theme thumbnail from $SRC_GTK → $DEST_GTK_DIR/thumbnail.png"
      sudo cp "$SRC_GTK" "$DEST_GTK_DIR/thumbnail.png" 2>/dev/null || \
        warn "Failed to copy GTK thumbnail into $DEST_GTK_DIR."
    else
      warn "GTK thumbnails directory $DEST_GTK_DIR not found; skipping GTK preview."
    fi
  else
    warn "Catppuccin GTK thumbnail.png not found under $BASE1 or $BASE2."
  fi
}

set_text_editor_theme() {
  log "Configuring Xed theme (Catppuccin Frappe)…"

  local XED_STYLE_DIR="$HOME/.local/share/xed/styles"
  local STYLE_URL="https://raw.githubusercontent.com/catppuccin/xed/refs/heads/main/src/frappe.xml"
  local STYLE_PATH="$XED_STYLE_DIR/frappe.xml"

  mkdir -p "$XED_STYLE_DIR"

  if ! curl -fsSL "$STYLE_URL" -o "$STYLE_PATH"; then
    warn "Failed to download Catppuccin Frappe theme for Xed; skipping."
    return 0
  fi

  # Try to set it as the active scheme if the schema exists
  if gsettings list-schemas | grep -qx 'org.x.editor.preferences.editor'; then
    local SCHEME_ID
    SCHEME_ID=$(grep -o 'id=\"[^\"]*\"' "$STYLE_PATH" | head -n1 | sed 's/id=\"//;s/\"//') || true

    if [[ -n "$SCHEME_ID" ]]; then
      gsettings set org.x.editor.preferences.editor scheme "$SCHEME_ID" 2>/dev/null || \
        warn "Downloaded Xed theme but could not set scheme '$SCHEME_ID'."
    else
      warn "Could not infer Xed scheme id from frappe.xml; theme installed but not activated."
    fi
  else
    warn "Xed gsettings schema not found; Catppuccin theme installed but not auto-activated."
  fi
}

tweak_time_and_date_prefs() {
  log "Tweaking time and date preferences..."

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping time/date tweaks."
    return 0
  fi

  # Prefer Cinnamon; fall back to GNOME if needed
  if gsettings set org.cinnamon.desktop.interface clock-use-24h false 2>/dev/null; then
    log " • Clock set to 12-hour format (org.cinnamon.desktop.interface)"
  elif gsettings set org.gnome.desktop.interface clock-use-24h false 2>/dev/null; then
    log " • Clock set to 12-hour format (org.gnome.desktop.interface)"
  else
    warn " • Could not set clock-use-24h to false on Cinnamon or GNOME; leaving clock format unchanged."
  fi
}

tweak_screensaver_prefs() {
  log "Customizing lock screen..."

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping lock screen tweaks."
    return 0
  fi

  # Try to write; if the first key fails, assume this schema isn't usable and bail.
  if ! gsettings set org.cinnamon.desktop.screensaver allow-media-control false 2>/dev/null; then
    warn "Screensaver schema not writable; skipping lock screen tweaks."
    return 0
  else
    log " • Disabled media controls on lock screen."
  fi

  gsettings set org.cinnamon.desktop.screensaver show-album-art false 2>/dev/null || \
    warn "Could not disable album art on lock screen."
  gsettings set org.cinnamon.desktop.screensaver floating-widgets false 2>/dev/null || \
    warn "Could not disable floating widgets on lock screen."

  # Refresh screensaver
  if command -v cinnamon-screensaver-command >/dev/null 2>&1; then
    cinnamon-screensaver-command -r 2>/dev/null || true
  else
    pkill -HUP -f cinnamon-screensaver 2>/dev/null || true
  fi
}

tweak_file_management_prefs() {
  log "Tweaking Nemo file management preferences..."

  # 1) Default view → List View
  #    Try a real write; if this fails, just skip all Nemo tweaks.
  if ! gsettings set org.nemo.preferences default-folder-viewer 'list-view' 2>/dev/null; then
    warn "Nemo preferences schema not available or not writable; skipping file management tweaks."
    return 0
  else
    log " • Nemo default view → list-view"
  fi

  # 2) Executable text files → View when opened
  if gsettings list-keys org.nemo.preferences | grep -qx 'executable-text-activation'; then
    gsettings set org.nemo.preferences executable-text-activation 'display' 2>/dev/null || \
      warn "Could not set executable-text-activation to 'display'."
  fi

  # 3) Ensure Reload button in toolbar
  if gsettings list-keys org.nemo.preferences | grep -qx 'show-reload-icon-toolbar'; then
    gsettings set org.nemo.preferences show-reload-icon-toolbar true 2>/dev/null || \
      warn "Could not enable Nemo reload toolbar button."
  fi

  # TODO: Rename on double-click.

  # Soft-reload Nemo so changes apply
  if command -v nemo >/dev/null 2>&1; then
    pkill -HUP nemo 2>/dev/null || true
  fi
}

tweak_behavior_prefs() {
  log "Tweaking behavior prefs..."

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not available; skipping behavior tweaks."
    return 0
  fi

  #
  # 1) Center new windows (Cinnamon / muffin)
  #
  if gsettings set org.cinnamon.muffin placement-mode 'center' 2>/dev/null; then
    log " • Window placement → center (org.cinnamon.muffin::placement-mode)"
  else
    # Fallback if placement-mode isn't supported
    if gsettings set org.cinnamon.muffin center-new-windows true 2>/dev/null; then
      log " • Window placement → center (org.cinnamon.muffin::center-new-windows)"
    else
      warn " • Could not center new windows via org.cinnamon.muffin."
    fi
  fi

  #
  # 2) Remove Corner Bar applet from panel
  #
  local CURRENT_APPLETS NEW_APPLETS
  CURRENT_APPLETS="$(gsettings get org.cinnamon enabled-applets 2>/dev/null || echo '[]')"

  NEW_APPLETS="$(python3 - "$CURRENT_APPLETS" <<'PY'
import ast, sys

cur = sys.argv[1]
try:
    applets = ast.literal_eval(cur)
except Exception:
    applets = []

if not isinstance(applets, list):
    applets = []

# Corner Bar applet UUID is cornerbar@cinnamon.org
applets = [a for a in applets if 'cornerbar@cinnamon.org' not in str(a)]

print(str(applets).replace('"', "'"))
PY
)"

  if gsettings set org.cinnamon enabled-applets "$NEW_APPLETS" 2>/dev/null; then
    log " • Corner Bar applet removed from panel."
  else
    warn " • Failed to update enabled-applets for Corner Bar removal."
  fi

  #
  # 3) Hot corner: top-left → Show all workspaces (expo)
  #
  local HCURRENT HNEW
  HCURRENT="$(gsettings get org.cinnamon hotcorner-layout 2>/dev/null || echo "['desktop:false:0','desktop:false:0','desktop:false:0','desktop:false:0']")"

  HNEW="$(python3 - "$HCURRENT" <<'PY'
import ast, sys

cur = sys.argv[1]
try:
    corners = ast.literal_eval(cur)
except Exception:
    corners = ['desktop:false:0'] * 4

if not isinstance(corners, list):
    corners = ['desktop:false:0'] * 4

# Ensure exactly 4 entries (TL, TR, BL, BR)
if len(corners) < 4:
    corners += ['desktop:false:0'] * (4 - len(corners))
elif len(corners) > 4:
    corners = corners[:4]

# Top-left: expo:true:0 → Show all workspaces
corners[0] = 'expo:true:0'

print(str(corners).replace('"', "'"))
PY
)"

  if gsettings set org.cinnamon hotcorner-layout "$HNEW" 2>/dev/null; then
    log " • Hot corner (top-left) → Show all workspaces (expo:true:0)."
  else
    warn " • Failed to update hotcorner-layout."
  fi

  #
  # 4) Alt-Tab switcher style → Timeline (3D)
  #
  if gsettings set org.cinnamon alttab-switcher-style 'timeline' 2>/dev/null; then
    log " • Alt-Tab switcher style → Timeline (3D)."
  else
    warn " • Failed to set Alt-Tab switcher style to 'timeline'."
  fi

  # TODO: Open menu on hover.
}

install_neofetch() {
  log "Installing Neofetch..."

  # Neofetch is a nice-to-have; don't let failures kill the whole script.
  if ! sudo apt-get install -y neofetch; then
    warn "Neofetch installation failed (network or repo issue?). Skipping Neofetch setup."
    return 0
  fi

  log "Enabling Neofetch auto-launch for interactive shells..."
  local MARKER="neofetch auto-launch (added by mint-workstation-setup)"
  local NEOFETCH_SNIPPET
  NEOFETCH_SNIPPET="$(cat <<'EOF'
# >>> neofetch auto-launch (added by mint-workstation-setup) >>>
if command -v neofetch >/dev/null 2>&1; then
  case "$-" in
    *i*) neofetch ;;
  esac
fi
# <<< neofetch auto-launch <<<
EOF
)"

  # Append once to ~/.bashrc and ~/.zshrc (create file if missing)
  for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$RC" ]]; then
      if ! grep -q "$MARKER" "$RC"; then
        printf "\n%s\n" "$NEOFETCH_SNIPPET" >> "$RC"
        log "Added Neofetch auto-launch to $(basename "$RC")"
      else
        log "Neofetch auto-launch already present in $(basename "$RC")"
      fi
    else
      printf "%s\n" "$NEOFETCH_SNIPPET" > "$RC"
      log "Created $(basename "$RC") with Neofetch auto-launch"
    fi
  done
}

install_cinnamon_extensions() {
  # Only for Cinnamon sessions
  if [[ "$XDG_CURRENT_DESKTOP" != *"Cinnamon"* && "$XDG_CURRENT_DESKTOP" != *"X-Cinnamon"* ]]; then
    warn "Cinnamon desktop not detected; skipping Cinnamon extensions/actions."
    return 0
  fi

  log "Installing Cinnamon extensions and actions..."
  install_blur_cinnamon_extension
  install_gtile_extension
  install_vscode_launcher_action
}

install_blur_cinnamon_extension() {
  log "Installing Blur Cinnamon extension..."

  local EXT_DIR="$HOME/.local/share/cinnamon/extensions"
  local TMPDIR
  TMPDIR="$(mktemp -d)"

  mkdir -p "$EXT_DIR"

  if [[ -d "$EXT_DIR/BlurCinnamon@klangman" ]]; then
    log "Blur Cinnamon already present at $EXT_DIR/BlurCinnamon@klangman"
    rm -rf "$TMPDIR"
    return 0
  fi

  if ! git clone --depth=1 https://github.com/klangman/BlurCinnamon.git \
    "$TMPDIR/BlurCinnamon" >/dev/null 2>&1; then
    warn "Failed to clone BlurCinnamon repo; skipping Blur Cinnamon install."
    rm -rf "$TMPDIR"
    return 0
  fi

  if [[ -d "$TMPDIR/BlurCinnamon/BlurCinnamon@klangman" ]]; then
    cp -a "$TMPDIR/BlurCinnamon/BlurCinnamon@klangman" "$EXT_DIR/"
    log "Blur Cinnamon installed into $EXT_DIR/BlurCinnamon@klangman"
  else
    warn "BlurCinnamon@klangman directory not found in cloned repo; skipping."
  fi

  rm -rf "$TMPDIR"
}

install_gtile_extension() {
  log "Installing gTile extension..."

  local EXT_DIR="$HOME/.local/share/cinnamon/extensions"
  local TMPDIR
  TMPDIR="$(mktemp -d)"

  mkdir -p "$EXT_DIR"

  if [[ -d "$EXT_DIR/gTile@shuairan" ]]; then
    log "gTile already present at $EXT_DIR/gTile@shuairan"
    rm -rf "$TMPDIR"
    return 0
  fi

  if ! git clone --depth=1 https://github.com/shuairan/gTile.git \
    "$TMPDIR/gTile" >/dev/null 2>&1; then
    warn "Failed to clone gTile repo; skipping gTile install."
    rm -rf "$TMPDIR"
    return 0
  fi

  # As per upstream instructions: mv gTile -> ~/.local/share/cinnamon/extensions/gTile@shuairan
  if [[ -d "$TMPDIR/gTile" ]]; then
    mv "$TMPDIR/gTile" "$EXT_DIR/gTile@shuairan"
    log "gTile installed into $EXT_DIR/gTile@shuairan"
  else
    warn "gTile directory not found after clone; skipping."
  fi

  rm -rf "$TMPDIR"
}

install_vscode_launcher_action() {
  log "Installing VSCode Launcher Nemo action..."

  local ACTIONS_DIR="$HOME/.local/share/nemo/actions"
  local TMPDIR
  TMPDIR="$(mktemp -d)"

  mkdir -p "$ACTIONS_DIR"

  # If an action file already exists, don't reinstall
  if ls "$ACTIONS_DIR"/vscode-launcher*.nemo_action >/dev/null 2>&1; then
    log "VSCode Launcher Nemo action already present in $ACTIONS_DIR"
    rm -rf "$TMPDIR"
    return 0
  fi

  local ZIP_URL="https://cinnamon-spices.linuxmint.com/files/actions/vscode-launcher%40vajdao.zip"
  local ZIP_FILE="$TMPDIR/vscode-launcher.zip"

  if ! curl -fsSL "$ZIP_URL" -o "$ZIP_FILE"; then
    warn "Failed to download VSCode Launcher action zip; skipping."
    rm -rf "$TMPDIR"
    return 0
  fi

  mkdir -p "$TMPDIR/unpacked"
  if ! unzip -qq "$ZIP_FILE" -d "$TMPDIR/unpacked"; then
    warn "Failed to unzip VSCode Launcher action; skipping."
    rm -rf "$TMPDIR"
    return 0
  fi

  # Copy any .nemo_action files into the actions directory
  local found=false
  while IFS= read -r -d '' f; do
    cp "$f" "$ACTIONS_DIR/"
    found=true
  done < <(find "$TMPDIR/unpacked" -maxdepth 2 -type f -name '*.nemo_action' -print0)

  if [[ "$found" == true ]]; then
    log "Installed VSCode Launcher Nemo action into $ACTIONS_DIR"
  else
    warn "No .nemo_action files found in VSCode Launcher zip; nothing installed."
  fi

  rm -rf "$TMPDIR"
}

# =============================================================================
#  MAIN RUNNER
# =============================================================================
main() {
  log "==== 1) SYSTEM UPDATE ===="
  system_update

  log "==== 2) GPU DRIVER HELPER (mode: $GPU_MODE) ===="
  install_gpu_drivers

  log "==== 3) SDKs ===="
  install_sdks

  log "==== 4) APP INSTALLS ===="
  install_apps

  log "==== 5) APP CONFIGURATIONS ===="
  configure_apps

  log "==== 6) RICE (THEMES & AESTHETICS) ===="
  if ! cook_rice; then
    warn "Rice step encountered an error; continuing to final updates."
  fi

  final_updates
  log "✅ Setup complete!"
  print_final_reboot_notice
}
main "$@"
