#!/usr/bin/env bash
# =============================================================================
#    Linux Mint Cinnamon — General Setup
#
#  For every new user after a fresh Linux Mint Cinnamon install. Safe to re-run.
#
#  1) System update, prerequisites, automatic updates
#  2) Fonts
#  3) App installs
#     • Brave - Web Browser (replaces Firefox)
#     • LibreOffice - Office Suite (Flatpak, replaces distro build)
#     • Joplin - Note-Taking
#     • MDHero - Markdown Editor (default for .md)
#     • BleachBit - System Cleaner
#     • Bitwarden - Password Vault
#     • Flameshot - Screenshot Utility
#     • FreeCAD - Parametric CAD
#     • Inkscape - Vector Graphics
#     • Krita - Raster Art
#     • Kdenlive - Video Editing
#     • OBS - Screen Recording
#  4) App configurations
#  5) "Rice" - Themes & Aesthetics
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
  exec bash "$REPO_TMP/scripts/mint-general-setup.sh" "$@"
fi

# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: mint-general-setup.sh [--help]

General Linux Mint Cinnamon setup for any user. Safe to re-run.
Set WORKSTATION_REF=<branch|tag> to run resources from a branch other than main.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    *)         error "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

# Pinned upstream sources. Catppuccin GTK and Neofetch are archived upstream; see readme.
CATPPUCCIN_GTK_URL="https://raw.githubusercontent.com/catppuccin/gtk/v1.0.3/install.py"
CATPPUCCIN_TERMINAL_URL="https://raw.githubusercontent.com/catppuccin/gnome-terminal/v1.0.0/install.py"
CATPPUCCIN_TERMINAL_FRAPPE_UUID="71a9971e-e829-43a9-9b2f-4565c855d664"   # from install.py v1.0.0
CATPPUCCIN_XED_URL="https://raw.githubusercontent.com/catppuccin/xed/88807d183516438935629afe00636956bdc3ba1c/src/frappe.xml"
NEOFETCH_URL="https://raw.githubusercontent.com/dylanaraps/neofetch/7.1.0/neofetch"

GTK_THEME_NAME="catppuccin-frappe-blue-standard+default"
JOPLIN_DESKTOP="appimagekit-joplin.desktop"
MDHERO_DESKTOP="MDHero.desktop"
LIBREOFFICE_USER_DIR="$HOME/.var/app/org.libreoffice.LibreOffice/config/libreoffice/4/user"

# =============================================================================
#  2) FONTS
# =============================================================================
install_fonts() {
  # Microsoft core fonts + Carlito/Caladea (Calibri/Cambria metric-compatible) for
  # document compatibility; Inter + JetBrains Mono for the desktop.
  echo "ttf-mscorefonts-installer msttcorefonts/accept-mscorefonts-eula select true" \
    | sudo debconf-set-selections
  apt_install ttf-mscorefonts-installer fonts-crosextra-carlito fonts-crosextra-caladea \
    fonts-inter fonts-jetbrains-mono

  # Earlier versions of this script hand-copied the MS fonts here; the package owns them now.
  local legacy_dir=/usr/local/share/fonts/truetype/msttcorefonts2
  if [[ -d "$legacy_dir" ]] && compgen -G "/usr/share/fonts/truetype/msttcorefonts/*.ttf" >/dev/null; then
    sudo rm -rf "$legacy_dir"
    info "Removed legacy font copy at $legacy_dir."
  fi

  sudo fc-cache -f
}

# =============================================================================
#  3) APP INSTALLS
# =============================================================================
install_brave() {
  if is_pkg_installed brave-browser; then
    info "Brave already installed; it updates through APT."
  else
    # Official installer: adds Brave's APT repo and installs brave-browser.
    curl -fsS https://dl.brave.com/install.sh | sh
  fi
  is_pkg_installed brave-browser
}

remove_firefox() {
  if ! is_pkg_installed brave-browser; then
    warn "Brave isn't installed; keeping Firefox so this machine still has a browser."
    return 0
  fi
  purge_matching 'firefox*'

  if [[ -d "$HOME/.mozilla" ]]; then
    local backup
    backup="$HOME/.mozilla.bak.$(date +%Y%m%d-%H%M%S)"
    mv "$HOME/.mozilla" "$backup"
    info "Backed up existing Firefox profile to $backup"
  fi
}

