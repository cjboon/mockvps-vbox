#!/usr/bin/env bash
#
# mockvps-vbox.sh -- spin up a disposable Debian "VPS" locally with VirtualBox
#
# Boots an unattended, headless Debian install in VirtualBox and leaves you
# with a VM reachable over key-only SSH from this host only.
#
# Revised version. Compared with the original it:
#   * never force-kills libvirt/KVM VMs (KVM is only touched with --stop-kvm,
#     and then only after a graceful ACPI shutdown),
#   * only installs VirtualBox when it is missing (apt-based hosts only),
#   * works with an existing VirtualBox on any x86_64 Linux host,
#   * exits non-zero when the install fails or times out,
#   * verifies the Debian ISO (SHA512SUMS + GPG signature),
#   * uses a SATA controller, compares port *and* IP of the NAT rule,
#     clears stale known_hosts entries, replaces the TCP serial listener with
#     a log file, and supports extra SSH tunnels (-f/--forward),
#   * can remove everything it created again (--uninstall, with a --dry-run
#     preview, and --keep-iso to keep the downloaded ISO).
#
# Security model:
#   * The NAT port-forward is bound to 127.0.0.1 -- other machines on the LAN
#     cannot reach the guest.
#   * No network listener for the serial console (--serial logs to a file).
#   * A random guest password is generated once and stored 0600 in
#     "$WORKDIR/credentials/<name>.env". SSH uses a dedicated Ed25519 key and
#     password authentication is disabled in the guest.
#
# Usage:
#   ./mockvps-vbox.sh               # install (typically 10-20 min) + wait for SSH
#   ./mockvps-vbox.sh --help        # all flags
#
# Exit codes: 0 ok, 1 error, 2 install did not complete (VM powered off or
#             SSH timeout), 3 VM is up but key login failed.

set -euo pipefail

# Debian CD signing keys (https://www.debian.org/CD/verify). Space-separated
# primary-key fingerprints; add more with --cd-key-fpr.
DEFAULT_CD_KEY_FPRS="10460DAD76165AD81FBC0CE9988021A964E6EA7D DF9B9C49EAA9298432589D76DA87E80D6294BE9B"
CD_KEY_SERVERS="hkps://keyring.debian.org hkps://keyserver.ubuntu.com"

