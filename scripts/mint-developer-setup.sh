#!/usr/bin/env bash
# =============================================================================
#    Linux Mint Cinnamon — Developer Setup
#
#  For developer machines. Usually run after mint-general-setup.sh, but it
#  doesn't depend on it. Safe to re-run.
#
#  1) System update, prerequisites, automatic updates
#  2) Developer tools
#     • git - Version Control
#     • .NET SDK (latest LTS from APT) + MonoGame project templates
#     • VS Code - Code Editor (+ extensions, settings, keybindings)
#     • Blender - 3D Modeling & Rendering
#  3) Desktop integration
# =============================================================================
set -Eeuo pipefail

WORKSTATION_REF="${WORKSTATION_REF:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run via `bash <(curl ...)` there is no repo beside the script: fetch it and re-run from there.
if [[ ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  REPO_TMP="$(mktemp -d)"
  echo "[INFO] Downloading Runneth-Over-Studio/Workstation ($WORKSTATION_REF)…"
  curl -fsSL "https://github.com/Runneth-Over-Studio/Workstation/archive/$WORKSTATION_REF.tar.gz" \
    | tar -xz -C "$REPO_TMP" --strip-components=1
  exec bash "$REPO_TMP/scripts/mint-developer-setup.sh" "$@"
fi

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: mint-developer-setup.sh [--help]

Developer tooling for Linux Mint Cinnamon. Safe to re-run.
Set WORKSTATION_REF=<branch|tag> to run resources from a branch other than main.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    *)         error "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

VSCODE_USER_DIR="$HOME/.config/Code/User"

# Extensions earlier versions of this script installed that are now redundant with
# built-in VS Code / C# Dev Kit features. Removed if present.
RETIRED_VSCODE_EXTENSIONS=(
  formulahendry.auto-close-tag
  JeremyCaron.csharp-organize-usings
  xabikos.JavaScriptSnippets
)

# =============================================================================
#  2) DEVELOPER TOOLS
# =============================================================================
install_git() {
  apt_install git
  info "$(git --version)"
  mkdir -p "$HOME/source"
}

# Newest LTS SDK package available. .NET LTS releases have even major versions
# (8, 10, 12, …); moving to an odd-numbered (STS) release should be a deliberate change here.
latest_lts_dotnet_sdk_pkg() {
  apt-cache pkgnames dotnet-sdk- | grep -E '^dotnet-sdk-[0-9]*[02468]\.0$' | sort -V | tail -n1 || true
}

install_dotnet_sdk() {
  # Earlier versions of this script used dotnet-install.sh into /usr/share/dotnet,
  # which never updated. Remove it so it can't shadow the APT-managed SDK.
  if [[ "$(readlink /usr/bin/dotnet 2>/dev/null)" == /usr/share/dotnet/dotnet ]] \
     && ! dpkg -S /usr/bin/dotnet >/dev/null 2>&1; then
    info "Removing script-installed .NET from /usr/share/dotnet…"
    sudo rm -f /usr/bin/dotnet
    sudo rm -rf /usr/share/dotnet
  fi

  local pkg
  pkg="$(latest_lts_dotnet_sdk_pkg)"
  if [[ -z "$pkg" ]]; then
    info "No .NET LTS SDK in the distro archive; adding the Ubuntu .NET backports PPA…"
    sudo add-apt-repository -y ppa:dotnet/backports
    "${APT_GET[@]}" update
    pkg="$(latest_lts_dotnet_sdk_pkg)"
  fi
  if [[ -z "$pkg" ]]; then
    error "No .NET LTS SDK package available from APT."
    return 1
  fi

  apt_install "$pkg"
  info "Installed $pkg ($(dotnet --version)); it updates through APT."

  # Keep only the latest LTS: remove any other SDK versions (older LTS or STS).
  local others=()
  mapfile -t others < <(dpkg-query -W -f='${Package} ${Status}\n' 'dotnet-sdk-*' 2>/dev/null \
    | awk -v keep="$pkg" '/install ok installed/ && $1 != keep && $1 ~ /^dotnet-sdk-[0-9]+\.[0-9]+$/ {print $1}')
  if (( ${#others[@]} )); then
    info "Removing other .NET SDKs: ${others[*]}"
    "${APT_GET[@]}" purge "${others[@]}"
  fi
}

install_monogame_templates() {
  if ! exists dotnet; then
    warn ".NET SDK not found; skipping MonoGame templates."
    return 0
  fi

  local installed
  installed="$(dotnet new uninstall)"
  if grep -q 'MonoGame.Templates.CSharp' <<<"$installed"; then
    dotnet new update
  else
    dotnet new install MonoGame.Templates.CSharp
  fi
}

install_vscode() {
  local sources=/etc/apt/sources.list.d/vscode.sources

  # Earlier versions of this script registered the repo by hand under these names; the
  # code package now manages its own repo entry, and two entries make apt complain.
  if [[ -f /etc/apt/sources.list.d/vscode.list ]] && grep -q ms_vscode.gpg /etc/apt/sources.list.d/vscode.list; then
    sudo rm -f /etc/apt/sources.list.d/vscode.list /usr/share/keyrings/ms_vscode.gpg
    info "Removed legacy hand-made VS Code repo entry."
  fi

  if is_pkg_installed code && [[ -f "$sources" ]]; then
    info "VS Code already installed; it updates through APT."
    return 0
  fi

  local os
  case "$(dpkg --print-architecture)" in
    amd64) os=linux-deb-x64 ;;
    arm64) os=linux-deb-arm64 ;;
    *)     error "Unsupported architecture for VS Code: $(dpkg --print-architecture)"; return 1 ;;
  esac

  # Microsoft's documented route: install the .deb and let it register its own APT repo.
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=$os" -o "$tmp/code.deb"
  echo "code code/add-microsoft-repo boolean true" | sudo debconf-set-selections
  apt_install --reinstall "$tmp/code.deb"
  rm -rf "$tmp"

  if [[ ! -f "$sources" ]]; then
    warn "VS Code installed, but its APT repo ($sources) wasn't registered; it won't update with the system."
  fi
}

configure_vscode() {
  if ! exists code; then
    warn "VS Code not found; skipping extensions and settings."
    return 0
  fi

  local installed ext
  installed="$(code --list-extensions | tr '[:upper:]' '[:lower:]')"

  for ext in "${RETIRED_VSCODE_EXTENSIONS[@]}"; do
    if grep -qx "${ext,,}" <<<"$installed"; then
      code --uninstall-extension "$ext" || warn "Could not uninstall $ext."
    fi
  done

  while read -r ext; do
    code --install-extension "$ext" || warn "Could not install $ext."
  done < <(read_list vscode-extensions.txt)

  # Merge (not overwrite) settings and keybindings; changed files get a timestamped backup.
  # The removed keys are from earlier versions of this script's settings.
  pyhelper merge-json "$VSCODE_USER_DIR/settings.json" "$RESOURCES_DIR/vscode-settings.json" \
    --remove editor.defaultFormatter \
    --remove csharpOrganizeUsings.sortOrder \
    --remove csharpOrganizeUsings.splitGroups
  pyhelper merge-keybindings "$VSCODE_USER_DIR/keybindings.json" "$RESOURCES_DIR/vscode-keybindings.json" \
    --remove-command csharp-organize-usings.organize
}

# =============================================================================
#  3) DESKTOP INTEGRATION
# =============================================================================
configure_favorites() {
  edit_favorites --append code.desktop
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
  init_setup "mint-developer-setup"

  log "==== 1) SYSTEM UPDATE ===="
  begin_setup

  log "==== 2) DEVELOPER TOOLS ===="
  run_step "Installing git" install_git
  run_step "Installing .NET SDK" install_dotnet_sdk
  run_step "Installing MonoGame templates" install_monogame_templates
  run_step "Installing VS Code" install_vscode
  run_step "Configuring VS Code" configure_vscode
  run_step "Installing Flatpak apps" install_flatpaks flatpaks-developer.txt

  log "==== 3) DESKTOP INTEGRATION ===="
  run_step "Adding VS Code to menu favorites" configure_favorites

  finish_setup
}
main "$@"
