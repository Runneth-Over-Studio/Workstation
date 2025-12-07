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
    TS=$(date +%Y%m%d-%H%M%S)
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

# Normalize to strings only
launcher_list = [x for x in launcher_list if isinstance(x, str)]

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

  log "Updating Cinnamon favorites..."

  local CURRENT NEW
  CURRENT="$(gsettings get org.cinnamon favorite-apps 2>/dev/null || echo "[]")"

  NEW="$(python3 - "$CURRENT" <<'PY'
import ast, sys

cur = sys.argv[1]

# Parse current favorites list
try:
    fav = ast.literal_eval(cur)
except Exception:
    fav = []

if not isinstance(fav, list):
    fav = []

# Entries we want to remove from favorites (already pinned to panel)
to_remove = {
    "nemo.desktop",
    "org.gnome.Terminal.desktop",
    "gnome-terminal.desktop",
    "org.xfce.terminal.desktop",
    "xterm.desktop",
}

fav = [item for item in fav if item not in to_remove]

def ensure(lst, item):
    if item not in lst:
        lst.append(item)

# Ensure VS Code (Microsoft .deb uses code.desktop)
ensure(fav, "code.desktop")

# Joplin can have different .desktop IDs depending on how it's installed
joplin_candidates = [
    "appimagekit-joplin.desktop",  # common from official Joplin script
    "joplin.desktop",
]

# If none of the candidates are present, add the first candidate
if not any(c in fav for c in joplin_candidates):
    ensure(fav, joplin_candidates[0])

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
  log "Setting custom wallpaper..."

  local PICS_DIR="$HOME/Pictures"
  local WALL_DIR="$PICS_DIR/Wallpapers"
  local WALL_NAME="Gnome-Desktop-851-Right-4K-No-Logo.jpg"
  local WALL_PATH="$WALL_DIR/$WALL_NAME"
  local WALL_URL="https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/refs/heads/main/content/wallpapers/Gnome-Desktop-851-Right-4K-No-Logo.jpg"

  mkdir -p "$WALL_DIR"

  if [[ ! -f "$WALL_PATH" ]]; then
    if curl -fsSL "$WALL_URL" -o "$WALL_PATH"; then
      log "Downloaded wallpaper to $WALL_PATH"
    else
      warn "Failed to download wallpaper from $WALL_URL"
      return 0
    fi
  else
    log "Wallpaper already exists at $WALL_PATH"
  fi

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not available; cannot apply wallpaper settings."
    return 0
  fi

  if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.background'; then
    local URI="file://$WALL_PATH"
    gsettings set org.cinnamon.desktop.background picture-uri "$URI" 2>/dev/null || \
      warn "Could not set desktop background image."

    # Set Picture Aspect to 'stretched'
    gsettings set org.cinnamon.desktop.background picture-options 'stretched' 2>/dev/null || \
      warn "Could not set picture aspect to stretched."
  else
    warn "org.cinnamon.desktop.background schema not found; skipping wallpaper configuration."
  fi
}