### Helpers ###########################################################

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# is_uint VALUE MIN MAX -- decimal integer in range (leading zeros are fine)
is_uint() { [[ "$1" =~ ^[0-9]{1,9}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  [[ -t 0 ]] || die "Confirmation needed ('$1') but stdin is not a terminal; re-run with -y."
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

usage() {
  cat <<'EOF'
usage: mockvps-vbox.sh [options]

Set up a disposable Debian server "VPS" locally in VirtualBox: unattended
install (typically 10-20 minutes), key-only SSH reachable from this host
only, no GUI. Afterwards:  ssh <name>

Requires an x86_64 Linux host. If VirtualBox (7.x) is missing, the script
offers to install it -- on apt-based hosts (Debian/Ubuntu/derivatives) only;
elsewhere install VirtualBox yourself first.

options:
  -h, --help            show this help and exit
  -y, --yes             non-interactive; confirms prompts (reinstalls an
                        existing VM; shuts libvirt VMs down gracefully if
                        --stop-kvm is also given)
  -n, --name NAME       VM name (default: mockvps-vbox)
  -u, --user USER       guest user (default: vps)
  -p, --port PORT       host port of the SSH forward (default: 2222)
  -c, --cpus N          guest vCPUs (default: 2)
  -m, --memory MIB      guest RAM in MiB (default: 2048)
  -d, --disk MB         guest disk size in MB (default: 20000)
  -w, --workdir DIR     state directory (default: ~/vps)
  -i, --iso-url URL|FILE  Debian netinst ISO: a URL or a local file
                        (default: latest, auto-detected and verified)
  -f, --forward L:G     also tunnel host port L to guest port G over SSH
                        (repeatable; L must be 1024-65535), e.g. -f 8443:443
  -k, --ip IP           bind the NAT forward to this IPv4 address (default
                        127.0.0.1; only change this if you know why)
  --manual              boot the interactive installer (GUI) instead
  --serial              log the guest serial console to
                        <workdir>/<name>-serial.log (no network listener)
  --stop-kvm            unload KVM so VirtualBox can run. libvirt VMs are
                        shut down gracefully, never force-killed
  --require-signature   fail if the ISO checksum file's GPG signature cannot
                        be verified (default: warn and rely on the checksum)
  --cd-key-fpr FPR      accept this additional Debian CD signing key
  --no-web-tunnel       do not add the default 8080 -> guest:80 tunnel

uninstall mode:
  --uninstall           remove every trace of the VM: registration, disk,
                        keys, credentials, the ssh config block and the
                        workdir files (ISO too, unless --keep-iso). The
                        repo itself and the VirtualBox packages are kept.
                        With -y it also powers off a running VM gracefully.
  --dry-run             only with --uninstall: list what would be removed
  --keep-iso            only with --uninstall: keep the downloaded Debian ISO

Every option has an environment-variable equivalent (VM_NAME, VM_USER,
SSH_HOST_PORT, VM_VCPUS, VM_MEMORY, VM_DISK_SIZE_MB, WORKDIR, ISO_URL,
SSH_HOST_IP, MANUAL, SERIAL, STOP_KVM, REQUIRE_SIG, WEB_TUNNEL=0|1,
UNINSTALL=1, DRY_RUN=1, KEEP_ISO=1, FORWARDS="8443:443,3000:3000"); flags win.
EOF
}

### Configuration #####################################################

init_defaults() {
  VM_NAME="${VM_NAME:-mockvps-vbox}"
  VM_VCPUS="${VM_VCPUS:-2}"
  VM_MEMORY="${VM_MEMORY:-2048}"            # MiB
  VM_DISK_SIZE_MB="${VM_DISK_SIZE_MB:-20000}"
  VM_USER="${VM_USER:-vps}"
  WORKDIR="${WORKDIR:-$HOME/vps}"
  SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
  SSH_HOST_IP="${SSH_HOST_IP:-127.0.0.1}"
  ISO_URL="${ISO_URL:-}"
  CDIMAGE_BASE="${CDIMAGE_BASE:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"
  CD_KEY_FPRS="${CD_KEY_FPRS:-$DEFAULT_CD_KEY_FPRS}"
  MANUAL="${MANUAL:-0}"
  SERIAL="${SERIAL:-0}"
  STOP_KVM="${STOP_KVM:-0}"
  REQUIRE_SIG="${REQUIRE_SIG:-0}"
  UNINSTALL="${UNINSTALL:-0}"
  DRY_RUN="${DRY_RUN:-0}"
  KEEP_ISO="${KEEP_ISO:-0}"
  WEB_TUNNEL="${WEB_TUNNEL:-1}"
  FORWARDS="${FORWARDS:-}"
  REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
  ASSUME_YES=0
  EXTRA_FORWARDS=()
  FORWARD_LIST=()
  REINSTALL=1
  KVM_RESTORE_HINT=""
  ISO_FILE=""
  ISO_LOCAL=0
  AUTO_ISO=0
  PRESEED_FILE=""
}

need_arg() { [[ $2 -ge 2 ]] || die "option $1 requires an argument"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -n|--name) need_arg "$1" $#; VM_NAME="$2"; shift 2 ;;
      -u|--user) need_arg "$1" $#; VM_USER="$2"; shift 2 ;;
      -p|--port) need_arg "$1" $#; SSH_HOST_PORT="$2"; shift 2 ;;
      -c|--cpus) need_arg "$1" $#; VM_VCPUS="$2"; shift 2 ;;
      -m|--memory) need_arg "$1" $#; VM_MEMORY="$2"; shift 2 ;;
      -d|--disk) need_arg "$1" $#; VM_DISK_SIZE_MB="$2"; shift 2 ;;
      -w|--workdir) need_arg "$1" $#; WORKDIR="$2"; shift 2 ;;
      -i|--iso-url) need_arg "$1" $#; ISO_URL="$2"; shift 2 ;;
      -f|--forward) need_arg "$1" $#; EXTRA_FORWARDS+=("$2"); shift 2 ;;
      -k|--ip) need_arg "$1" $#; SSH_HOST_IP="$2"; shift 2 ;;
      --cd-key-fpr) need_arg "$1" $#; CD_KEY_FPRS="$CD_KEY_FPRS $2"; shift 2 ;;
      --manual) MANUAL=1; shift ;;
      --serial) SERIAL=1; shift ;;
      --stop-kvm) STOP_KVM=1; shift ;;
      --require-signature) REQUIRE_SIG=1; shift ;;
      --no-web-tunnel) WEB_TUNNEL=0; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --keep-iso) KEEP_ISO=1; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1 (try --help)" ;;
      *) die "unexpected argument: $1 (no positional parameters; try --help)" ;;
    esac
  done
  [[ $# -eq 0 ]] || die "unexpected argument(s) after '--': $* (try --help)"
}

check_forward() {
  local lp gp
  [[ "$1" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] \
    || die "invalid forward '$1' (expected LOCALPORT:GUESTPORT, e.g. 8443:443)"
  lp="${BASH_REMATCH[1]}"; gp="${BASH_REMATCH[2]}"   # is_uint clobbers BASH_REMATCH
  is_uint "$lp" 1024 65535 || die "forward '$1': local port must be 1024-65535"
  is_uint "$gp" 1 65535    || die "forward '$1': guest port must be 1-65535"
}

build_forwards() {
  local f lp seen=" " envf=()
  FORWARD_LIST=()
  if [[ "$WEB_TUNNEL" != "0" ]]; then FORWARD_LIST+=("8080:80"); fi
  if [[ -n "$FORWARDS" ]]; then
    IFS=',' read -r -a envf <<<"$FORWARDS"
    for f in "${envf[@]}"; do FORWARD_LIST+=("$f"); done
  fi
  for f in ${EXTRA_FORWARDS[@]+"${EXTRA_FORWARDS[@]}"}; do FORWARD_LIST+=("$f"); done
  for f in ${FORWARD_LIST[@]+"${FORWARD_LIST[@]}"}; do
    check_forward "$f"
    lp=$((10#${f%%:*}))
    [[ "$seen" != *" $lp "* ]] || die "local port $lp is used by more than one forward"
    seen+="$lp "
  done
}

validate_config() {
  [[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
    || die "VM_NAME must be 1-64 chars [A-Za-z0-9_.-] and not start with - or . (got '$VM_NAME')"
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
    || die "VM_USER must be a lowercase POSIX user name (got '$VM_USER')"
  is_uint "$SSH_HOST_PORT" 1 65535 || die "SSH_HOST_PORT must be 1-65535 (got '$SSH_HOST_PORT')"
  is_uint "$VM_VCPUS" 1 32 || die "VM_VCPUS must be 1-32 (got '$VM_VCPUS')"
  is_uint "$VM_MEMORY" 512 131072 || die "VM_MEMORY (MiB) must be 512-131072 (got '$VM_MEMORY')"
  is_uint "$VM_DISK_SIZE_MB" 4000 2097152 || die "VM_DISK_SIZE_MB must be 4000-2097152 (got '$VM_DISK_SIZE_MB')"
  [[ "$SSH_HOST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || die "SSH_HOST_IP must be an IPv4 address (got '$SSH_HOST_IP')"
  [[ "$CD_KEY_FPRS" =~ ^[0-9A-Fa-f\ ]+$ ]] || die "CD key fingerprints must be hex (got '$CD_KEY_FPRS')"
  SSH_HOST_PORT=$((10#$SSH_HOST_PORT))
  build_forwards
  if [[ "$SSH_HOST_IP" != 127.* ]]; then
    warn "NAT forward bound to $SSH_HOST_IP -- SSH will be reachable from OTHER MACHINES. Use a host firewall."
    confirm "Proceed with a non-loopback bind?" || die "aborted by user"
  fi
}

derive_paths() {
  DISK="$WORKDIR/$VM_NAME.vdi"
  CRED_DIR="$WORKDIR/credentials"
  CRED_FILE="$CRED_DIR/$VM_NAME.env"
  KEY_FILE="$HOME/.ssh/${VM_NAME}_id"
  SERIAL_LOG="$WORKDIR/${VM_NAME}-serial.log"
  SSH_BEGIN="# BEGIN mockvps-vbox:$VM_NAME (managed by mockvps-vbox.sh)"
  SSH_END="# END mockvps-vbox:$VM_NAME"
  SSH_LEGACY="# $VM_NAME (managed by mockvps-vbox.sh)"   # block format of the original script
  # Hostnames cannot contain '_' or '.' labels we did not intend; keep it simple.
  GUEST_HOST="$(printf '%s' "$VM_NAME" | LC_ALL=C tr 'A-Z_.' 'a-z--')"
}

### VirtualBox plumbing ###############################################

module_loaded() { grep -q '^vboxdrv ' /proc/modules; }

# startvm/unattended need /dev/vboxdrv access (group vboxusers). Handles the
# stale-shell case (just added to the group, not re-logged in) via sg.
run_vbox() {
  if [[ $EUID -eq 0 ]] || id -nG | grep -qw vboxusers; then
    "$@"
  else
    sg vboxusers -c "$(printf '%q ' "$@")"
  fi
}
vb() { run_vbox VBoxManage "$@"; }

vm_exists() { vb list vms 2>/dev/null | grep -Fq "\"$VM_NAME\""; }

vm_state() {
  vb showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
    awk -F'=' '/^VMState=/ { gsub(/"/, "", $2); print $2 }' || true
}

wait_poweroff() {
  local i
  for ((i = 0; i < 15; i++)); do
    case "$(vm_state)" in poweroff | aborted | "") return 0 ;; esac
    sleep 2
  done
  return 1
}

remove_vm() {
  case "$(vm_state)" in
    saved) vb discardstate "$VM_NAME" || true ;;
    running | paused | stuck | gurumeditation)
      vb controlvm "$VM_NAME" acpipowerbutton 2>/dev/null || true
      wait_poweroff || vb controlvm "$VM_NAME" poweroff || true
      wait_poweroff || true
      ;;
  esac
  vb unregistervm "$VM_NAME" --delete
}

have_apt() { command -v apt-get >/dev/null 2>&1 && [[ -r /etc/os-release ]]; }

install_virtualbox_apt() {
  local codename id_like cand repo="" pkg="" c candidates=()
  as_root apt-get update
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y wget gnupg ca-certificates

  codename="$(. /etc/os-release; printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  id_like="$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  if [[ -z "$codename" ]] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi
  [[ -n "$codename" ]] || die "Could not detect the distribution codename."

  # Oracle's repo is split per codename; probe it and fall back to a close one.
  candidates=("$codename")
  case " $id_like " in
    *" ubuntu "*) candidates+=(noble jammy) ;;
    *)            candidates+=(bookworm) ;;
  esac
  for cand in "${candidates[@]}"; do
    # Oracle's Release files ship 'Codename:' but no 'Suite:' line.
    if wget -qO- --timeout=30 "https://download.virtualbox.org/virtualbox/debian/dists/$cand/Release" |
        grep -q "^Codename: $cand$"; then
      repo="$cand"
      break
    fi
  done
  [[ -n "$repo" ]] || die "Oracle's VirtualBox repo is unreachable or has no release for '$codename'."
  if [[ "$repo" != "$codename" ]]; then log "Using Oracle repo branch '$repo' for codename '$codename'"; fi

  wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc |
    as_root gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $repo contrib" |
    as_root tee /etc/apt/sources.list.d/virtualbox.list >/dev/null
  as_root apt-get update

  for c in virtualbox-7.2 virtualbox-7.1 virtualbox-7.0; do
    cand="$(apt-cache policy "$c" 2>/dev/null | awk '/^ *Candidate:/ { print $2 }')"
    if [[ -n "$cand" && "$cand" != "(none)" ]]; then pkg="$c"; break; fi
  done
  [[ -n "$pkg" ]] || die "No VirtualBox 7.x package available from Oracle's repo for this distro."

  log "Installing $pkg (+ DKMS and kernel headers for the host module)"
  as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "$pkg" dkms "linux-headers-$(uname -r)" build-essential \
    || die "VirtualBox install failed."
}

ensure_virtualbox() {
  local ver major
  if ! command -v VBoxManage >/dev/null 2>&1; then
    have_apt || die "VirtualBox is not installed, and automatic install only supports apt-based hosts.
Install VirtualBox 7.x with your package manager (or from virtualbox.org) and re-run."
    confirm "VirtualBox is not installed. Add Oracle's apt repository and install it (uses sudo)?" \
      || die "VirtualBox is required; aborted."
    install_virtualbox_apt
  fi
  ver="$(VBoxManage --version 2>/dev/null | head -n1 || true)"
  major="${ver%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]]; then
    (( major >= 7 )) || die "VirtualBox $ver is too old; this script needs 7.0 or newer."
  else
    warn "Could not parse the VirtualBox version ('$ver'); continuing."
  fi
  log "Using VirtualBox ${ver:-unknown}"
}

ensure_vboxusers() {
  getent group vboxusers >/dev/null || as_root groupadd vboxusers
  if ! id -nG "$REAL_USER" | grep -qw vboxusers; then
    log "Adding $REAL_USER to the vboxusers group"
    as_root usermod -aG vboxusers "$REAL_USER"
  fi
}

# vboxconfig can regenerate 60-vboxdrv.rules as root:root 0600, locking out
# non-root users. Normalize to the standard layout.
fix_udev_rules() {
  local rule="/etc/udev/rules.d/60-vboxdrv.rules"
  [[ -f "$rule" ]] || return 0
  if ! as_root grep -q 'GROUP="vboxusers"' "$rule"; then
    log "Normalizing /dev/vboxdrv permissions in $rule"
    as_root sed -i 's/GROUP="root"/GROUP="vboxusers"/g; s/MODE="0600"/MODE="0660"/g' "$rule"
    as_root udevadm control --reload || true
    as_root udevadm trigger /sys/class/misc/vboxdrv /sys/class/misc/vboxdrvu /sys/class/misc/vboxnetctl || true
  fi
}

ensure_vbox_host() {
  local i
  # Try the cheap thing first; vboxconfig stops/rebuilds modules and is only
  # worth running when the module for this kernel is really missing.
  if ! module_loaded; then as_root modprobe vboxdrv 2>/dev/null || true; fi
  if ! module_loaded && [[ -x /sbin/vboxconfig ]]; then
    log "vboxdrv is not available for $(uname -r) -- running vboxconfig (one-time build, a few minutes)"
    as_root /sbin/vboxconfig || warn "vboxconfig exited non-zero"
    as_root modprobe vboxdrv 2>/dev/null || true
  fi
  for i in 1 2 3 4 5; do
    if module_loaded; then break; fi
    sleep 2
  done
  module_loaded || die "The vboxdrv kernel module is not loaded.
Try: sudo modprobe vboxdrv   (check 'sudo dmesg | tail -30').
If Secure Boot is enabled, the module must be signed/enrolled (MOK) first."
  ensure_vboxusers
  fix_udev_rules
}

### KVM coexistence (opt-in) ##########################################

kvm_loaded() { grep -q '^kvm[ _]' /proc/modules; }

libvirt_running_domains() {
  command -v virsh >/dev/null 2>&1 || return 0
  as_root virsh --connect qemu:///system list --name 2>/dev/null | sed '/^[[:space:]]*$/d' || true
}

# Never force-kills anything: libvirt guests get an ACPI shutdown and, if they
# do not stop, the script gives up and tells you.
stop_kvm() {
  local doms dom i mods
  mods="$(awk '$1 ~ /^kvm_(intel|amd)$/ { printf "%s ", $1 }' /proc/modules)"
  doms="$(libvirt_running_domains)"
  if [[ -n "$doms" ]]; then
    printf 'Running libvirt VMs that will be shut down gracefully:\n' >&2
    printf '  %s\n' $doms >&2
    confirm "Shut these VMs down (ACPI) and unload KVM?" || die "Aborted; nothing was changed."
    for dom in $doms; do
      as_root virsh --connect qemu:///system shutdown "$dom" >/dev/null 2>&1 || true
    done
    for ((i = 0; i < 60; i++)); do
      if [[ -z "$(libvirt_running_domains)" ]]; then break; fi
      sleep 2
    done
    [[ -z "$(libvirt_running_domains)" ]] \
      || die "libvirt VMs are still running after 2 minutes. Not force-killing them; shut them down yourself and re-run."
  else
    confirm "Unload the KVM kernel modules (VirtualBox cannot share VT-x/AMD-V with KVM)?" \
      || die "Aborted; nothing was changed."
  fi
  as_root systemctl stop libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
  as_root modprobe -r kvm_intel 2>/dev/null || as_root modprobe -r kvm_amd 2>/dev/null || true
  as_root modprobe -r kvm 2>/dev/null || true
  if kvm_loaded; then
    die "KVM modules are still in use (some process holds /dev/kvm). Close it and re-run."
  fi
  KVM_RESTORE_HINT="sudo modprobe ${mods:-kvm_intel} && sudo systemctl start libvirtd.socket"
}

### Credentials, keys, ISO ############################################

gen_password() {
  local pw
  while :; do
    pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 30)" || true
    if [[ ${#pw} -eq 30 ]]; then printf '%s' "$pw"; return 0; fi
  done
}

# env VM_PASSWORD > stored file > new random. Written with %q so any
# character survives being sourced back.
setup_credentials() {
  mkdir -p "$WORKDIR" "$CRED_DIR"
  chmod 700 "$CRED_DIR"
  if [[ -n "${VM_PASSWORD:-}" ]]; then
    log "Using VM_PASSWORD from the environment"
  elif [[ -f "$CRED_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CRED_FILE"
    if [[ -n "${VM_PASSWORD:-}" ]]; then
      log "Reusing the stored password in $CRED_FILE"
    else
      log "Credential file has no password -- generating a new one"
      VM_PASSWORD="$(gen_password)"
    fi
  else
    log "Generating a random guest password (stored in $CRED_FILE)"
    VM_PASSWORD="$(gen_password)"
  fi
  ( umask 077; printf 'VM_PASSWORD=%q\n' "$VM_PASSWORD" > "$CRED_FILE" )
  chmod 600 "$CRED_FILE"
}

ensure_host_key() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  if [[ ! -f "$KEY_FILE" ]]; then
    log "Generating dedicated SSH key for $VM_NAME: $KEY_FILE"
    ssh-keygen -q -t ed25519 -N "" -f "$KEY_FILE" -C "$VM_USER@$VM_NAME"
  fi
  chmod 600 "$KEY_FILE"
  chmod 644 "$KEY_FILE.pub"
}

sig_problem() {
  if [[ $REQUIRE_SIG -eq 1 ]]; then
    die "$1 (--require-signature given)"
  fi
  warn "$1 -- continuing with the SHA512 checksum check only."
}

# Verifies SHA512SUMS against SHA512SUMS.sign using the Debian CD signing keys.
verify_sums_signature() {
  local sums="$1" sig="$2" base="$3" gh fpr srv status signer allowed ok=0 got=0
  if ! wget -q -O "$sig" --timeout=30 "$base/SHA512SUMS.sign"; then
    sig_problem "Could not download SHA512SUMS.sign"; return 0
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    sig_problem "gpg is not installed, cannot check the signature"; return 0
  fi
  gh="$(mktemp -d)"; chmod 700 "$gh"
  for fpr in $CD_KEY_FPRS; do
    for srv in $CD_KEY_SERVERS; do
      if gpg --homedir "$gh" --batch --quiet --keyserver "$srv" --recv-keys "$fpr" >/dev/null 2>&1; then
        got=1; break
      fi
    done
  done
  if [[ $got -ne 1 ]]; then
    rm -rf "$gh"
    sig_problem "Could not fetch the Debian CD signing keys"; return 0
  fi
  if ! status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$sig" "$sums" 2>/dev/null)"; then
    rm -rf "$gh"
    die "BAD or unverifiable GPG signature on SHA512SUMS -- refusing to continue."
  fi
  rm -rf "$gh"
  # VALIDSIG's last field is the primary-key fingerprint.
  signer="$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status" | head -n1)"
  for allowed in $CD_KEY_FPRS; do
    if [[ "${signer^^}" == "${allowed^^}" ]]; then ok=1; fi
  done
  [[ $ok -eq 1 ]] || die "SHA512SUMS is validly signed, but by an unexpected key ($signer).
Check https://www.debian.org/CD/verify and, if that key is legitimate, re-run with --cd-key-fpr $signer"
  log "GPG signature on SHA512SUMS is valid (key $signer)"
}

verify_iso() {
  local base="${ISO_URL%/*}" name vdir sums sig expected actual
  name="$(basename "$ISO_FILE")"
  vdir="$WORKDIR/verify"; mkdir -p "$vdir"
  sums="$vdir/SHA512SUMS"; sig="$vdir/SHA512SUMS.sign"
  rm -f "$sums" "$sig"
  if ! wget -q -O "$sums" --timeout=30 "$base/SHA512SUMS"; then
    rm -f "$sums"
    if [[ $AUTO_ISO -eq 1 ]]; then die "Could not download $base/SHA512SUMS to verify the ISO."; fi
    warn "No SHA512SUMS next to the ISO URL -- the ISO is NOT verified."
    return 0
  fi
  expected="$(awk -v f="$name" '$2 == f { print $1 }' "$sums")"
  if [[ -z "$expected" ]]; then
    if [[ $AUTO_ISO -eq 1 ]]; then die "SHA512SUMS has no entry for $name."; fi
    warn "SHA512SUMS has no entry for $name -- the ISO is NOT verified."
    return 0
  fi
  verify_sums_signature "$sums" "$sig" "$base"
  log "Verifying SHA512 of $name"
  actual="$(sha512sum "$ISO_FILE" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$ISO_FILE"
    die "SHA512 mismatch for $name (corrupt or tampered download). The file was removed; re-run to download it again."
  fi
}

ensure_iso() {
  local listing latest
  if [[ -n "$ISO_URL" && -f "$ISO_URL" ]]; then
    ISO_FILE="$ISO_URL"; ISO_LOCAL=1
    warn "Using local ISO '$ISO_FILE' -- it is NOT verified."
    return 0
  fi
  if [[ -z "$ISO_URL" ]]; then
    AUTO_ISO=1
    listing="$(wget -qO- --timeout=30 "${CDIMAGE_BASE%/}/")" || listing=""
    latest="$(grep -oE 'debian-[0-9]+\.[0-9]+\.[0-9]+-amd64-netinst\.iso' <<<"$listing" | sort -uV | tail -n1)" || true
    [[ -n "$latest" ]] || die "Could not resolve the latest Debian netinst ISO. Pass -i URL or -i /path/to.iso."
    ISO_URL="${CDIMAGE_BASE%/}/$latest"
    log "Selected ISO: $ISO_URL"
  fi
  ISO_FILE="$WORKDIR/$(basename "$ISO_URL")"
  mkdir -p "$WORKDIR"
  if [[ ! -f "$ISO_FILE" ]]; then
    log "Downloading $(basename "$ISO_FILE")"
    rm -f "$ISO_FILE.part"
    wget -c -O "$ISO_FILE.part" "$ISO_URL" || {
      rm -f "$ISO_FILE.part"
      die "ISO download failed. Download it manually and re-run with -i /path/to/the.iso"
    }
    mv "$ISO_FILE.part" "$ISO_FILE"
  fi
  [[ -s "$ISO_FILE" ]] || die "ISO file is empty or missing: $ISO_FILE"
  verify_iso
}

### VM creation #######################################################

port_in_use() {
  command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$1" 2>/dev/null | grep -q .
}

check_port_free() {
  if port_in_use "$SSH_HOST_PORT"; then
    die "Host port $SSH_HOST_PORT is already in use. Pick another with -p/--port."
  fi
}

# Make sure the SSH forward matches $SSH_HOST_IP:$SSH_HOST_PORT -- live
# (controlvm) when the VM runs, persistent (modifyvm) otherwise. Idempotent.
ensure_nat_binding() {
  local line val cur_ip="" cur_port="" want
  want="SSH,tcp,${SSH_HOST_IP},${SSH_HOST_PORT},,22"
  line="$(vb showvminfo "$VM_NAME" --machinereadable 2>/dev/null | grep -F '="SSH,tcp,' || true)"
  if [[ -n "$line" ]]; then
    val="${line#*=\"}"; val="${val%\"*}"
    IFS=, read -r _ _ cur_ip cur_port _ <<<"$val"
    if [[ "$cur_ip" == "$SSH_HOST_IP" && "$cur_port" == "$SSH_HOST_PORT" ]]; then return 0; fi
    log "Updating SSH NAT rule: ${cur_ip:-<all interfaces>}:${cur_port} -> ${SSH_HOST_IP}:${SSH_HOST_PORT}"
  else
    log "No SSH NAT rule found -- adding ${SSH_HOST_IP}:${SSH_HOST_PORT}"
  fi
  if [[ "$(vm_state)" == "running" ]]; then
    if [[ -n "$line" ]]; then vb controlvm "$VM_NAME" natpf1 delete SSH 2>/dev/null || true; fi
    vb controlvm "$VM_NAME" natpf1 "$want"
  else
    if [[ -n "$line" ]]; then vb modifyvm "$VM_NAME" --nat-pf1 delete SSH 2>/dev/null || true; fi
    vb modifyvm "$VM_NAME" --nat-pf1 "$want"
  fi
}

# Older versions of the original script could leave a TCP serial listener on
# all interfaces. Turn it off if we find one.
secure_serial() {
  local mode
  mode="$(vb showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
    awk -F'=' '/^uartmode1=/ { gsub(/"/, "", $2); print $2 }' || true)"
  case "$mode" in *tcpserver*) ;; *) return 0 ;; esac
  if [[ "$(vm_state)" == "running" ]]; then
    warn "This VM has a serial TCP listener on ALL interfaces. Power it off
  (VBoxManage controlvm $VM_NAME acpipowerbutton) and re-run to disable it."
  else
    log "Disabling the TCP serial listener inherited from an older install"
    vb modifyvm "$VM_NAME" --uart1 off --uart-mode1 disconnected
  fi
}

create_vm() {
  local pf_rule="SSH,tcp,${SSH_HOST_IP},${SSH_HOST_PORT},,22"
  log "Creating VM: $VM_VCPUS vCPU(s), ${VM_MEMORY} MiB RAM, ${VM_DISK_SIZE_MB} MB disk"
  mkdir -p "$WORKDIR"
  vb createvm --name "$VM_NAME" --ostype Debian_64 --register

  # Boot the disk first: it is empty during the install (the BIOS falls
  # through to the ISO) and takes over automatically afterwards.
  vb modifyvm "$VM_NAME" \
    --cpus "$VM_VCPUS" --memory "$VM_MEMORY" --vram 16 --ioapic on \
    --audio-driver none \
    --boot1 disk --boot2 dvd --boot3 none --boot4 none \
    --nic1 nat --nat-pf1 "$pf_rule"
  if [[ "$SERIAL" == "1" ]]; then
    # Output goes to a file; there is no network listener.
    : > "$SERIAL_LOG"; chmod 600 "$SERIAL_LOG"
    vb modifyvm "$VM_NAME" --uart1 0x3f8 4 --uart-mode1 file "$SERIAL_LOG"
  fi

  if [[ -e "$DISK" ]]; then
    vb closemedium disk "$DISK" --delete 2>/dev/null || rm -f "$DISK"
  fi
  vb createmedium disk --filename "$DISK" --size "$VM_DISK_SIZE_MB" --format VDI
  vb storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 2
  vb storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$DISK"
  vb storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium emptydrive
}

find_vbox_template() {
  local d
  if [[ -n "${VBOX_PRESEED_TEMPLATE:-}" && -f "$VBOX_PRESEED_TEMPLATE" ]]; then
    printf '%s' "$VBOX_PRESEED_TEMPLATE"; return 0
  fi
  for d in /usr/share/virtualbox/UnattendedTemplates /usr/lib/virtualbox/UnattendedTemplates \
           /usr/lib64/virtualbox/UnattendedTemplates /opt/VirtualBox/UnattendedTemplates; do
    if [[ -f "$d/debian_preseed.cfg" ]]; then printf '%s' "$d/debian_preseed.cfg"; return 0; fi
  done
  return 1
}

# Sets PRESEED_FILE. Called directly (not via $(...)) so die() really aborts.
build_preseed_template() {
  local out tpl pubkey kopts latecmd merged value
  out="$WORKDIR/templates/debian_preseed.cfg"
  mkdir -p "$(dirname "$out")"
  chmod 700 "$(dirname "$out")"
  tpl="$(find_vbox_template)" || die "VirtualBox's debian_preseed.cfg template was not found (set VBOX_PRESEED_TEMPLATE)."
  cp "$tpl" "$out"

  # Pure ASCII, no quotes/backslashes, so it can be embedded as-is.
  pubkey="$(tr -d '\n' < "$KEY_FILE.pub")"
  case "$pubkey" in (*[![:print:]]*) die "public key contains non-printable characters" ;; esac

  # Single-line late command: install the pubkey, harden sshd to key-only.
  # It must contain no backslashes or quotes d-i's preseed parser could mangle.
  # The chown is numeric: d-i runs it in its own environment where the new
  # user's name does not resolve (a name-based chown silently no-ops and
  # sshd's StrictModes then rejects the key). Debian gives the first user 1000.
  latecmd="mkdir -p /target/home/${VM_USER}/.ssh; echo '${pubkey}' > /target/home/${VM_USER}/.ssh/authorized_keys; chown -R 1000:1000 /target/home/${VM_USER}/.ssh; chmod 700 /target/home/${VM_USER}/.ssh; chmod 600 /target/home/${VM_USER}/.ssh/authorized_keys; mkdir -p /target/etc/ssh/sshd_config.d; echo 'PasswordAuthentication no' > /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; echo 'PubkeyAuthentication yes' >> /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; grep -q '^Include' /target/etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /target/etc/ssh/sshd_config; true"
  [[ "$latecmd" == *\\* ]] && die "late_command contains backslashes"
  printf '%s' "$latecmd" | sh -n || die "late_command fails sh -n parse check"
  export AV_PUBKEY_LATECMD="$latecmd"

  # Global entries (openssh-server, kernel console, no tasksel) must sit
  # outside any @@VBOX_COND@@ block or VirtualBox's renderer strips them.
  # Console: VGA always; also the serial port when --serial is used.
  if [[ "$SERIAL" == "1" ]]; then kopts="console=tty0 console=ttyS0,115200n8"; else kopts="console=tty0"; fi
  sed -i -e '/^d-i pkgsel\/include/d' -e '/^d-i debian-installer\/add-kernel-opts/d' "$out"
  awk -v kopts="$kopts" '
    /^d-i pkgsel\/install-language-support/ {
      print
      print "d-i pkgsel/include string openssh-server"
      print "d-i debian-installer/add-kernel-opts string " kopts
      print "d-i pkgsel/run_tasksel boolean false"
      next
    }
    { print }
  ' "$out" > "$out.new" && mv "$out.new" "$out"
  awk '
    /^d-i pkgsel\/install-language-support/ { zone=1; next }
    /^@@VBOX/ { zone=0 }
    zone && /pkgsel\/include string openssh-server/ { ok1=1 }
    zone && /debian-installer\/add-kernel-opts string/ { ok2=1 }
    zone && /pkgsel\/run_tasksel boolean false/ { ok3=1 }
    END { exit !(ok1 && ok2 && ok3) }
  ' "$out" || die "pkgsel/add-kernel/run_tasksel entries not placed outside conditionals"

  # Merge our commands into the template's (possibly backslash-continued)
  # late_command, keeping VirtualBox's own post-install step.
  if grep -q '^d-i preseed/late_command' "$out"; then
    awk '
      /^d-i preseed\/late_command/ {
        val = $0
        sub(/^d-i preseed\/late_command string[ \t]*/, "", val)
        sub(/\\[ \t]*$/, "", val)
        while ((getline nxt) > 0) {
          cont = (nxt ~ /\\[ \t]*$/)
          sub(/\\[ \t]*$/, "", nxt)
          val = val " " nxt
          if (!cont) break
        }
        print "d-i preseed/late_command string " val " ; " ENVIRON["AV_PUBKEY_LATECMD"]
        next
      }
      { print }
    ' "$out" > "$out.new" && mv "$out.new" "$out"
  else
    printf 'd-i preseed/late_command string %s\n' "$latecmd" >> "$out"
  fi
  grep -q 'preseed/late_command' "$out" || die "late_command insertion into preseed failed"
  awk '/^d-i preseed\/late_command/ && found++ { exit 1 }' "$out" \
    || die "multiple preseed/late_command entries in preseed"

  merged="$(grep -E '^d-i preseed/late_command' "$out")"
  [[ "$merged" == *"$latecmd"* ]] || die "injected late_command not found in merged template"
  value="${merged#d-i preseed/late_command string }"
  [[ "$value" != "$merged" ]] || die "malformed late_command line in preseed"
  [[ "$value" == *\\* ]] && die "merged late_command contains backslashes"
  value="${value%; true}; true"
  printf '%s' "$value" | sh -n || die "merged late_command fails sh -n parse check"

  chmod 600 "$out"
  PRESEED_FILE="$out"
}

### SSH config ########################################################

# Writes (or replaces) this VM's managed block in ~/.ssh/config. Each VM gets
# its own BEGIN/END-delimited block, so several VMs (-n) never clobber each
# other. A backup is kept in ~/.ssh/config.mockvps.bak.
write_ssh_block() {
  local cfg="$HOME/.ssh/config" blockfile out f
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  touch "$cfg"; chmod 600 "$cfg"
  if grep -qxF "$SSH_BEGIN" "$cfg" && ! grep -qxF "$SSH_END" "$cfg"; then
    die "$cfg has a '$SSH_BEGIN' line but no matching END line; fix it by hand and re-run."
  fi
  cp -p "$cfg" "$cfg.mockvps.bak"

  blockfile="$(mktemp)"; out="$(mktemp)"
  chmod 600 "$blockfile" "$out"
  {
    echo "$SSH_BEGIN"
    echo "Host $VM_NAME"
    echo "  HostName $SSH_HOST_IP"
    echo "  Port $SSH_HOST_PORT"
    echo "  User $VM_USER"
    echo "  IdentityFile $KEY_FILE"
    echo "  IdentitiesOnly yes"
    echo "  HostKeyAlias $VM_NAME"
    echo "  StrictHostKeyChecking accept-new"
    for f in ${FORWARD_LIST[@]+"${FORWARD_LIST[@]}"}; do
      echo "  LocalForward ${f%%:*} localhost:${f##*:}"
    done
    echo "$SSH_END"
  } > "$blockfile"

  awk -v bf="$blockfile" -v begin="$SSH_BEGIN" -v end="$SSH_END" \
      -v legacy="$SSH_LEGACY" -v host="Host $VM_NAME" '
    $0 == begin  { while ((getline l < bf) > 0) print l; close(bf); placed = 1; skip = 1; next }
    skip         { if ($0 == end) skip = 0; next }
    $0 == legacy { lg = 1; next }
    lg           { if ($0 == host || $0 ~ /^[ \t]/) next; lg = 0 }
    { print }
    END { if (!placed) { if (NR > 0) print ""; while ((getline l < bf) > 0) print l } }
  ' "$cfg" > "$out" || { rm -f "$blockfile" "$out"; die "ssh config block replacement failed"; }
  cat "$out" > "$cfg"     # keep the inode, so a symlinked config still works
  rm -f "$blockfile" "$out"
}

forget_old_host_keys() {
  local kh="$HOME/.ssh/known_hosts"
  [[ -f "$kh" ]] || return 0
  # -f is explicit on purpose: ssh-keygen -R resolves ~ from the passwd entry,
  # not from $HOME, which breaks under an overridden HOME (e.g. tests).
  ssh-keygen -R "$VM_NAME" -f "$kh" >/dev/null 2>&1 || true
  ssh-keygen -R "[$SSH_HOST_IP]:$SSH_HOST_PORT" -f "$kh" >/dev/null 2>&1 || true
}

ssh_banner_ready() {
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"; read -t 3 -r line <&3 2>/dev/null; [[ $line == SSH-* ]]' _ "$SSH_HOST_IP" "$SSH_HOST_PORT" 2>/dev/null
}

probe_key_login() {
  ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o HostKeyAlias="$VM_NAME" \
      -o IdentitiesOnly=yes -i "$KEY_FILE" \
      -p "$SSH_HOST_PORT" "$VM_USER@$SSH_HOST_IP" true 2>/dev/null
}

start_vm() {
  local frontend="$1" out
  if out="$(vb startvm "$VM_NAME" --type "$frontend" 2>&1)"; then return 0; fi
  printf '%s\n' "$out" >&2
  if grep -qiE 'VERR_VMX_IN_VMX_ROOT_MODE|VERR_SVM_IN_USE|kvm' <<<"$out"; then
    die "VirtualBox cannot start while KVM is loaded. Re-run with --stop-kvm
(libvirt VMs are shut down gracefully, never force-killed)."
  fi
  die "Could not start the VM '$VM_NAME'."
}

wait_for_ssh() {
  local i state
  log "Waiting for SSH on $SSH_HOST_IP:$SSH_HOST_PORT (up to 30 minutes)"
  for ((i = 0; i < 180; i++)); do
    state="$(vm_state)"
    case "$state" in
      poweroff | aborted)
        return 2 ;;
    esac
    if ssh_banner_ready; then return 0; fi
    sleep 10
  done
  return 1
}

### Uninstall mode #####################################################

# Lists only the artifacts that currently exist (or are explicitly kept).
uninstall_items() {
  local f reg=0
  if command -v VBoxManage >/dev/null 2>&1 && vm_exists; then
    echo "vbox-vm    VBox VM '$VM_NAME' (registration, disk state, Unattended-* logs)"
    reg=1
  fi
  if [[ -e "$DISK" ]]; then echo "file       $DISK"; fi
  if [[ $reg -eq 0 && -d "$HOME/VirtualBox VMs/$VM_NAME" ]]; then
    echo "dir        $HOME/VirtualBox VMs/$VM_NAME (leftover VM folder)"
  fi
  if [[ -f "$CRED_FILE" ]]; then echo "file       $CRED_FILE (guest sudo password)"; fi
  if [[ -f "$WORKDIR/credentials/${VM_NAME}.pwfile" ]]; then
    echo "file       $WORKDIR/credentials/${VM_NAME}.pwfile (install-time temp)"
  fi
  if [[ -f "$WORKDIR/templates/debian_preseed.cfg" ]]; then
    echo "file       $WORKDIR/templates/debian_preseed.cfg (preseed copy)"
  fi
  if [[ $KEEP_ISO -eq 0 ]]; then
    for f in "$WORKDIR"/debian-*-amd64-netinst.iso "$WORKDIR"/debian-*-amd64-netinst.iso.part; do
      if [[ -e "$f" ]]; then echo "file       $f (install ISO)"; fi
    done
    if [[ -d "$WORKDIR/verify" ]]; then echo "dir        $WORKDIR/verify (ISO checksum artifacts)"; fi
  else
    if [[ -d "$WORKDIR/verify" ]]; then
      echo "keep       $WORKDIR/*.iso and $WORKDIR/verify (kept: --keep-iso)"
    fi
  fi
  if [[ -f "$SERIAL_LOG" ]]; then echo "file       $SERIAL_LOG"; fi
  if [[ -f "$KEY_FILE" ]]; then echo "file       $KEY_FILE"; fi
  if [[ -f "$KEY_FILE.pub" ]]; then echo "file       $KEY_FILE.pub"; fi
  if [[ -f "$HOME/.ssh/config" ]]; then
    if grep -qxF "$SSH_BEGIN" "$HOME/.ssh/config" && ! grep -qxF "$SSH_END" "$HOME/.ssh/config"; then
      die "$HOME/.ssh/config has a '$SSH_BEGIN' line but no matching END line; fix it by hand and re-run."
    fi
    if grep -qxF "$SSH_BEGIN" "$HOME/.ssh/config" || grep -qxF "$SSH_LEGACY" "$HOME/.ssh/config"; then
      echo "ssh-block  $HOME/.ssh/config (managed block for '$VM_NAME')"
    fi
  fi
  if [[ -f "$HOME/.ssh/known_hosts" ]] \
     && { grep -qE "(^|,)$VM_NAME(,| )" "$HOME/.ssh/known_hosts" \
          || grep -qF "[$SSH_HOST_IP]:$SSH_HOST_PORT" "$HOME/.ssh/known_hosts"; }; then
    echo "known-hosts  entries for '$VM_NAME' and [$SSH_HOST_IP]:$SSH_HOST_PORT in ~/.ssh/known_hosts"
  fi
  return 0
}

# Removes exactly this VM's managed block (modern BEGIN/END and the legacy
# single-comment format), keeping everything else byte-identical. Keeps a
# fresh backup (the pre-uninstall config) in ~/.ssh/config.mockvps.bak.
remove_ssh_block() {
  local cfg="$HOME/.ssh/config" out
  [[ -f "$cfg" ]] || return 0
  cp -p "$cfg" "$cfg.mockvps.bak"
  out="$(mktemp)"; chmod 600 "$out"
  awk -v begin="$SSH_BEGIN" -v end="$SSH_END" -v legacy="$SSH_LEGACY" \
      -v host="Host $VM_NAME" '
    $0 == begin   { skip = 1; next }
    skip          { if ($0 == end) skip = 0; next }
    $0 == legacy  { legacy_mode = 1; next }
    legacy_mode   { if ($0 == host || $0 ~ /^[ \t]/) next; legacy_mode = 0 }
    { print }
  ' "$cfg" > "$out"
  cat "$out" > "$cfg"     # keep the inode, so a symlinked config still works
  rm -f "$out"; chmod 600 "$cfg"
}

uninstall_run() {
  local cfg="$HOME/.ssh/config" f
  log "Uninstall plan for VM '$VM_NAME' (workdir: $WORKDIR)"
  uninstall_items
  if [[ $DRY_RUN -eq 1 ]]; then
    log "dry-run: nothing was removed. Re-run without --dry-run to delete for real."
    return 0
  fi
  confirm "Permanently delete everything listed above?" || die "Aborted; nothing was removed."

  if command -v VBoxManage >/dev/null 2>&1 && vm_exists; then
    log "Removing VM '$VM_NAME' (graceful ACPI shutdown first; hard stop after 2 minutes)"
    remove_vm
  fi
  if [[ -d "$HOME/VirtualBox VMs/$VM_NAME" ]]; then
    log "Removing leftover VM folder"
    rm -rf "$HOME/VirtualBox VMs/$VM_NAME"
  fi

  # Workdir artifacts, one explicit path at a time.
  rm -f -- "$DISK" "$SERIAL_LOG" "$CRED_FILE" "$WORKDIR/credentials/${VM_NAME}.pwfile"
  if [[ $KEEP_ISO -eq 0 ]]; then
    for f in "$WORKDIR"/debian-*-amd64-netinst.iso "$WORKDIR"/debian-*-amd64-netinst.iso.part; do
      if [[ -e "$f" ]]; then rm -f -- "$f"; fi
    done
    if [[ -d "$WORKDIR/verify" ]]; then rm -rf "$WORKDIR/verify"; fi
  fi
  if [[ -f "$WORKDIR/templates/debian_preseed.cfg" ]]; then
    rm -f "$WORKDIR/templates/debian_preseed.cfg"
    rmdir "$WORKDIR/templates" 2>/dev/null || true
  fi
  rmdir "$CRED_DIR" 2>/dev/null || true
  if [[ -d "$WORKDIR" ]] && [[ -z "$(find "$WORKDIR" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    rmdir "$WORKDIR" || true
  fi

  # Keys, ssh config block, known hosts.
  rm -f -- "$KEY_FILE" "$KEY_FILE.pub"
  remove_ssh_block
  if [[ -f "$HOME/.ssh/known_hosts" ]]; then
    forget_old_host_keys
  fi

  log "Removal of '$VM_NAME' is complete."
  if [[ -d "$WORKDIR" ]]; then
    warn "Workdir not fully empty: $WORKDIR (kept artifacts above, e.g. --keep-iso)"
  fi
  if [[ -f "$cfg.mockvps.bak" ]]; then
    log "Kept a restore point: $cfg.mockvps.bak (delete it when everything looks right)."
  fi
  # Resolve the REAL script location (readlink -f follows any symlink), so the
  # printed repo path is never something dangerous like $HOME.
  local script_path repo_dir
  script_path="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null)" || script_path="${BASH_SOURCE[0]:-$0}"
  repo_dir="$(dirname -- "$script_path")"
  cat <<EOF

Deliberately NOT touched (do these yourself if you truly want a clean slate):
  * this repo:            rm -rf "$repo_dir"
  * the VirtualBox packages:  sudo apt-get purge '~nvirtualbox' && sudo apt-get autoremove
  * the vboxusers group member:  sudo deluser $REAL_USER vboxusers
  * ~/.ssh/known_hosts.old, if ssh-keygen -R removed entries just now
EOF
}

### Main ##############################################################

print_summary() {
  local f
  cat <<EOF

VM is ready.

Connect:
  ssh $VM_NAME                    # dedicated key, key-only login
  (or) ssh -p $SSH_HOST_PORT $VM_USER@$SSH_HOST_IP

Install Apache in the guest (sudo asks for the stored password):
  ssh $VM_NAME
  sudo apt-get update && sudo apt-get install -y apache2

Forgot the password? (SSH never needs it)
  cat $CRED_FILE

SSH tunnels (active while an 'ssh $VM_NAME' session is open):
EOF
  if [[ ${#FORWARD_LIST[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    for f in "${FORWARD_LIST[@]}"; do
      echo "  http://localhost:${f%%:*}  ->  guest port ${f##*:}"
    done
  fi
  cat <<EOF

Management ($VM_NAME):
  run headless      : VBoxManage startvm "$VM_NAME" --type headless
  GUI console       : VBoxManage startvm "$VM_NAME" --type gui
  graceful power off: VBoxManage controlvm "$VM_NAME" acpipowerbutton
  hard power off    : VBoxManage controlvm "$VM_NAME" poweroff
  VM status         : VBoxManage list runningvms
  snapshot clean    : VBoxManage snapshot "$VM_NAME" take clean
  restore snapshot  : VBoxManage snapshot "$VM_NAME" restore clean
  uninstall all     : mockvps-vbox.sh --uninstall   (add --dry-run to preview)
EOF
  if [[ "$SERIAL" == "1" ]]; then echo "  serial log        : $SERIAL_LOG"; fi
  if [[ -n "$KVM_RESTORE_HINT" ]]; then
    printf '\nKVM was unloaded for VirtualBox. To bring it back later:\n  %s\n' "$KVM_RESTORE_HINT"
  fi
}

main() {
  local rc state
  init_defaults
  parse_args "$@"

  if [[ $UNINSTALL -eq 1 ]]; then
    [[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux hosts only."
    [[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] \
      || die "VM_NAME must be 1-64 chars [A-Za-z0-9_.-] and not start with - or . (got '$VM_NAME')"
    is_uint "$SSH_HOST_PORT" 1 65535 || die "SSH_HOST_PORT must be 1-65535 (got '$SSH_HOST_PORT')"
    SSH_HOST_PORT=$((10#$SSH_HOST_PORT))
    derive_paths
    uninstall_run
    return 0
  fi
  [[ $DRY_RUN -eq 0 ]] || die "--dry-run is only meaningful with --uninstall"
  [[ $KEEP_ISO -eq 0 ]] || die "--keep-iso is only meaningful with --uninstall"

  validate_config
  derive_paths

  [[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux hosts only."
  [[ "$(uname -m)" == "x86_64" ]] || die "This script supports x86_64 hosts only (on ARM look at Lima or multipass)."
  if [[ $EUID -ne 0 ]]; then sudo -v || die "sudo access required."; fi

  ensure_virtualbox
  ensure_vbox_host

  # KVM is only ever touched when you ask for it.
  if kvm_loaded; then
    if [[ $STOP_KVM -eq 1 ]]; then
      stop_kvm
    else
      warn "KVM is loaded. VirtualBox may refuse to start VMs until it is unloaded; if so, re-run with --stop-kvm."
    fi
  fi

  log "Preparing VM '$VM_NAME'"
  if vm_exists; then
    state="$(vm_state)"
    log "VM already exists (state: ${state:-unknown})"
    if confirm "Delete the existing VM and reinstall?"; then
      remove_vm
    else
      log "Reusing the existing VM"
      REINSTALL=0
    fi
  fi

  if [[ $REINSTALL -eq 1 ]]; then
    check_port_free
    create_vm
  else
    ensure_nat_binding
    if [[ "$(vm_state)" != "running" ]]; then check_port_free; fi
  fi
  secure_serial

  ensure_host_key

  if [[ $REINSTALL -eq 1 ]]; then
    ensure_iso
    forget_old_host_keys
    if [[ "$MANUAL" == "1" ]]; then
      vb storageattach "$VM_NAME" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$ISO_FILE"
      write_ssh_block
      start_vm gui
      cat <<EOF

Interactive installer started in a GUI window. In it, create the user '$VM_USER'
and select "SSH server" in the software selection. Afterwards, install your key:

  ssh-copy-id -i "$KEY_FILE.pub" -p $SSH_HOST_PORT $VM_USER@$SSH_HOST_IP

then:  ssh $VM_NAME
EOF
      return 0
    fi

    setup_credentials
    build_preseed_template
    local pwfile="$CRED_DIR/${VM_NAME}.pwfile"
    # shellcheck disable=SC1090
    ( umask 077; source "$CRED_FILE"; printf '%s\n' "$VM_PASSWORD" > "$pwfile" )
    log "Running unattended Debian install (typically 10-20 minutes)"
    if ! vb unattended install "$VM_NAME" \
          --iso "$ISO_FILE" \
          --script-template "$PRESEED_FILE" \
          --user "$VM_USER" \
          --user-password-file "$pwfile" \
          --hostname "${GUEST_HOST}.debian.local" \
          --time-zone UTC --locale en_US --country US; then
      rm -f "$pwfile"
      die "VirtualBox rejected the unattended-install options. Try --manual for the interactive installer."
    fi
    rm -f "$pwfile"
  fi

  if [[ "$(vm_state)" != "running" ]]; then start_vm headless; fi

  set +e
  wait_for_ssh; rc=$?
  set -e
  case $rc in
    0) ;;
    2) printf 'ERROR: the VM powered off before SSH came up -- the install most likely failed.\n' >&2
       printf '  Inspect it with: VBoxManage startvm "%s" --type gui\n' "$VM_NAME" >&2
       printf '  (add --serial on a new run to capture installer output in a log file)\n' >&2
       exit 2 ;;
    *) printf 'ERROR: SSH did not come up on %s:%s within 30 minutes.\n' "$SSH_HOST_IP" "$SSH_HOST_PORT" >&2
       printf '  The install may still be running. Check with: VBoxManage startvm "%s" --type gui\n' "$VM_NAME" >&2
       printf '  If it finished, re-run this script and answer N to reuse the VM.\n' >&2
       exit 2 ;;
  esac

  write_ssh_block

  log "Probing key-based login into the guest"
  local tries=0
  until probe_key_login; do
    tries=$((tries + 1))
    if [[ $tries -ge 6 ]]; then
      printf 'ERROR: SSH is up but key login failed.\n' >&2
      if [[ $REINSTALL -eq 0 ]]; then
        printf '  The reused VM may predate key injection. Log in once with the stored password\n' >&2
        printf '  (%s) and add %s.pub to ~/.ssh/authorized_keys.\n' "$CRED_FILE" "$KEY_FILE" >&2
      else
        printf '  See "Key-only login refused" in the README troubleshooting section.\n' >&2
      fi
      exit 3
    fi
    sleep 5
  done
  log "Key-based SSH works; password authentication over SSH is disabled in the guest."

  print_summary
}

# Allow `source mockvps-vbox.sh` (e.g. from tests) without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
