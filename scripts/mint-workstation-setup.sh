#!/usr/bin/env bash
# Log everything to a file as well as stdout/stderr
exec > >(tee -a "$HOME/mint-workstation-setup.log") 2>&1

# Keep sudo alive during the whole run (only if not root)
if [[ $EUID -ne 0 ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[ERR ] 'sudo' is required but not installed. Aborting." >&2
    exit 1
  fi
  # Initial prompt (interactive); if this fails, abort early and clearly
  if ! sudo -v; then
    echo "[ERR ] Unable to obtain sudo privileges. Aborting." >&2
    exit 1
  fi
  # Background refresh (non-interactive, no prompts)
  ( while true; do sleep 60; sudo -n true || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

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
  install_bitwarden
  install_joplin
  install_bleachbit
  uninstall_firefox
  install_brave_browser
  install_creative_tools_flatpaks
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

install_bitwarden() {
  log "Installing Bitwarden (prefer .deb, fallback Flatpak if fetch fails)..."

  if ! is_pkg_installed bitwarden; then
    TMP_DEB=$(mktemp --suffix=.deb)
    if curl -fsSL -o "$TMP_DEB" "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb"; then
      sudo dpkg -i "$TMP_DEB" || sudo apt-get -f install -y
      rm -f "$TMP_DEB"
    else
      sudo flatpak install -y flathub com.bitwarden.desktop
    fi
  fi
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

install_creative_tools_flatpaks() {
  log "Installing creative tools and utilities via Flatpak..."

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

  # Minimal safe preset:
  # - Only remove generic caches/temp and thumbnails
  # - Leave browsers and package caches untouched
  cat > "$CFG_FILE" <<'INI'
[bleachbit]
# Do not overwrite; just provide sane safe defaults.
# You can edit these later via the GUI (Preferences).

# General behavior
shred = False
confirm = True
delete_confirmation = True

# Keep only English interface (optional; comment out to keep all)
# preserve_languages = en

# Cleaners: section names map to modules; keys map to specific items.
# We keep this conservative.
[system]
cache = True
temporary_files = True
# recent_documents = False         ; Uncomment to also clear recent docs
trash = True

[thumbnails]
cache = True

# Browser cleaners intentionally left untouched by default:
# Brave/Chromium-based examples you could enable later:
# [brave]
# cache = True
# cookies = True
# history = True
#
# [chromium]
# cache = True
# cookies = True
# history = True

# Package managers intentionally left untouched:
# [apt]
# autoclean = False
# clean = False
INI

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

  NEW_SETTINGS="$(cat <<'JSON'
{
  "workbench.iconTheme": "material-icon-theme",
  "editor.tabSize": 2,
  "editor.insertSpaces": true,
  "editor.formatOnSave": true,
  "editor.defaultFormatter": "ms-dotnettools.csharp",
  "editor.codeActionsOnSave": { "source.organizeImports": "explicit" },
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  "editor.bracketPairColorization.enabled": true,
  "editor.cursorBlinking": "expand",
  "editor.fontSize": 16,
  "explorer.confirmDelete": false,
  "git.confirmSync": false,
  "git.enableSmartCommit": true,
  "csharpOrganizeUsings.sortOrder": "",
  "csharpOrganizeUsings.splitGroups": false,
  "telemetry.telemetryLevel": "off",
  "github.copilot.nextEditSuggestions.enabled": true
}
JSON
)"
  NEW_KEYS="$(cat <<'JSON'
[
  {
    "key": "ctrl+alt+o",
    "command": "csharp-organize-usings.organize",
    "when": "editorTextFocus && editorLangId == csharp"
  },
  {
    "key": "ctrl+shift+i",
    "command": "editor.action.formatDocument",
    "when": "editorHasDocumentFormattingProvider && editorTextFocus && !editorReadonly"
  }
]
JSON
)"

  SETTINGS="$USER_DIR/settings.json"
  KEYS="$USER_DIR/keybindings.json"
  TS=$(date +%Y%m%d-%H%M%S)
  [[ -f "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak.$TS"
  [[ -f "$KEYS" ]] && cp "$KEYS" "$KEYS.bak.$TS"

  if [[ -f "$SETTINGS" ]]; then
    jq -s '.[0] * .[1]' "$SETTINGS" <(printf "%s" "$NEW_SETTINGS") > "$SETTINGS.merged.$TS" && mv "$SETTINGS.merged.$TS" "$SETTINGS"
  else
    printf "%s" "$NEW_SETTINGS" > "$SETTINGS"
  fi

  if [[ -f "$KEYS" ]]; then
    jq -s '[.[0][], .[1][]] | unique_by(.key + ":" + .command)' "$KEYS" <(printf "%s" "$NEW_KEYS") > "$KEYS.merged.$TS" && mv "$KEYS.merged.$TS" "$KEYS"
  else
    printf "%s" "$NEW_KEYS" > "$KEYS"
  fi
}

configure_favorites() {
  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not available; cannot configure favorites."
    return 0
  fi

  log "Updating Cinnamon favorites (remove Files/Terminal, add Thunderbird/Joplin)..."

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

# Ensure Thunderbird
ensure(fav, "thunderbird.desktop")

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
  set_mint_theme
  set_icon_theme
  set_fonts
  tweak_time_and_date_prefs
  tweak_screensaver_prefs
  tweak_file_management_prefs
  tweak_behavior_prefs
  install_neofetch
  # install_cinnamon_gtile
  # install_cinnamon_transparent_panels
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
  log "Installing developer-friendly fonts (Fira Code, JetBrains Mono)..."

  sudo apt-get install -y fonts-firacode fonts-jetbrains-mono
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

  log "Time and date preferences updated."
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

  1) Center windows.
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

  #TODO: 2) Open menu on hover.
}

install_cinnamon_gtile() {
  # Only for Cinnamon sessions
  if [[ "$XDG_CURRENT_DESKTOP" != *"Cinnamon"* && "$XDG_CURRENT_DESKTOP" != *"X-Cinnamon"* ]]; then
    warn "Cinnamon desktop not detected; skipping gTile (Cinnamon)."
    return 0
  fi

  log "Installing gTile (Cinnamon Spice)..."

  local TMPDIR UUID EXT_BASE TARGET
  TMPDIR="$(mktemp -d)"
  UUID="gTile@shuairan"
  EXT_BASE="$HOME/.local/share/cinnamon/extensions"
  TARGET="$EXT_BASE/$UUID"

  # We assume git is available from the App Installs step.
  git clone --depth=1 https://github.com/shuairan/gTile "$TMPDIR/gTile" >/dev/null 2>&1 || {
    warn "Git clone failed; aborting gTile (Cinnamon)."
    rm -rf "$TMPDIR"
    return 0
  }

  mkdir -p "$EXT_BASE"
  rm -rf "$TARGET"
  cp -r "$TMPDIR/gTile" "$TARGET"
  rm -rf "$TMPDIR"
  log "gTile (Cinnamon) installed to $TARGET"

  # Enable the extension automatically
  if command -v gsettings >/dev/null 2>&1; then
    log "Enabling gTile (Cinnamon) extension..."
    local CURRENT NEW
    CURRENT="$(gsettings get org.cinnamon enabled-extensions 2>/dev/null || echo "[]")"
    NEW="$(python3 - "$CURRENT" "$UUID" <<'PY'
import ast, sys
cur = sys.argv[1]
uuid = sys.argv[2]
try:
    # Handle GVariant like "@as []"
    if cur.startswith('@as '):
        cur = cur.split(' ', 1)[1]
    lst = ast.literal_eval(cur)
except Exception:
    lst = []
if uuid not in lst:
    lst.append(uuid)
print(str(lst).replace('"', "'"))
PY
)"
    gsettings set org.cinnamon enabled-extensions "$NEW" 2>/dev/null || {
      warn "Failed to enable gTile (Cinnamon) via gsettings."
      return 0
    }
    log "gTile (Cinnamon) enabled."
    # Soft-reload Cinnamon to apply changes
    pkill -HUP -f "cinnamon$" 2>/dev/null || true
  else
    warn "gsettings not found; unable to auto-enable gTile (Cinnamon)."
  fi
}

install_cinnamon_transparent_panels() {
  # Only for Cinnamon sessions
  if [[ "$XDG_CURRENT_DESKTOP" != *"Cinnamon"* && "$XDG_CURRENT_DESKTOP" != *"X-Cinnamon"* ]]; then
    warn "Cinnamon desktop not detected; skipping Transparent Panels."
    return 0
  fi

  log "Installing Transparent Panels (via upstream utils.sh)..."
  local TMPDIR UUID
  TMPDIR="$(mktemp -d)"
  UUID="transparent-panels@germanfr.github.com"

  git clone --depth=1 https://github.com/germanfr/cinnamon-transparent-panels.git     "$TMPDIR/cinnamon-transparent-panels" >/dev/null 2>&1 || {
      warn "Git clone failed; aborting Transparent Panels."
      rm -rf "$TMPDIR"
      return 0
    }

  # Run installer as current user
  if ( cd "$TMPDIR/cinnamon-transparent-panels" && bash ./utils.sh install ); then
    log "Transparent Panels installed to ~/.local/share/cinnamon/extensions/$UUID"
  else
    warn "Transparent Panels installer (utils.sh) failed."
    rm -rf "$TMPDIR"
    return 0
  fi

  rm -rf "$TMPDIR"

  # Enable the extension automatically
  if command -v gsettings >/dev/null 2>&1; then
    log "Enabling Transparent Panels extension..."

    local CURRENT NEW
    CURRENT="$(gsettings get org.cinnamon enabled-extensions 2>/dev/null || echo "[]")"

    # Use Python for safe list manipulation (avoids bash quoting issues)
    NEW="$(python3 - "$CURRENT" "$UUID" <<'PY'
import ast, sys
cur = sys.argv[1]
uuid = sys.argv[2]
try:
    if cur.startswith('@as '):
        cur = cur.split(' ', 1)[1]
    lst = ast.literal_eval(cur)
except Exception:
    lst = []
if uuid not in lst:
    lst.append(uuid)
print(str(lst).replace('"', "'"))
PY
)"
    if [[ -n "$NEW" ]]; then
      gsettings set org.cinnamon enabled-extensions "$NEW" 2>/dev/null || {
        warn "Failed to enable Transparent Panels via gsettings."
        return 0
      }
      log "Transparent Panels extension enabled successfully."
      # Reload Cinnamon to apply changes immediately (safe, no logout required)
      pkill -HUP -f "cinnamon$" 2>/dev/null || true
    fi
  else
    warn "gsettings not found; unable to auto-enable Transparent Panels."
  fi
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
  cook_rice

  final_updates
  log "✅ Setup complete!"
  print_final_reboot_notice
}
main "$@"
