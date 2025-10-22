#!/usr/bin/env bash
# Log everything to a file as well as stdout/stderr
exec > >(tee -a "$HOME/mint-workstation-setup.log") 2>&1
set -euo pipefail
trap 'echo -e "\n[ERR ] Failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive

# =============================================================================
#    Linux Mint Workstation Setup
#
#  - Args: --skip-vulkan | --gpu=auto|nvidia|amd|intel|none | --help
#
#  1) System Updates
#  2) GPU Driver Helper (auto/NVIDIA/AMD/Intel)
#  3) SDKs (.NET/Vulkan)
#  4) LibreOffice via Flatpak
#  5) App Installs
#     • git - Version Control
#     • VS Code - Code Editor
#     • Joplin - Note-Taking
#     • Bitwarden - Password Vault
#     • Blender - 3D Modeling & Rendering
#     • FreeCAD - Parametric CAD
#     • Inkscape - Vector Graphics
#     • Krita - Raster Art
#     • Kdenlive - Video Editing
#     • OBS - Screen Recording
#     • Flameshot - Screenshot Utility
#  6) VS Code Extensions
#  7) VS Code Settings
#  8) App Configurations
#  9) "Rice" - Themes & Aesthetics
# =============================================================================

# ----- helpers ---------------------------------------------------------------
log()   { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
exists(){ command -v "$1" >/dev/null 2>&1; }
is_pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

require_sudo() {
  if [[ $EUID -ne 0 ]]; then
    log "Requesting sudo privileges..."
    sudo -v
  fi
}

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
  require_sudo
  
  sudo apt-get update -y
  sudo apt-get -o Dpkg::Options::="--force-confnew" dist-upgrade -y
  sudo apt-get autoremove -y

  log "Installing common prerequisites..."
  sudo apt-get install -y \
    curl wget apt-transport-https ca-certificates gnupg lsb-release \
    software-properties-common python3-minimal jq unzip
}

# =============================================================================
#  2) GPU DRIVER HELPER
#      - auto: detect vendor; NVIDIA => proprietary driver, AMD/Intel => Mesa
#      - nvidia: force ubuntu-drivers autoinstall
#      - amd/intel: ensure Mesa Vulkan stack
#      - none: do nothing
# =============================================================================
install_gpu_drivers() {
  require_sudo
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
  require_sudo
  
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
  require_sudo
  
  sudo apt-get install -y \
    libvulkan1 vulkan-tools \
    libvulkan-dev vulkan-validationlayers \
    glslang-tools spirv-tools shaderc \
    mesa-vulkan-drivers

  # Optional X/Wayland dev headers, helpful for building sample apps with windows
  sudo apt-get install -y \
    libx11-dev libxcursor-dev libxrandr-dev libxi-dev libxinerama-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev || true

  if command -v vulkaninfo >/dev/null 2>&1; then
    log "vulkaninfo (first lines):"
    vulkaninfo | head -n 10 || true
  else
    warn "vulkaninfo not found; ensure 'vulkan-tools' installed and drivers support Vulkan."
  fi

  log "Vulkan (APT packages) install done."
}