remove_distro_libreoffice() {
  if ! flatpak info org.libreoffice.LibreOffice >/dev/null 2>&1; then
    warn "LibreOffice Flatpak isn't installed; keeping the distro LibreOffice."
    return 0
  fi
  purge_matching 'libreoffice*'
}

install_joplin() {
  # The Joplin AppImage needs FUSE 2 (libfuse2t64 on newer Ubuntu bases).
  if apt_has_candidate libfuse2t64; then
    apt_install libfuse2t64
  else
    apt_install libfuse2
  fi
  # Official install/update script; re-running it updates Joplin.
  curl -fsSL https://raw.githubusercontent.com/laurent22/joplin/dev/Joplin_install_and_update.sh | bash
}

install_mdhero() {
  # Official .deb from the project's GitHub releases (no APT repo); re-running installs the latest release.
  local arch url tmp
  arch="$(dpkg --print-architecture)"
  url="$(curl -fsSL https://api.github.com/repos/vaibhav-kakde-in/mdhero/releases/latest \
    | grep -oE "\"browser_download_url\": *\"[^\"]*_${arch}\.deb\"" | head -n1 | cut -d'"' -f4)"
  if [[ -z "$url" ]]; then
    error "No MDHero .deb found for $arch."
    return 1
  fi
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/mdhero.deb"
  apt_install "$tmp/mdhero.deb"
  rm -rf "$tmp"
  is_pkg_installed md-hero
}

install_bleachbit() {
  apt_install bleachbit

  local cfg="$HOME/.config/bleachbit/bleachbit.ini"
  mkdir -p "$(dirname "$cfg")"
  if [[ -f "$cfg" ]]; then
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  cp "$RESOURCES_DIR/bleachbit.ini" "$cfg"
  info "BleachBit defaults written to $cfg."
}

