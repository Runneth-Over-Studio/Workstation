#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#    Linux Mint Workstation Setup
#
#  - Args: --skip-vulkan | --gpu=auto|nvidia|amd|intel | --help
#
#  1) System Updates
#  2) GPU Driver Helper (auto/NVIDIA/AMD/Intel)
#  3) SDKs (.NET/Vulkan)
#  4) LibreOffice via Flatpak
#  5) App Installs
#     • VS Code - Code Editor
#     • Joplin - Note-Taking
#     • Bitwarden - Password Vault
#     • Blender - 3D Modeling & Rendering
#     • FreeCAD - Parametric CAD
#     • Inkscape - Vector Graphics
#     • Krita - Raster Art
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
Usage: $0 [--skip-vulkan] [--gpu=auto|nvidia|amd|intel] [--help]

Options:
  --skip-vulkan           Skip installing Vulkan development packages
  --gpu=MODE              Install/ensure GPU driver stack:
                            auto   (default) detect GPU and choose
                            nvidia proprietary via ubuntu-drivers
                            amd    Mesa Vulkan stack
                            intel  Mesa Vulkan stack
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
  require_sudo
  log "Updating APT index and upgrading the system..."
  sudo apt-get update -y
  sudo apt-get dist-upgrade -y
  sudo apt-get autoremove -y

  log "Installing common prerequisites..."
  sudo apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release software-properties-common
}

# =============================================================================
#  2) GPU DRIVER HELPER
#      - auto: detect vendor; NVIDIA => proprietary driver, AMD/Intel => Mesa
#      - nvidia: force ubuntu-drivers autoinstall
#      - amd/intel: ensure Mesa Vulkan stack
# =============================================================================
install_gpu_drivers() {
  require_sudo
  local mode="$GPU_MODE"

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
      # This picks the recommended nvidia-driver-XXX for your card
      sudo ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall did not complete successfully."
      log "NVIDIA driver install attempted. A reboot is usually required."
      ;;

    amd|intel)
      log "Ensuring Mesa Vulkan stack (works for AMD & Intel)..."
      sudo apt-get update -y
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
install_dotnet_sdk() {
  require_sudo
  log "Installing the latest .NET SDK (current LTS) using dotnet-install.sh..."
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
  require_sudo
  if [[ "$SKIP_VULKAN" == true ]]; then
    log "Skipping Vulkan packages (--skip-vulkan)."
    return 0
  fi

  log "Installing Vulkan via distro packages (recommended, standard way)..."
  sudo apt-get update -y
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
  require_sudo
  log "Removing distro LibreOffice (APT) if present..."
  sudo apt-get remove -y --purge libreoffice* libreoffice-core* || true
  sudo apt-get autoremove -y || true

  log "Ensuring Flatpak + Flathub are available..."
  sudo apt-get install -y flatpak
  if ! flatpak remote-list | grep -qi flathub; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi

  log "Installing LibreOffice from Flathub..."
  sudo flatpak install -y flathub org.libreoffice.LibreOffice
}

# =============================================================================
#  5) APP INSTALLS
# =============================================================================
install_vscode() {
  log "Installing VS Code via Microsoft APT repo (no Flatpak/Snap fallback)..."
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
  JOPLIN_SCRIPT=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/laurent22/joplin/dev/Joplin_install_and_update.sh" -o "$JOPLIN_SCRIPT"
  chmod +x "$JOPLIN_SCRIPT"
  bash "$JOPLIN_SCRIPT"
  rm -f "$JOPLIN_SCRIPT"
}

install_creative_and_utils_flatpaks() {
  log "Installing creative tools and utilities via Flatpak..."
  sudo flatpak install -y flathub org.blender.Blender
  sudo flatpak install -y flathub org.freecadweb.FreeCAD || sudo flatpak install -y flathub org.freecad.FreeCAD
  sudo flatpak install -y flathub org.inkscape.Inkscape
  sudo flatpak install -y flathub org.kde.krita
  sudo flatpak install -y flathub org.flameshot.Flameshot
}

# =============================================================================
#  6) VS CODE EXTENSIONS
# =============================================================================
install_vscode_extensions() {
  log "Installing VS Code extensions for .NET, web, and Avalonia development..."
  if ! exists code; then
    warn "VS Code not detected; skipping extension installs."; return 0
  fi
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
  log "VS Code extension installation complete."
}

# =============================================================================
#  7) VS CODE SETTINGS
# =============================================================================
apply_vscode_settings() {
  log "Applying VS Code settings and keybindings..."
  require_sudo
  sudo apt-get install -y jq
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
  log "Configuring LibreOffice (Tabbed UI helper script)..."
  cat > "$HOME/.configure-libreoffice-ui.sh" <<'EOF'
#!/usr/bin/env bash
echo "Open LibreOffice → View → User Interface → Tabbed to apply."
EOF
  chmod +x "$HOME/.configure-libreoffice-ui.sh"
}

# =============================================================================
#  9) "RICE" – THEMES & AESTHETICS
# =============================================================================
rice_section() {
  require_sudo
  log "Installing Papirus icon theme and useful fonts..."
  sudo add-apt-repository -y ppa:papirus/papirus || true
  sudo apt-get update -y
  sudo apt-get install -y papirus-icon-theme fonts-firacode fonts-jetbrains-mono
  if exists gsettings; then
    gsettings set org.cinnamon.desktop.interface icon-theme 'Papirus-Dark' || true
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
  install_dotnet_sdk
  install_vulkan_sdk

  log "==== 4) LIBREOFFICE VIA FLATPAK ===="
  libreoffice_flatpak

  log "==== 5) APP INSTALLS ===="
  install_vscode
  install_bitwarden
  install_joplin
  install_creative_and_utils_flatpaks

  log "==== 6) VS CODE EXTENSIONS ===="
  install_vscode_extensions

  log "==== 7) VS CODE SETTINGS ===="
  apply_vscode_settings

  log "==== 8) APP CONFIGURATIONS ===="
  configure_apps

  log "==== 9) RICE (THEMES & AESTHETICS) ===="
  rice_section

  log "✅ Setup complete!"
}
main "$@"