# =============================================================================
#  4) LIBREOFFICE VIA FLATPAK
# =============================================================================
libreoffice_flatpak() {
  log "Installing LibreOffice from Flathub (removing distro)..."
  require_sudo
  
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

# =============================================================================
#  5) APP INSTALLS
# =============================================================================
install_apps() {
  install_git
  install_vscode
  install_bitwarden
  install_joplin
  install_creative_tools_flatpaks
}

install_git() {
  log "Installing Git..."
  require_sudo
  
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
  require_sudo
  
  if command -v flatpak >/dev/null 2>&1 && flatpak list --app | grep -qi 'com.visualstudio.code'; then
    sudo flatpak uninstall -y com.visualstudio.code || true
  fi
  if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -qi '^code '; then
    sudo snap remove code || true
  fi
  if is_pkg_installed code; then
    log "VS Code (deb) already installed."; return 0
  fi
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | sudo tee /usr/share/keyrings/ms_vscode.gpg >/dev/null
  echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/ms_vscode.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y code
}

install_bitwarden() {
  log "Installing Bitwarden (prefer .deb, fallback Flatpak if fetch fails)..."
  require_sudo
  
  if ! is_pkg_installed bitwarden; then
    TMP_DEB=$(mktemp --suffix=.deb)
    if curl -fsSL -o "$TMP_DEB" "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb"; then
      require_sudo
      sudo dpkg -i "$TMP_DEB" || sudo apt-get -f install -y
      rm -f "$TMP_DEB"
    else
      sudo flatpak install -y flathub com.bitwarden.desktop
    fi
  fi
}

install_joplin() {
  log "Installing Joplin via official install/update script (no Flatpak)..."
  require_sudo
  
  # Prevent AppImage launch issues on some bases
  sudo apt-get install -y libfuse2 || true

  JOPLIN_SCRIPT=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/laurent22/joplin/dev/Joplin_install_and_update.sh" -o "$JOPLIN_SCRIPT"
  chmod +x "$JOPLIN_SCRIPT"
  bash "$JOPLIN_SCRIPT"
  rm -f "$JOPLIN_SCRIPT"
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

# =============================================================================
#  6) VS CODE EXTENSIONS
# =============================================================================
install_vscode_extensions() {
  if ! exists code; then
    warn "VS Code not detected; skipping extension installs."; return 0
  fi

  log "Installing VS Code extensions for .NET, web, and Avalonia development..."

  # Headless warm-up (non-fatal) to ensure 'code' CLI is ready
  timeout 10s code --version >/dev/null 2>&1 || true

  code --install-extension ms-dotnettools.vscode-dotnet-runtime   || true
  code --install-extension ms-dotnettools.csharp                  || true
  code --install-extension ms-dotnettools.csdevkit                || true
  code --install-extension JosKreativ.vscode-csharp-extensions    || true
  code --install-extension JeremyCaron.csharp-organize-usings     || true
  code --install-extension dbaeumer.vscode-eslint                 || true
  code --install-extension ecmel.vscode-html-css                  || true
  code --install-extension xabikos.JavaScriptSnippets             || true
  code --install-extension formulahendry.auto-close-tag           || true
  code --install-extension christian-kohler.path-intellisense     || true
  code --install-extension PKief.material-icon-theme              || true
  code --install-extension KatsuteDev.background                  || true
  code --install-extension AvaloniaTeam.vscode-avalonia           || true

  # Install Avalonia .NET project templates
  if command -v dotnet >/dev/null 2>&1; then
    log "Installing Avalonia .NET project templates..."
    dotnet new install Avalonia.Templates || warn "Avalonia.Templates install failed."
  else
    warn ".NET SDK not found; skipping Avalonia.Templates install."
  fi

  log "VS Code extension installation complete."
}

# =============================================================================
#  7) VS CODE SETTINGS
# =============================================================================
apply_vscode_settings() {
  log "Applying VS Code settings and keybindings..."
  require_sudo

  USER_DIR="$HOME/.config/Code/User"
  mkdir -p "$USER_DIR"

  read -r -d '' NEW_SETTINGS <<'JSON'
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
  "dotnetAcquisitionExtension.existingDotnetPath": "/usr/share/dotnet/dotnet",
  "dotnetAcquisitionExtension.enableTelemetry": false,
  "eslint.validate": ["javascript","javascriptreact","typescript","typescriptreact"],
  "csharp.semanticHighlighting.enabled": true,
  "csharp.suppressDotnetInstallWarning": true
}
JSON

  read -r -d '' NEW_KEYS <<'JSON'
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

# =============================================================================
#  8) APP CONFIGURATIONS
# =============================================================================
configure_apps() {
  configure_libreoffice
  configure_firefox
}

configure_libreoffice() {
  log "Configuring LibreOffice..."
  
  cat > "$HOME/.configure-libreoffice-ui.sh" <<'EOF'
#!/usr/bin/env bash
echo "Open LibreOffice → View → User Interface → Tabbed to apply."
EOF
  chmod +x "$HOME/.configure-libreoffice-ui.sh"
}

configure_firefox() {
  log "Configuring Firefox..."

  local FF_DIR="$HOME/.mozilla/firefox"
  local PROFILE=""
  if [[ -d "$FF_DIR" ]]; then
    PROFILE=$(find "$FF_DIR" -maxdepth 1 -type d -name "*.default*" | head -n 1 || true)
  fi

  if [[ -z "$PROFILE" || ! -d "$PROFILE" ]]; then
    warn "No Firefox profile found yet. Skipping Firefox config (run Firefox once to create a profile)."
    return 0
  fi

  local USERJS="$PROFILE/user.js"
  local TS; TS="$(date +%Y%m%d-%H%M%S)"

  # Prefs to enforce
  local -a PREF_KEYS=(
    'layers.acceleration.force-enabled'
    'gfx.webrender.all'
    'media.ffmpeg.vaapi.enabled'
    'media.hardware-video-decoding.enabled'
    'media.rdd-ffmpeg.enabled'
    'gfx.x11-egl.force-enabled'
    'widget.dmabuf.force-enabled'
  )

  # Backup existing user.js (if any)
  if [[ -f "$USERJS" ]]; then
    cp "$USERJS" "$USERJS.bak.$TS"
  fi

  # Start from existing (or empty), but strip previous copies of the keys we manage
  local TMP="$USERJS.tmp.$TS"
  [[ -f "$USERJS" ]] && cp "$USERJS" "$TMP" || : 

  for k in "${PREF_KEYS[@]}"; do
    # Remove any existing lines for this key
    sed -i "\#^user_pref(\"$k\",#d" "$TMP" 2>/dev/null || true
  done

  # Append our managed block
  {
    echo '// ===== mint-workstation-setup: managed Firefox prefs ====='
    echo 'user_pref("layers.acceleration.force-enabled", true);'
    echo 'user_pref("gfx.webrender.all", true);'
    echo 'user_pref("media.ffmpeg.vaapi.enabled", true);'
    echo 'user_pref("media.hardware-video-decoding.enabled", true);'
    echo 'user_pref("media.rdd-ffmpeg.enabled", true);'
    echo 'user_pref("gfx.x11-egl.force-enabled", true);'
    echo 'user_pref("widget.dmabuf.force-enabled", true);'
  } >> "$TMP"

  mv "$TMP" "$USERJS"
  log "Firefox prefs applied at: $USERJS"
}

# =============================================================================
#  9) "RICE" – THEMES & AESTHETICS
# =============================================================================
cook_rice() {
  set_icon_theme
  set_fonts
  tweak_screensaver_prefs
  install_neofetch
  install_gnome_gtile
  install_cinnamon_transparent_panels
}

set_icon_theme() {
  log "Installing and applying Papirus icon theme..."
  require_sudo
  
  sudo add-apt-repository -y ppa:papirus/papirus || true
  sudo apt-get update -y
  sudo apt-get install -y papirus-icon-theme
  if exists gsettings; then
    gsettings set org.cinnamon.desktop.interface icon-theme 'Papirus-Dark' || true
  fi
}

set_fonts() {
  log "Installing developer-friendly fonts (Fira Code, JetBrains Mono)..."
  require_sudo
  
  sudo apt-get install -y fonts-firacode fonts-jetbrains-mono
}

tweak_screensaver_prefs() {
  log "Customizing lock screen..."

  # Candidate schemas seen across Cinnamon/Mint versions
  local schemas=(
    "org.cinnamon.desktop.screensaver"
    "org.cinnamon.screensaver"
    "org.gnome.desktop.screensaver"
  )

  # Candidate key names for each preference (varies by version)
  local media_keys=(
    "show-media-controls" "media-controls" "allow-media-control"
    "show-media-player" "show-media-player-controls"
  )
  local album_keys=(
    "show-album-art" "album-art" "show-media-artwork" "show-albumart"
  )
  local floating_keys=(
    "allow-floating" "allow-floating-window" "allow-floating-controls"
    "allow-floating-ambient"
  )

  # Utility: does a schema exist?
  schema_exists() { gsettings list-schemas | grep -qx "$1"; }

  # Utility: does a key exist in schema?
  key_exists() { gsettings list-keys "$1" 2>/dev/null | grep -qx "$2"; }

  # Try to set the first matching key in any schema for a given list of keys
  set_first_match_false() {
    local -n _keys_ref=$1   # nameref to the key array
    local label="$2"        # human-friendly label for logs
    local set_ok=false

    for sch in "${schemas[@]}"; do
      schema_exists "$sch" || continue
      for k in "${_keys_ref[@]}"; do
        if key_exists "$sch" "$k"; then
          if gsettings set "$sch" "$k" false 2>/dev/null; then
            log " • $label → false  ($sch::$k)"
            set_ok=true
            break 2
          fi
        fi
      done
    done

    if [[ "$set_ok" == false ]]; then
      warn " • $label not found on this system (skipped)."
    fi
  }

  # Apply toggles
  set_first_match_false media_keys   "Show media player controls"
  set_first_match_false album_keys   "Show album art"
  set_first_match_false floating_keys "Allow floating overlay"

  # Try to refresh the screensaver so changes apply
  if command -v cinnamon-screensaver-command >/dev/null 2>&1; then
    cinnamon-screensaver-command -r 2>/dev/null || true
  else
    # As a last resort, gently nudge the process (non-fatal)
    pkill -HUP -f cinnamon-screensaver 2>/dev/null || true
  fi
}

install_neofetch() {
  log "Installing Neofetch..."
  require_sudo
  
  sudo apt-get install -y neofetch

  log "Enabling Neofetch auto-launch for interactive shells..."
  local MARKER="neofetch auto-launch (added by mint-workstation-setup)"
  read -r -d '' NEOFETCH_SNIPPET <<'EOF'
# >>> neofetch auto-launch (added by mint-workstation-setup) >>>
if command -v neofetch >/dev/null 2>&1; then
  case "$-" in
    *i*) neofetch ;;
  esac
fi
# <<< neofetch auto-launch <<<
EOF

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

install_gnome_gtile() {
  # Only for GNOME sessions
  if [[ "$XDG_CURRENT_DESKTOP" != *"GNOME"* ]]; then
    warn "GNOME Shell not detected; skipping gTile installation."
    return 0
  fi

  log "Installing gTile (GNOME extension)..."
  require_sudo
  
  sudo apt-get install -y gnome-shell-extensions gnome-shell-extension-manager curl

  if ! command -v gnome-extensions >/dev/null 2>&1; then
    warn "gnome-extensions CLI not found — cannot enable gTile automatically."
  fi

  local UUID="gTile@vibou"
  local EXT_DIR="$HOME/.local/share/gnome-shell/extensions/$UUID"

  if [[ -d "$EXT_DIR" ]]; then
    log "gTile already installed at $EXT_DIR"
  else
    log "Downloading and installing gTile..."
    local VERSION_URL="https://extensions.gnome.org/extension-query/?search=gtile"
    local DOWNLOAD_URL
    # pick the last (latest) shell_version_map entry safely
    DOWNLOAD_URL=$(curl -s "$VERSION_URL" \
      | jq -r '.extensions[0].shell_version_map | .[length-1].download_url' 2>/dev/null || true)

    if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
      warn "Could not resolve gTile download URL; skipping installation."
      return 0
    fi

    local TEMP_ZIP
    TEMP_ZIP=$(mktemp --suffix=.zip)
    curl -fsSL "https://extensions.gnome.org${DOWNLOAD_URL}" -o "$TEMP_ZIP"
    mkdir -p "$EXT_DIR"
    unzip -qo "$TEMP_ZIP" -d "$EXT_DIR"
    rm -f "$TEMP_ZIP"
    log "gTile installed to $EXT_DIR"
  fi

  if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions enable "$UUID" || warn "Failed to enable gTile automatically."
    log "gTile extension enabled."
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

  git clone --depth=1 https://github.com/germanfr/cinnamon-transparent-panels.git \
    "$TMPDIR/cinnamon-transparent-panels" >/dev/null 2>&1 || {
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
    NEW="$(python3 - <<PY
import ast
lst = []
try:
    lst = ast.literal_eval(${CURRENT!r})
except Exception:
    pass
if "${UUID}" not in lst:
    lst.append("${UUID}")
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

  log "==== 4) LIBREOFFICE VIA FLATPAK ===="
  libreoffice_flatpak

  log "==== 5) APP INSTALLS ===="
  install_apps

  log "==== 6) VS CODE EXTENSIONS ===="
  install_vscode_extensions

  log "==== 7) VS CODE SETTINGS ===="
  apply_vscode_settings

  log "==== 8) APP CONFIGURATIONS ===="
  configure_apps

  log "==== 9) RICE (THEMES & AESTHETICS) ===="
  cook_rice

  log "✅ Setup complete!"
  if [[ -f "$HOME/.reboot-recommended-nvidia" ]]; then
    warn "NVIDIA drivers were installed; a reboot is recommended."
  fi
}
main "$@"