set_mint_theme() {
  # gsettings is available in Cinnamon (and also used for Mint theming)
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping Mint theme configuration."
    return 0
  fi

  log "Applying Linux Mint theme..."

  # Apply core theme components
  gsettings set org.cinnamon.theme name 'Mint-Y-Dark' 2>/dev/null || true
  gsettings set org.cinnamon.desktop.interface gtk-theme 'Mint-Y-Dark' 2>/dev/null || true
  gsettings set org.cinnamon.desktop.wm.preferences theme 'Mint-Y-Dark' 2>/dev/null || true
  gsettings set org.cinnamon.desktop.interface cursor-theme 'DMZ-White' 2>/dev/null || true

  # Optional: Adjust accent color to Mint-Y
  if gsettings writable org.cinnamon.desktop.interface accent-color &>/dev/null; then
    gsettings set org.cinnamon.desktop.interface accent-color 'mint-y' 2>/dev/null || true
  fi

  log "Linux Mint theme applied (Mint-Y Dark)."
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
  log "Installing and applying Inter + JetBrains Mono fonts..."

  local FONTS_DIR="$HOME/.fonts"
  local TMPDIR
  TMPDIR="$(mktemp -d)"

  mkdir -p "$FONTS_DIR"

  # Download Inter and JetBrains Mono from Google Fonts
  local INTER_ZIP="$TMPDIR/inter.zip"
  local JB_ZIP="$TMPDIR/jetbrains-mono.zip"

  if ! curl -fsSL "https://fonts.google.com/download?family=Inter" -o "$INTER_ZIP"; then
    warn "Failed to download Inter font zip."
  fi

  if ! curl -fsSL "https://fonts.google.com/download?family=JetBrains+Mono" -o "$JB_ZIP"; then
    warn "Failed to download JetBrains Mono font zip."
  fi

  # Extract and copy TTFs into ~/.fonts
  if [[ -f "$INTER_ZIP" ]]; then
    mkdir -p "$TMPDIR/inter"
    if unzip -qq "$INTER_ZIP" -d "$TMPDIR/inter"; then
      find "$TMPDIR/inter" -type f -name '*.ttf' -exec cp -n {} "$FONTS_DIR/" \;
      log "Copied Inter TTF files into $FONTS_DIR"
    else
      warn "Failed to unzip Inter font archive."
    fi
  fi

  if [[ -f "$JB_ZIP" ]]; then
    mkdir -p "$TMPDIR/jetbrains"
    if unzip -qq "$JB_ZIP" -d "$TMPDIR/jetbrains"; then
      find "$TMPDIR/jetbrains" -type f -name '*.ttf' -exec cp -n {} "$FONTS_DIR/" \;
      log "Copied JetBrains Mono TTF files into $FONTS_DIR"
    else
      warn "Failed to unzip JetBrains Mono font archive."
    fi
  fi

  # Refresh font cache (non-fatal if fc-cache is missing)
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$FONTS_DIR" || true
  fi

  rm -rf "$TMPDIR"

  # Apply fonts via gsettings (Cinnamon)
  if command -v gsettings >/dev/null 2>&1; then
    if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.interface'; then
      # Default + Desktop font
      gsettings set org.cinnamon.desktop.interface font-name 'Inter Regular 10' 2>/dev/null || \
        warn "Could not set default font to Inter Regular."

      # Monospace font
      gsettings set org.cinnamon.desktop.interface monospace-font-name 'JetBrains Mono Regular 10' 2>/dev/null || \
        warn "Could not set monospace font to JetBrains Mono Regular."
    fi

    if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.wm.preferences'; then
      # Window title font
      gsettings set org.cinnamon.desktop.wm.preferences titlebar-font 'Inter Medium 10' 2>/dev/null || \
        warn "Could not set titlebar font to Inter Medium."
    fi
  else
    warn "gsettings not found; skipping font configuration in Cinnamon."
  fi
}

set_themes() {
  log "Applying themes…"

  set_system_theme
  set_terminal_theme
  set_text_editor_theme
}

