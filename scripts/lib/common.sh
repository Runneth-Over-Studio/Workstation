#!/usr/bin/env bash
# =============================================================================
#  Shared helpers for the Runneth Over Studio Linux Mint setup scripts.
#  Sourced by mint-general-setup.sh and mint-developer-setup.sh; not run directly.
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOURCES_DIR="$REPO_ROOT/scripts/resources"
FAILED_STEPS=()

# sudo resets the environment, so DEBIAN_FRONTEND has to be passed through explicitly.
# confdef/confold keep locally modified config files on re-runs instead of overwriting them.
APT_GET=(sudo DEBIAN_FRONTEND=noninteractive apt-get -y
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# ERR trap handler: report where a command failed.
on_err() { printf "\n\033[1;31m[ERR ]\033[0m %s:%s: %s\n" "${BASH_SOURCE[1]##*/}" "$1" "$BASH_COMMAND" >&2; }

# ----- output ----------------------------------------------------------------
log()   { printf "\n\033[1;36m[INFO]\033[0m %s\n" "$*"; }
info()  { printf "  • %s\n" "$*"; }
warn()  { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
rule()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ----- small predicates ------------------------------------------------------
exists() { command -v "$1" >/dev/null 2>&1; }

# dpkg -s also succeeds for removed-but-not-purged packages, so check the status field.
is_pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_has_candidate() {
  local candidate
  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

has_gsetting() {
  gsettings list-keys "$1" 2>/dev/null | grep -qx "$2"
}

# ----- actions ---------------------------------------------------------------
apt_install() { "${APT_GET[@]}" install "$@"; }

# Purge every installed package whose name matches a dpkg glob, e.g. 'firefox*'.
purge_matching() {
  local pkgs=()
  mapfile -t pkgs < <(dpkg-query -W -f='${Package} ${Status}\n' "$1" 2>/dev/null \
    | awk '/install ok installed/ {print $1}')
  if (( ${#pkgs[@]} )); then
    info "Purging: ${pkgs[*]}"
    "${APT_GET[@]}" purge "${pkgs[@]}"
  else
    info "Nothing installed matching '$1'."
  fi
}

# Set a gsettings key, warning (not failing) if this desktop doesn't have it.
gset() {
  if gsettings set "$1" "$2" "$3" 2>/dev/null; then
    info "$1 $2 → $3"
  else
    warn "Could not set $1 $2."
  fi
}

# Run the Python file/setting editors (see lib/helpers.py).
pyhelper() { python3 "$REPO_ROOT/scripts/lib/helpers.py" "$@"; }

# Print a resource list file without comments or blank lines.
read_list() { grep -Ev '^\s*(#|$)' "$RESOURCES_DIR/$1"; }

# Add/remove Cinnamon menu favorites. Args go straight to `helpers.py list-edit`.
edit_favorites() {
  local current updated
  current="$(gsettings get org.cinnamon favorite-apps)"
  updated="$(pyhelper list-edit "$current" "$@")"
  gset org.cinnamon favorite-apps "$updated"
}

install_flatpaks() {
  local apps=()
  mapfile -t apps < <(read_list "$1")
  sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  sudo flatpak install -y --noninteractive --or-update flathub "${apps[@]}"
}

# =============================================================================
#  Setup lifecycle
# =============================================================================
init_setup() {
  local name="$1"

  if [[ $EUID -eq 0 ]]; then
    error "Run this script as your regular user (with sudo rights), not as root."
    exit 1
  fi

  exec > >(tee -a "$HOME/$name.log") 2>&1
  trap 'on_err $LINENO' ERR

  if [[ ! -f /etc/linuxmint/info ]]; then
    warn "This doesn't look like Linux Mint; continuing anyway."
  fi

  if ! exists sudo || ! sudo -v; then
    error "Unable to obtain sudo privileges. Aborting."
    exit 1
  fi
  ( while true; do sleep 60; sudo -n true || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# Run one setup step in a subshell with errexit on. A failing step is reported
# and recorded, and the script moves on to the next one.
#
# (Calling a function from `if`/`||` would silently disable `set -e` inside it,
# so errexit is toggled around the subshell instead.)
run_step() {
  local title="$1" rc
  shift
  log "$title"

  trap - ERR
  set +e
  ( trap 'on_err $LINENO' ERR; set -e; "$@" )
  rc=$?
  set -e
  trap 'on_err $LINENO' ERR

  if (( rc != 0 )); then
    warn "Step failed (exit $rc): $title — continuing."
    FAILED_STEPS+=("$title")
  fi
}

system_update() {
  "${APT_GET[@]}" update
  "${APT_GET[@]}" -f install
  "${APT_GET[@]}" full-upgrade
  "${APT_GET[@]}" autoremove
}

install_prerequisites() {
  apt_install curl wget ca-certificates gnupg tar unzip jq python3 dconf-cli flatpak
}

# Mint's Update Manager can apply updates (including Flatpaks) and remove old
# kernels on a schedule; turning it on keeps machines current without re-running this.
enable_automatic_updates() {
  if ! exists mintupdate-automation; then
    warn "mintupdate-automation not found; enable automatic updates in Update Manager → Preferences."
    return 0
  fi
  sudo mintupdate-automation upgrade enable
  info "Automatic APT updates enabled."

  # Older Mint releases have a separate automation for removing obsolete kernels.
  if grep -q '"autoremove"' /usr/share/linuxmint/mintupdate/automation/index.json 2>/dev/null; then
    sudo mintupdate-automation autoremove enable
    info "Automatic removal of obsolete kernels enabled."
  fi

  # Automatic Flatpak updates are a separate, per-user Update Manager setting.
  if has_gsetting com.linuxmint.updates auto-update-flatpaks; then
    gset com.linuxmint.updates auto-update-flatpaks true
  else
    warn "Can't find Update Manager's Flatpak auto-update setting; enable it in Update Manager → Preferences."
  fi
}

# Shared opening steps; fatal on failure because everything else depends on them.
begin_setup() {
  log "Updating the system…"
  system_update
  log "Installing prerequisites…"
  install_prerequisites
  run_step "Enabling automatic updates" enable_automatic_updates
}

finish_setup() {
  run_step "Final package refresh" final_updates

  echo
  rule
  if (( ${#FAILED_STEPS[@]} )); then
    warn "Finished with ${#FAILED_STEPS[@]} failed step(s):"
    printf '   • %s\n' "${FAILED_STEPS[@]}"
    echo "   Details are in the log above. Fixing the cause and re-running the script is safe."
  else
    log "✅ Setup complete!"
  fi

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is REQUIRED to finish applying updates."
  else
    log "A reboot (or at least logging out and back in) is RECOMMENDED so all changes apply."
  fi
  rule

  [[ ${#FAILED_STEPS[@]} -eq 0 ]] || exit 1
}

final_updates() {
  system_update
  sudo flatpak update -y --noninteractive
}