# =============================================================================
#  4) APP CONFIGURATIONS
# =============================================================================
configure_brave() {
  if ! is_pkg_installed brave-browser; then
    warn "Brave isn't installed; skipping Brave configuration."
    return 0
  fi

  xdg-settings set default-web-browser brave-browser.desktop
  info "Brave set as the default web browser."

  # First-run preferences for new Brave profiles.
  # https://www.chromium.org/administrators/configuring-other-preferences/
  # TODO: The theme extension doesn't install yet; possibly https://issues.chromium.org/issues/432502916
  sudo install -m 644 "$RESOURCES_DIR/brave-initial-preferences.json" /opt/brave.com/brave/initial_preferences
  info "Brave initial_preferences written."

  # Swap Firefox for Brave in the panel's pinned apps (every grouped-window-list instance).
  local cfg found=false
  for cfg in "$HOME"/.config/cinnamon/spices/grouped-window-list@cinnamon.org/*.json; do
    [[ -f "$cfg" ]] || continue
    found=true
    pyhelper pin-apps "$cfg" --replace-prefix firefox --with brave-browser.desktop
  done
  if [[ "$found" == false ]]; then
    warn "No grouped-window-list config found (log in to Cinnamon once first); Brave not pinned."
  fi
}

configure_libreoffice() {
  # Tabbed ("notebookbar") UI for Writer, Calc, Impress and Draw.
  pyhelper xcu-merge "$LIBREOFFICE_USER_DIR/registrymodifications.xcu" \
    "$RESOURCES_DIR/libreoffice-tabbed-ui.xcu"
  # Left behind by earlier versions of this script.
  rm -f "$HOME/.configure-libreoffice-ui.sh"
}

configure_mdhero() {
  if ! is_pkg_installed md-hero; then
    warn "MDHero isn't installed; leaving Markdown file associations alone."
    return 0
  fi
  xdg-mime default "$MDHERO_DESKTOP" text/markdown text/x-markdown
  info "MDHero is the default app for Markdown files."
}

configure_favorites() {
  # Files and Terminal are already pinned to the panel; Firefox is gone. Joplin goes in.
  edit_favorites --remove-contains nemo.desktop --remove-contains terminal \
    --remove-contains firefox --append "$JOPLIN_DESKTOP"
}

# =============================================================================
#  5) "RICE" — THEMES & AESTHETICS
# =============================================================================
set_wallpaper() {
  local wall_dir="$HOME/Pictures/Wallpapers"
  local wall_file="$wall_dir/Gnome-Desktop-851-Right-4K-No-Logo.jpg"

  mkdir -p "$wall_dir"
  cp "$REPO_ROOT/content/wallpapers/Gnome-Desktop-851-Right-4K-No-Logo.jpg" "$wall_file"
  gset org.cinnamon.desktop.background picture-uri "file://$wall_file"
  gset org.cinnamon.desktop.background picture-options 'stretched'
}

set_icon_theme() {
  # Earlier versions used the Papirus PPA; the distro package avoids PPA breakage on new Mint bases.
  if compgen -G "/etc/apt/sources.list.d/papirus-ubuntu-papirus-*" >/dev/null; then
    sudo add-apt-repository -y --remove ppa:papirus/papirus
  fi
  apt_install papirus-icon-theme
  gset org.cinnamon.desktop.interface icon-theme 'Papirus-Dark'
}

set_fonts() {
  gset org.cinnamon.desktop.interface font-name 'Inter 10'
  gset org.cinnamon.desktop.wm.preferences titlebar-font 'Inter Medium 10'
  # Cinnamon's "Monospace font" setting; the terminal profile follows it.
  gset org.gnome.desktop.interface monospace-font-name 'JetBrains Mono 10'
}

set_terminal_theme() {
  if ! exists gnome-terminal; then
    warn "GNOME Terminal not found; skipping Catppuccin terminal theme."
    return 0
  fi

  curl -fsSL "$CATPPUCCIN_TERMINAL_URL" | python3 - >/dev/null

  local profile="/org/gnome/terminal/legacy/profiles:/:$CATPPUCCIN_TERMINAL_FRAPPE_UUID/"
  if [[ -z "$(dconf read "${profile}visible-name")" ]]; then
    warn "Catppuccin Frappé terminal profile not found; leaving default profile unchanged."
    return 0
  fi
  dconf write /org/gnome/terminal/legacy/profiles:/default "'$CATPPUCCIN_TERMINAL_FRAPPE_UUID'"
  info "Catppuccin Frappé is the default GNOME Terminal profile."
}

set_gtk_theme() {
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "$CATPPUCCIN_GTK_URL" -o "$tmp/install.py"
  (cd "$tmp" && python3 install.py frappe blue >/dev/null)
  rm -rf "$tmp"

  gset org.cinnamon.desktop.interface gtk-theme "$GTK_THEME_NAME"
  gset org.cinnamon.theme name "$GTK_THEME_NAME"

  # Give Cinnamon's theme picker preview thumbnails for the new theme.
  local theme_dir="" base kind
  for base in "$HOME/.local/share/themes" "$HOME/.themes"; do
    if [[ -d "$base/$GTK_THEME_NAME" ]]; then theme_dir="$base/$GTK_THEME_NAME"; break; fi
  done
  if [[ -z "$theme_dir" ]]; then
    warn "Installed theme folder not found; skipping theme preview thumbnails."
    return 0
  fi
  for kind in cinnamon gtk-3.0; do
    if [[ -f "$theme_dir/$kind/thumbnail.png" && -d "/usr/share/cinnamon/thumbnails/$kind" ]]; then
      sudo cp "$theme_dir/$kind/thumbnail.png" "/usr/share/cinnamon/thumbnails/$kind/$GTK_THEME_NAME.png"
      info "Installed $kind preview thumbnail."
    fi
  done
}

set_text_editor_theme() {
  local style_dir="$HOME/.local/share/xed/styles"
  mkdir -p "$style_dir"
  curl -fsSL "$CATPPUCCIN_XED_URL" -o "$style_dir/frappe.xml"
  gset org.x.editor.preferences.editor scheme 'catppuccin-frappe'
}

set_dark_mode_preference() {
  # Which key Cinnamon/apps read has moved between releases, so set every one present.
  local schema did_set=false
  for schema in org.x.apps.portal org.cinnamon.desktop.interface org.gnome.desktop.interface; do
    if has_gsetting "$schema" color-scheme; then
      gset "$schema" color-scheme 'prefer-dark'
      did_set=true
    fi
  done
  if [[ "$did_set" == false ]]; then
    warn "No 'color-scheme' key found; leaving Dark Mode as-is."
  fi
}

tweak_desktop_prefs() {
  # Clock
  gset org.cinnamon.desktop.interface clock-use-24h false

  # Lock screen
  gset org.cinnamon.desktop.screensaver allow-media-control false
  gset org.cinnamon.desktop.screensaver show-album-art false
  gset org.cinnamon.desktop.screensaver floating-widgets false

  # Nemo
  gset org.nemo.preferences default-folder-viewer 'list-view'
  gset org.nemo.preferences executable-text-activation 'display'
  gset org.nemo.preferences show-reload-icon-toolbar true
  # TODO: Rename on double-click.

  # Window behavior
  gset org.cinnamon.muffin placement-mode 'center'
  gset org.cinnamon alttab-switcher-style 'timeline'
  # TODO: Open menu on hover.

  # Remove the Corner Bar applet from the panel
  local applets
  applets="$(pyhelper list-edit "$(gsettings get org.cinnamon enabled-applets)" \
    --remove-contains cornerbar@cinnamon.org)"
  gset org.cinnamon enabled-applets "$applets"

  # Top-left hot corner → Show all workspaces (expo)
  local corners
  corners="$(pyhelper list-set "$(gsettings get org.cinnamon hotcorner-layout)" \
    --index 0 --value 'expo:true:0' --length 4 --fill 'desktop:false:0')"
  gset org.cinnamon hotcorner-layout "$corners"
}

install_neofetch() {
  # Neofetch is archived upstream (pinned at 7.1.0); see readme for the planned replacement.
  if apt_has_candidate neofetch; then
    apt_install neofetch
  elif ! exists neofetch; then
    sudo curl -fsSL "$NEOFETCH_URL" -o /usr/local/bin/neofetch
    sudo chmod 755 /usr/local/bin/neofetch
  fi

  local marker="neofetch auto-launch (added by mint-workstation-setup)"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if grep -qF "$marker" "$rc"; then
      info "Neofetch auto-launch already in $(basename "$rc")."
    else
      cat >>"$rc" <<'EOF'

# >>> neofetch auto-launch (added by mint-workstation-setup) >>>
if command -v neofetch >/dev/null 2>&1; then
  case "$-" in
    *i*) neofetch ;;
  esac
fi
# <<< neofetch auto-launch <<<
EOF
      info "Added Neofetch auto-launch to $(basename "$rc")."
    fi
  done
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
  init_setup "mint-general-setup"

  log "==== 1) SYSTEM UPDATE ===="
  begin_setup

  log "==== 2) FONTS ===="
  run_step "Installing fonts" install_fonts

  log "==== 3) APP INSTALLS ===="
  run_step "Installing Brave" install_brave
  run_step "Removing Firefox" remove_firefox
  run_step "Installing Flatpak apps" install_flatpaks flatpaks-general.txt
  run_step "Removing distro LibreOffice" remove_distro_libreoffice
  run_step "Installing Joplin" install_joplin
  run_step "Installing MDHero" install_mdhero
  run_step "Installing BleachBit" install_bleachbit

  log "==== 4) APP CONFIGURATIONS ===="
  run_step "Configuring Brave" configure_brave
  run_step "Configuring LibreOffice" configure_libreoffice
  run_step "Configuring MDHero" configure_mdhero
  run_step "Configuring menu favorites" configure_favorites

  log "==== 5) RICE (THEMES & AESTHETICS) ===="
  run_step "Setting wallpaper" set_wallpaper
  run_step "Setting icon theme (Papirus)" set_icon_theme
  run_step "Setting fonts" set_fonts
  run_step "Setting terminal theme (Catppuccin Frappé)" set_terminal_theme
  run_step "Setting GTK/Cinnamon theme (Catppuccin Frappé)" set_gtk_theme
  run_step "Setting Xed theme (Catppuccin Frappé)" set_text_editor_theme
  run_step "Setting dark mode preference" set_dark_mode_preference
  run_step "Tweaking desktop preferences" tweak_desktop_prefs
  run_step "Installing Neofetch" install_neofetch

  finish_setup
}
main "$@"