set_system_theme() {
  log "Configuring system theme (Catppuccin Frappe Standard Blue Dark)…"

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; skipping system theme configuration."
    return 0
  fi

  local THEME_NAME="Catppuccin-Frappe-Standard-Blue-Dark"
  # Using the official Catppuccin GTK release asset
  local THEME_URL="https://github.com/catppuccin/gtk/releases/download/v1.0.3/${THEME_NAME}.zip"
  local THEMES_DIR="$HOME/.themes"

  mkdir -p "$THEMES_DIR"

  local TMPDIR
  TMPDIR="$(mktemp -d)" || {
    warn "Could not create temp directory for GTK theme; skipping."
    return 0
  }

  if ! curl -fsSL "$THEME_URL" -o "$TMPDIR/theme.zip"; then
    warn "Failed to download Catppuccin GTK theme from $THEME_URL; skipping."
    rm -rf "$TMPDIR"
    return 0
  fi

  if ! unzip -q "$TMPDIR/theme.zip" -d "$TMPDIR"; then
    warn "Failed to unzip Catppuccin GTK theme; skipping."
    rm -rf "$TMPDIR"
    return 0
  fi

  # Prefer a folder matching THEME_NAME; if not found, copy all subdirectories
  if ls "$TMPDIR" | grep -qx "$THEME_NAME"; then
    cp -r "$TMPDIR/$THEME_NAME" "$THEMES_DIR/" 2>/dev/null || \
      warn "Could not copy $THEME_NAME into $THEMES_DIR."
  else
    cp -r "$TMPDIR"/*/ "$THEMES_DIR/" 2>/dev/null || \
      warn "Could not copy extracted GTK themes into $THEMES_DIR."
  fi

  rm -rf "$TMPDIR"

  # Apply to Cinnamon + GTK
  gsettings set org.cinnamon.desktop.interface gtk-theme "$THEME_NAME" 2>/dev/null || \
    warn "Could not set GTK theme to $THEME_NAME."
  gsettings set org.cinnamon.theme name "$THEME_NAME" 2>/dev/null || \
    warn "Could not set Cinnamon theme to $THEME_NAME."
}

set_terminal_theme() {
  log "Configuring terminal theme…"

  if ! command -v gnome-terminal >/dev/null 2>&1; then
    warn "gnome-terminal not found; skipping terminal theme configuration."
    return 0
  fi

  # Needed by Gogh for gnome-terminal profiles
  sudo apt-get install -y dconf-cli uuid-runtime || true

  local TMPDIR
  TMPDIR="$(mktemp -d)" || {
    warn "Could not create temp directory for Gogh; skipping terminal theme."
    return 0
  }

  local BASE_URL="https://raw.githubusercontent.com/Gogh-Co/Gogh/master"

  # Download apply-colors helper and the Catppuccin Frappe installer script
  if ! curl -fsSL "$BASE_URL/apply-colors.sh" -o "$TMPDIR/apply-colors.sh"; then
    warn "Failed to download Gogh apply-colors.sh; skipping terminal theme."
    rm -rf "$TMPDIR"
    return 0
  fi

  if ! curl -fsSL "$BASE_URL/installs/catppuccin-frappe.sh" -o "$TMPDIR/catppuccin-frappe.sh"; then
    warn "Failed to download Gogh Catppuccin Frappe installer; skipping terminal theme."
    rm -rf "$TMPDIR"
    return 0
  fi

  chmod +x "$TMPDIR"/apply-colors.sh "$TMPDIR"/catppuccin-frappe.sh

  # Run the theme installer in the directory where apply-colors.sh lives
  (
    cd "$TMPDIR" || exit 0
    TERMINAL=gnome-terminal bash ./catppuccin-frappe.sh
  ) || warn "Gogh Catppuccin Frappe install script failed; theme might not be applied."

  # Try to find the new profile and set it as default + set JetBrains Mono 11
  if command -v dconf >/dev/null 2>&1; then
    local PROFILE_IDS PROFILE_ID
    PROFILE_IDS=$(dconf list /org/gnome/terminal/legacy/profiles:/ 2>/dev/null | tr -d '/') || true

    for id in $PROFILE_IDS; do
      local NAME
      NAME=$(dconf read "/org/gnome/terminal/legacy/profiles:/:$id/visible-name" 2>/dev/null | tr -d "'") || true
      if [[ "$NAME" == "Catppuccin Frappe" ]]; then
        PROFILE_ID="$id"
        break
      fi
    done

    if [[ -n "${PROFILE_ID:-}" ]]; then
      # Make this profile the default
      dconf write /org/gnome/terminal/legacy/profiles:/default "'$PROFILE_ID'" 2>/dev/null || \
        warn "Could not set Catppuccin Frappe as the default terminal profile."

      # Disable system font and set JetBrains Mono Regular 11
      dconf write "/org/gnome/terminal/legacy/profiles:/:$PROFILE_ID/use-system-font" "false" 2>/dev/null || true
      dconf write "/org/gnome/terminal/legacy/profiles:/:$PROFILE_ID/font" "'JetBrains Mono Regular 11'" 2>/dev/null || \
        warn "Could not set JetBrains Mono font in gnome-terminal."
    else
      warn "Could not locate a 'Catppuccin Frappe' terminal profile; leaving the default profile unchanged."
    fi
  else
    warn "dconf not available; cannot set default terminal profile."
  fi

  rm -rf "$TMPDIR"
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

  # Disable 24-hour clock
  if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.interface'; then
    gsettings set org.cinnamon.desktop.interface clock-use-24h false 2>/dev/null || \
      warn "Could not set clock to 12-hour format."
  elif gsettings list-schemas | grep -qx 'org.gnome.desktop.interface'; then
    gsettings set org.gnome.desktop.interface clock-use-24h false 2>/dev/null || \
      warn "Could not set clock to 12-hour format."
  else
    warn "No compatible schema for clock-use-24h found."
  fi
}

tweak_screensaver_prefs() {
  log "Customizing lock screen..."

  # We know the exact schema and keys from your system
  if gsettings list-schemas | grep -qx 'org.cinnamon.desktop.screensaver'; then
    gsettings set org.cinnamon.desktop.screensaver allow-media-control false 2>/dev/null || \
      warn "Could not disable media controls on lock screen."
    gsettings set org.cinnamon.desktop.screensaver show-album-art false 2>/dev/null || \
      warn "Could not disable album art on lock screen."
    gsettings set org.cinnamon.desktop.screensaver floating-widgets false 2>/dev/null || \
      warn "Could not disable floating widgets on lock screen."
  else
    warn "Screensaver schema not found; skipping lock screen tweaks."
  fi

  # Refresh screensaver
  if command -v cinnamon-screensaver-command >/dev/null 2>&1; then
    cinnamon-screensaver-command -r 2>/dev/null || true
  else
    pkill -HUP -f cinnamon-screensaver 2>/dev/null || true
  fi
}

tweak_file_management_prefs() {
  log "Tweaking Nemo file management preferences..."

  if ! gsettings list-schemas | grep -qx 'org.nemo.preferences'; then
    warn "Schema org.nemo.preferences not found (is Nemo installed/running?)."
    return 0
  fi

  # 1) Default view → List View
  gsettings set org.nemo.preferences default-folder-viewer 'list-view' 2>/dev/null || \
    warn "Could not set Nemo default view to list-view."

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

  #TODO: 4) Rename on double-click.

  # Soft-reload Nemo so changes apply
  if command -v nemo >/dev/null 2>&1; then
    nemo -q 2>/dev/null || pkill -HUP -f 'nemo' 2>/dev/null || true
  fi
}

tweak_behavior_prefs() {
  log "Tweaking behavior prefs..."

  # 1) Center windows
  local centered=false

  if gsettings list-schemas | grep -qx 'org.cinnamon.muffin'; then
    if gsettings list-keys org.cinnamon.muffin | grep -qx 'placement-mode'; then
      if gsettings set org.cinnamon.muffin placement-mode 'center' 2>/dev/null; then
        log " • Window placement → center (org.cinnamon.muffin::placement-mode)"
        centered=true
      fi
    fi
    if [[ "$centered" == false ]] && gsettings list-keys org.cinnamon.muffin | grep -qx 'center-new-windows'; then
      if gsettings set org.cinnamon.muffin center-new-windows true 2>/dev/null; then
        log " • Window placement → center (org.cinnamon.muffin::center-new-windows)"
        centered=true
      fi
    fi
  fi

  if [[ "$centered" == false ]] && gsettings list-schemas | grep -qx 'org.gnome.mutter'; then
    if gsettings list-keys org.gnome.mutter | grep -qx 'center-new-windows'; then
      gsettings set org.gnome.mutter center-new-windows true 2>/dev/null && \
        log " • Window placement → center (org.gnome.mutter::center-new-windows)"
      centered=true
    fi
  fi

  [[ "$centered" == false ]] && warn " • Could not find a window-centering key on this system (skipped)."

  # 2) Remove Corner Bar (show desktop) from bottom-right panel corner
  if command -v gsettings >/dev/null 2>&1 && \
     gsettings list-schemas | grep -qx 'org.cinnamon' && \
     gsettings list-keys org.cinnamon | grep -qx 'enabled-applets'; then

    local CURRENT_APPLETS NEW_APPLETS
    CURRENT_APPLETS="$(gsettings get org.cinnamon enabled-applets 2>/dev/null || echo "[]")"

    NEW_APPLETS="$(python3 - "$CURRENT_APPLETS" <<'PY'
import ast, sys

cur = sys.argv[1]
try:
    arr = ast.literal_eval(cur)
except Exception:
    arr = []

if not isinstance(arr, list):
    arr = []

# Corner Bar applet UUID is cornerbar@cinnamon.org
filtered = [x for x in arr if 'cornerbar@cinnamon.org' not in str(x)]

print(str(filtered).replace('"', "'"))
PY
)"

    if [[ -n "$NEW_APPLETS" && "$NEW_APPLETS" != "$CURRENT_APPLETS" ]]; then
      if gsettings set org.cinnamon enabled-applets "$NEW_APPLETS" 2>/dev/null; then
        log " • Removed Corner Bar applet from panel (org.cinnamon::enabled-applets)"
      else
        warn " • Failed to update enabled applets when removing Corner Bar."
      fi
    else
      log " • Corner Bar applet not present in enabled applets (nothing to remove)."
    fi
  else
    warn " • Could not adjust Corner Bar applet (org.cinnamon::enabled-applets not available)."
  fi

  # 3) Enable top-left Hot Corner → Show all workspaces on hover
  # Cinnamon stores hot corner config in org.cinnamon hotcorner-layout as:
  #   ['func:hover:icon', '...', '...', '...']
  # Order: top-left, top-right, bottom-left, bottom-right.
  # "scale" == show all workspaces, "expo" == show all windows, "desktop" == show desktop. :contentReference[oaicite:1]{index=1}
  if command -v gsettings >/dev/null 2>&1 && \
     gsettings list-schemas | grep -qx 'org.cinnamon' && \
     gsettings list-keys org.cinnamon | grep -qx 'hotcorner-layout'; then

    local HCURRENT HNEW
    HCURRENT="$(gsettings get org.cinnamon hotcorner-layout 2>/dev/null || echo "[]")"

    HNEW="$(python3 - "$HCURRENT" <<'PY'
import ast, sys

cur = sys.argv[1]
try:
    layout = ast.literal_eval(cur)
except Exception:
    layout = []

# Ensure we have a list of four entries (one per corner)
if not isinstance(layout, list) or len(layout) != 4:
    # Sensible default: top-left shows all workspaces, others off
    layout = ["scale:true:0", "scale:false:0", "scale:false:0", "desktop:false:0"]
else:
    # Update top-left entry to "scale:true:<iconIndex>"
    entry = str(layout[0])
    parts = entry.split(':')
    if len(parts) < 3:
        parts = ['scale', 'true', '0']
    else:
        parts[0] = 'scale'   # show all workspaces
        parts[1] = 'true'    # enabled on hover
        # parts[2] = icon index (leave as-is if present)
    layout[0] = ':'.join(parts[:3])

print(str(layout).replace('"', "'"))
PY
)"

    if [[ -n "$HNEW" ]]; then
      if gsettings set org.cinnamon hotcorner-layout "$HNEW" 2>/dev/null; then
        log " • Hot corner (top-left) → Show all workspaces on hover (org.cinnamon::hotcorner-layout)"
      else
        warn " • Failed to apply hot corner layout."
      fi
    fi
  else
    warn " • Could not configure hot corner layout (org.cinnamon::hotcorner-layout not available)."
  fi

  # 4) Alt-Tab switcher style → Timeline (3D)
  if command -v gsettings >/dev/null 2>&1 && \
     gsettings list-schemas | grep -qx 'org.cinnamon.desktop.wm.preferences'; then

    if gsettings list-keys org.cinnamon.desktop.wm.preferences | grep -qx 'switcher-style'; then
      if gsettings set org.cinnamon.desktop.wm.preferences switcher-style 'timeline' 2>/dev/null; then
        log " • Alt-Tab switcher style → Timeline (3D)"
      else
        warn " • Failed to set Alt-Tab switcher style."
      fi
    else
      warn " • switcher-style key not found in org.cinnamon.desktop.wm.preferences; skipping Alt-Tab tweak."
    fi
  else
    warn " • org.cinnamon.desktop.wm.preferences schema not available; cannot tweak Alt-Tab behavior."
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
