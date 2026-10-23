#!/usr/bin/env bash
#
# mockvps-vbox.sh -- spin up a disposable Debian "VPS" locally with VirtualBox
#
# Sets up VirtualBox, boots an unattended Debian install, and leaves you with
# a running VM reachable via SSH **from this host only**.
#
# Security model:
#   * NAT port-forward is bound to 127.0.0.1, not 0.0.0.0 -- other machines on
#     the LAN cannot reach the guest's SSH. Override with SSH_HOST_IP.
#   * No serial/TCP console listener by default. VirtualBox 7.x cannot bind
#     that listener to loopback, so SERIAL=1 (opt-in) re-opens it on ALL
#     interfaces -- only enable it behind a host firewall.
#   * No hardcoded credentials: a random guest password is generated once and
#     stored 0600 in "$WORKDIR/credentials/${VM_NAME}.env". SSH access to the
#     guest uses a dedicated Ed25519 key; the guest's SSH password auth is
#     disabled during the install. The password remains a fallback for the
#     local console only and never travels in shell history or CLI args.
#
# Usage:
#   ./mockvps-vbox.sh            # full setup + unattended install + wait for SSH
#   ./mockvps-vbox.sh --help     # all flags (-n/--name, -p/--port, -y/--yes, ...)
#   ./mockvps-vbox.sh -y         # skip confirmation prompts (destroys an old VM)
#   MANUAL=1 ./mockvps-vbox.sh   # boot the interactive installer instead
#
# Overridable via flags *or* environment: VM_NAME, VM_VCPUS, VM_MEMORY,
# VM_DISK_SIZE_MB, VM_USER, VM_PASSWORD, SSH_HOST_PORT, SSH_HOST_IP, WORKDIR,
# ISO_URL, SERIAL -- run with --help for the full list.
#
# After the script:  ssh mockvps-vbox

set -euo pipefail

### Config ############################################################

VM_NAME="${VM_NAME:-mockvps-vbox}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_MEMORY="${VM_MEMORY:-2048}"          # MiB
VM_DISK_SIZE_MB="${VM_DISK_SIZE_MB:-20000}"
WORKDIR="${WORKDIR:-$HOME/vps}"
DISK="${WORKDIR}/${VM_NAME}.vdi"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
SSH_HOST_IP="${SSH_HOST_IP:-127.0.0.1}" # NAT forward bind address (loopback = LAN-safe)

VM_USER="${VM_USER:-vps}"
CRED_DIR="${WORKDIR}/credentials"
CRED_FILE="${CRED_DIR}/${VM_NAME}.env"
KEY_FILE="${HOME}/.ssh/${VM_NAME}_id"   # dedicated host key for this VM
SSH_MARKER_FILE="${VM_NAME} (managed by mockvps-vbox.sh)"

SERIAL="${SERIAL:-0}"                   # 0 = no TCP serial listener (default)
REAL_USER="${SUDO_USER:-$USER}"

# Empty = auto-resolve latest Debian netinst from cdimage "current" listing
ISO_URL="${ISO_URL:-}"
CDIMAGE_BASE="${CDIMAGE_BASE:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"

MANUAL="${MANUAL:-0}"                   # 1 = boot the interactive installer

### Helpers ###########################################################

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]] && [[ $1 -ge $2 ]] && [[ $1 -le $3 ]]; }

usage() {
	cat <<EOF
usage: ${0##*/} [options]

Set up a disposable Debian server "VPS" locally in VirtualBox: unattended
install (~5 min), key-only SSH reachable from this host, no GUI. After the
run: ssh <name>  --  and  http://localhost:8080  reaches the guest's web
server over an SSH tunnel while the session is open.

options:
  -h, --help            show this help and exit
  -y, --yes             non-interactive; confirms destructive actions
  -n, --name NAME       VM name                         (default: mockvps-vbox)
  -u, --user USER       guest user                      (default: vps)
  -p, --port PORT       host port of the SSH forward    (default: 2222)
  -c, --cpus N          guest vCPUs                     (default: 2)
  -m, --memory MIB      guest RAM, MiB                  (default: 2048)
  -d, --disk MB         guest disk size, MB             (default: 20000)
  -w, --workdir DIR     state directory                 (default: ~/vps)
  -i, --iso-url URL     Debian netinst ISO URL          (default: latest auto-detected)
  -k, --ip IP           bind the NAT forward to this IP (default: 127.0.0.1; use the
                        loopback default -- only deviate if you know why)
      --manual          boot the interactive installer instead of unattended mode
      --serial          expose a TCP serial console on port 4555 for install
                        output. LISTENS ON ALL INTERFACES (VirtualBox cannot
                        bind it to loopback) -- host firewall required!
      --no-web-tunnel   do not write the 8080 LocalForward into ~/.ssh/config

Every option also has an environment-variable equivalent (VM_NAME, VM_USER,
SSH_HOST_PORT, VM_VCPUS, VM_MEMORY, VM_DISK_SIZE_MB, WORKDIR, ISO_URL,
SSH_HOST_IP, MANUAL, SERIAL, WEB_TUNNEL) -- flags win.

Security notes:
  * The SSH forward always binds 127.0.0.1 unless -k is given.
  * Guest SSH is key-only; the random guest password is stored 0600 in
    <workdir>/credentials/<name>.env (local console / sudo fallback only).
  * A random Ed25519 key <name>_id is generated once in ~/.ssh and wired
    into ~/.ssh/config via a managed block.
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)      usage; exit 0 ;;
			-y|--yes)       ASSUME_YES=1; shift ;;
			-n|--name)      [[ $# -ge 2 ]] || die "option $1 requires an argument"; [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die "invalid name: '$2'"; VM_NAME="$2"; shift 2 ;;
			-u|--user)      [[ $# -ge 2 ]] || die "option $1 requires an argument"; [[ "$2" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name: '$2'"; VM_USER="$2"; shift 2 ;;
			-p|--port)      [[ $# -ge 2 ]] || die "option $1 requires an argument"; is_uint "$2" 1 65535 || die "invalid port: '$2'"; SSH_HOST_PORT="$2"; shift 2 ;;
			-c|--cpus)      [[ $# -ge 2 ]] || die "option $1 requires an argument"; is_uint "$2" 1 32 || die "invalid cpu count: '$2'"; VM_VCPUS="$2"; shift 2 ;;
			-m|--memory)    [[ $# -ge 2 ]] || die "option $1 requires an argument"; is_uint "$2" 512 131072 || die "invalid memory: '$2'"; VM_MEMORY="$2"; shift 2 ;;
			-d|--disk)      [[ $# -ge 2 ]] || die "option $1 requires an argument"; is_uint "$2" 4000 2097152 || die "invalid disk size: '$2'"; VM_DISK_SIZE_MB="$2"; shift 2 ;;
			-w|--workdir)   [[ $# -ge 2 ]] || die "option $1 requires an argument"; WORKDIR="$2"; shift 2 ;;
			-i|--iso-url)   [[ $# -ge 2 ]] || die "option $1 requires an argument"; ISO_URL="$2"; shift 2 ;;
			-k|--ip)        [[ $# -ge 2 ]] || die "option $1 requires an argument"; SSH_HOST_IP="$2"; shift 2 ;;
			 --manual)      MANUAL=1; shift ;;
			 --serial)      SERIAL=1; shift ;;
			 --no-web-tunnel) WEB_TUNNEL=0; shift ;;
			-- )            shift; break ;;
			-*)             die "unknown option: $1 (try --help)" ;;
			*)              die "unexpected argument: $1 (no positional parameters; try --help)" ;;
		esac
	done
	[[ $# -eq 0 ]] || die "unexpected argument(s) after '--': $* (try --help)"
}

# Kernel's own module inventory -- no userspace tool racing it
module_loaded() { grep -q '^vboxdrv ' /proc/modules; }

confirm() {
	[[ $ASSUME_YES -eq 1 ]] && return 0
	read -r -p "$1 [y/N] " reply
	[[ "$reply" =~ ^[yY]([eE][sS])?$ ]]
}

run_vbox() {
	# startvm/unattended need /dev/vboxdrv access (group vboxusers).
	# Handles the stale-shell case (just added to group, not re-logged in) via sg.
	if [[ $EUID -eq 0 ]] || id -nG | grep -qw vboxusers; then
		"$@"
	else
		sg vboxusers -c "$(printf '%q ' "$@")"
	fi
}

ensure_vboxusers() {
	log "Ensuring the vboxusers group exists and $REAL_USER is a member"
	if ! getent group vboxusers >/dev/null; then
		sudo groupadd vboxusers
	fi
	if ! id -nG "$REAL_USER" | grep -qw vboxusers; then
		sudo usermod -aG vboxusers "$REAL_USER"
	fi
}

fix_udev_rules() {
	# vboxconfig regenerates 60-vboxdrv.rules with root:root 0600, locking out
	# non-root users. Normalize to the standard Debian layout and reload the
	# modules so udev re-applies the corrected rules to the device nodes.
	local rule="/etc/udev/rules.d/60-vboxdrv.rules"
	[[ -f /etc/udev/rules.d/60-vboxdrv.rules ]] || return 0
	if ! sudo grep -q 'GROUP="vboxusers"' "$rule"; then
		log "Normalizing /dev/vboxdrv permissions in $rule (root:root 0600 -> vboxusers 0660)"
		sudo sed -i 's/GROUP="root"/GROUP="vboxusers"/g; s/MODE="0600"/MODE="0660"/g' "$rule"
		sudo udevadm control --reload || true
		# re-run udev on the live nodes without unloading anything
		sudo udevadm trigger /sys/class/misc/vboxdrv /sys/class/misc/vboxdrvu /sys/class/misc/vboxnetctl || true
	fi
}

vm_state() {
	VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
		awk -F'=' '/^VMState=/ { gsub(/"/, "", $2); print $2 }'
}

wait_poweroff() {
	for _ in $(seq 1 30); do
		case "$(vm_state)" in
			poweroff | aborted | "") return 0 ;;
		esac
		sleep 2
	done
	return 1
}

verify_vboxdrv() {
	# /proc/modules is the kernel's own word; no userspace mismatch possible
	for _ in $(seq 1 10); do
		module_loaded && return 0
		sleep 2
	done
	die "vboxdrv kernel module is not loaded. Try: sudo modprobe vboxdrv ; then capture: sudo dmesg | tail -30 > ~/error.log and share it."
}

ensure_host_key() {
	if [[ ! -f "$KEY_FILE" ]]; then
		log "Generating dedicated SSH key for $VM_NAME: $KEY_FILE"
		ssh-keygen -q -t ed25519 -N "" -f "$KEY_FILE" -C "$VM_USER@$VM_NAME"
	fi
	chmod 600 "$KEY_FILE"
	chmod 644 "$KEY_FILE.pub"
}

### Credentials #######################################################

gen_password() {
	local pw
	while :; do
		pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 30)" || true
		[[ ${#pw} -eq 30 ]] && { printf '%s' "$pw"; return 0; }
	done
}

# $1 = 1 for a (re)install: env VM_PASSWORD > stored file > new random.
#     = 0 for reusing an existing VM: only the stored file is authoritative.
setup_credentials() {
	local mode="$1"
	mkdir -p "$WORKDIR" "$CRED_DIR"
	chmod 700 "$CRED_DIR"
	if [[ "$mode" == "1" ]]; then
		if [[ -n "${VM_PASSWORD:-}" ]]; then
			log "Using VM_PASSWORD from the environment"
		elif [[ -f "$CRED_FILE" ]]; then
			# Reuse the stored password so reinstalls stay consistent.
			# shellcheck disable=SC1090
			source "$CRED_FILE"
			[[ -n "${VM_PASSWORD:-}" ]] || {
				log "Credential file has no password -- generating a new one"
				VM_PASSWORD="$(gen_password)"
			}
			log "Reusing the stored password in $CRED_FILE"
		else
			log "Generating a random guest password (stored in $CRED_FILE)"
			VM_PASSWORD="$(gen_password)"
		fi
		printf "VM_PASSWORD='%s'\n" "$VM_PASSWORD" > "$CRED_FILE"
		chmod 600 "$CRED_FILE"
		unset VM_PASSWORD	# never let the plaintext linger in the environment
	else
		if [[ -f "$CRED_FILE" ]]; then
			# shellcheck disable=SC1090
			source "$CRED_FILE"
		fi
		[[ -n "${VM_PASSWORD:-}" ]] ||
			die "No credential file for the existing VM ($CRED_FILE missing). Its original password is unknown; re-run with -y to reinstall."
	fi
}

### NAT binding safety net ############################################

# Ensure the SSH port-forward is bound to $SSH_HOST_IP -- live (controlvm)
# when the VM is running, persistent (modifyvm) otherwise. Idempotent.
ensure_nat_binding() {
	local line cur_hostip state
	line="$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
		grep -F '="SSH,tcp,' || true)"
	[[ -n "$line" ]] || { log "No SSH NAT forwarding rule found"; return 1; }
	cur_hostip="$(printf '%s' "$line" | sed -E 's/.*="SSH,tcp,([^,]*),.*/\1/')"
	[[ "$cur_hostip" == "$SSH_HOST_IP" ]] && return 0

	log "Hardening SSH NAT binding: host IP '${cur_hostip:-<all interfaces>}' -> '$SSH_HOST_IP'"
	state="$(vm_state)"
	if [[ "$state" == "running" ]]; then
		VBoxManage controlvm "$VM_NAME" natpf1 delete SSH 2>/dev/null || true
		VBoxManage controlvm "$VM_NAME" natpf1 "SSH,tcp,${SSH_HOST_IP},${SSH_HOST_PORT},,22"
	else
		VBoxManage modifyvm "$VM_NAME" --nat-pf1 delete SSH 2>/dev/null || true
		VBoxManage modifyvm "$VM_NAME" --nat-pf1 "SSH,tcp,${SSH_HOST_IP},${SSH_HOST_PORT},,22"
	fi
}

# Disable a TCP serial listener inherited from older script versions
# (fresh installs created by this script simply have none).
secure_serial() {
	local mode state
	mode="$(VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null |
		awk -F'=' '/^uartmode1=/ { gsub(/"/, "", $2); print $2 }' || true)"
	case "$mode" in
		*tcpserver*) ;;
		*) return 0 ;;
	esac
	if [[ "$SERIAL" == "1" ]]; then
		log "WARNING: serial TCP listener active on all interfaces (SERIAL=1). Use a host firewall, or disable it."
		return 0
	fi
	state="$(vm_state)"
	if [[ "$state" == "running" ]]; then
		log "WARNING: serial console listener on all interfaces is still active."
		log "         Power the VM off (VBoxManage controlvm $VM_NAME acpipowerbutton) and re-run this script to disable it."
	else
		log "Disabling TCP serial console listener inherited from an older install"
		VBoxManage modifyvm "$VM_NAME" --uart1 off --uart-mode1 disconnected
	fi
}

create_vm() {
	log "Creating VM: $VM_VCPUS vCPU(s), ${VM_MEMORY} MiB RAM, ${VM_DISK_SIZE_MB} MB disk"
	mkdir -p "$WORKDIR"

	VBoxManage createvm --name "$VM_NAME" --ostype Debian_64 --register

	pf_rule="SSH,tcp,${SSH_HOST_IP},${SSH_HOST_PORT},,22"

	# No TCP serial listener by default (VirtualBox cannot bind it to
	# loopback; SERIAL=1 opt-in keeps the old all-interfaces behavior).
	if [[ "$SERIAL" == "1" ]]; then
		VBoxManage modifyvm "$VM_NAME" \
			--cpus "$VM_VCPUS" \
			--memory "$VM_MEMORY" \
			--vram 16 \
			--audio-driver none \
			--boot1 dvd --boot2 disk --boot3 none --boot4 none \
			--nic1 nat \
			--nat-pf1 "$pf_rule" \
			--uart1 0x3f8 4 \
			--uart-mode1 tcpserver 4555
		log "WARNING: serial console TCP listener enabled on ALL interfaces (VBox 7.x cannot bind it to loopback)"
	else
		VBoxManage modifyvm "$VM_NAME" \
			--cpus "$VM_VCPUS" \
			--memory "$VM_MEMORY" \
			--vram 16 \
			--audio-driver none \
			--boot1 dvd --boot2 disk --boot3 none --boot4 none \
			--nic1 nat \
			--nat-pf1 "$pf_rule"
	fi

	VBoxManage createmedium disk --filename "$DISK" --size "$VM_DISK_SIZE_MB" --format VDI

	VBoxManage storagectl "$VM_NAME" --name "IDE" --add ide --controller PIIX4 --portcount 2
	VBoxManage storageattach "$VM_NAME" --storagectl "IDE" --port 0 --device 0 --type hdd --medium "$DISK"
}

build_preseed_template() {
	local out pub64 latecmd
	out="$WORKDIR/templates/debian_preseed.cfg"
	mkdir -p "$(dirname "$out")"
	chmod 700 "$(dirname "$out")"
	[ -f /usr/share/virtualbox/UnattendedTemplates/debian_preseed.cfg ] \
		|| die "VBox template debian_preseed.cfg not found"
	cp /usr/share/virtualbox/UnattendedTemplates/debian_preseed.cfg "$out"

	# The public key line is pure ASCII (no quotes, no backslashes), so it
	# can be embedded directly -- no base64 applet in the installer needed.
	pubkey="$(tr -d '\n' < "$KEY_FILE.pub")"
	case "$pubkey" in (*[![:print:]]*) die "public key contains non-printable characters";; esac

	# Single-line late command: installs the pubkey, then hardens sshd to
	# key-only login. MUST contain no backslashes or quotes so d-i's preseed
	# parser cannot mangle it (a literal \n in the value can be turned into
	# a real newline, splitting the command and wedging finish-install).
	# NOTE: the final chown is numeric (1000:1000). d-i executes late_command
	# in its own (busybox) environment, where the net name "vps" does NOT
	# resolve -- a name-based chown silently no-ops, leaving the files owned
	# by root, and sshd's StrictModes then refuses the key. Debian guarantees
	# uid/gid 1000 for the first created user.
	latecmd="mkdir -p /target/home/${VM_USER}/.ssh; echo '${pubkey}' > /target/home/${VM_USER}/.ssh/authorized_keys; chown -R 1000:1000 /target/home/${VM_USER}/.ssh; chmod 700 /target/home/${VM_USER}/.ssh; chmod 600 /target/home/${VM_USER}/.ssh/authorized_keys; mkdir -p /target/etc/ssh/sshd_config.d; echo 'PasswordAuthentication no' > /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; echo 'PubkeyAuthentication yes' >> /target/etc/ssh/sshd_config.d/00-mockvps-hardening.conf; grep -q '^Include' /target/etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /target/etc/ssh/sshd_config; true"

	# Guard: the value itself must parse as a single shell command and
	# contain nothing d-i's preseed parser could misinterpret.
	[[ "$latecmd" == *\\* ]] && die "late_command contains backslashes"
	printf '%s' "$latecmd" | sh -n || die "late_command fails sh -n parse check"
	export AV_PUBKEY_LATECMD="$latecmd"

	# Pass A: openssh-server must be preseeded OUTSIDE any @@VBOX_COND@@
	# block, or VBox's template renderer strips it for our flag set (no
	# Guest Additions, non-minimal install). The stock template only lists
	# it under conditionals, so insert a global entry right after
	# "pkgsel/install-language-support" (always condition-free).
	# Also pin the installer kernel console: ttyS0 (visible on the
	# opt-in serial socket) or tty0 (VGA) by default. Remove every stock
	# pkgsel/include / add-kernel-opts line first -- a previously hand-edited
	# or otherwise non-pristine system template must not leak entries that
	# the renderer may or may not strip.
	if [[ "$SERIAL" == "1" ]]; then
		kopts="console=ttyS0,115200n8"
	else
		kopts="console=tty0"
	fi
	sed -i \
		-e '/^d-i pkgsel\/include/d' \
		-e '/^d-i debian-installer\/add-kernel-opts/d' \
		"$out"
	# Server-only install: do NOT run tasksel at all. Debian 13 $task
	# handling ignores a preseeded `tasksel/first multiselect standard`
	# (installer still pulls task-desktop/task-gnome-desktop), so we skip
	# the dialog entirely; pkgsel/include above provides openssh-server.
	# Base system (required + important priority) is already installed by
	# debootstrap, so the guest boots to a headless multi-user console.
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
	# Guard: all global entries must sit in the condition-free zone
	# (between the install-language-support line and the first conditional).
	awk '
		/^d-i pkgsel\/install-language-support/ { zone=1; next }
		/^@@VBOX/                                { zone=0 }
		zone && /pkgsel\/include string openssh-server/ { ok1=1 }
		zone && /debian-installer\/add-kernel-opts string/ { ok2=1 }
		zone && /pkgsel\/run_tasksel boolean false/ { ok3=1 }
		END { exit !(ok1 && ok2 && ok3) }
	' "$out" || die "pkgsel/add-kernel/run_tasksel entries not placed outside conditionals"

	# Pass B: merge the target-side commands into the template's existing
	# (possibly backslash-continued) preseed/late_command entry; create one
	# if the template has none. The stock vboxpostinstall step is preserved.
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

	# Post-merge guard: exactly one line must carry the merged value, it must
	# embed our injected chain verbatim, and the value must sh-parse cleanly
	# with no d-i-ambiguous escapes.
	merged="$(grep -E '^d-i preseed/late_command' "$out")"
	[[ "$merged" == *"$latecmd"* ]] || die "injected late_command not found in merged template"
	value="${merged#d-i preseed/late_command string }"
	[[ "$value" != "$merged" ]] || die "malformed late_command line in preseed"
	[[ "$value" == *\\* ]] && die "merged late_command contains backslashes"
	value="${value%; true}; true"
	printf '%s' "$value" | sh -n || die "merged late_command fails sh -n parse check"

	chmod 600 "$out"
	echo "$out"
}

write_ssh_block() {
	local blockfile blockout
	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	touch "$HOME/.ssh/config"
	chmod 600 "$HOME/.ssh/config"

	blockfile="$(mktemp)"
	chmod 600 "$blockfile"
	{
		echo "# $SSH_MARKER_FILE"
		echo "Host $VM_NAME"
		echo "    HostName $SSH_HOST_IP"
		echo "    Port $SSH_HOST_PORT"
		echo "    User $VM_USER"
		echo "    IdentityFile $KEY_FILE"
		echo "    IdentitiesOnly yes"
		if [[ "${WEB_TUNNEL:-1}" != "0" ]]; then
			# Tunnel the guest web server (e.g. Apache) into the host loopback
			echo "    LocalForward 8080 localhost:80"
		fi
	} > "$blockfile"

	# Replace an existing managed block in place (preserves position and
	# avoids duplicate Host entries); otherwise append it at the end.
	# The old managed block's own "Host $VM_NAME" line must not be mistaken
	# for the boundary to the next foreign Host block.
	blockout="$(mktemp)"
	chmod 600 "$blockout"
	awk -v bf="$blockfile" -v vm="$VM_NAME" '
		$0 ~ /managed by mockvps-vbox\.sh/ {
			while ((getline line < bf) > 0) print line
			close(bf)
			dropped = 1
			next
		}
		dropped && $0 ~ /^Host[[:space:]]/ && $0 != "Host " vm { dropped = 0 }
		dropped { next }
		{ print }
	' "$HOME/.ssh/config" > "$blockout" || { rm -f "$blockfile" "$blockout"; die "ssh config block replacement failed"; }
	mv "$blockout" "$HOME/.ssh/config"
	if ! grep -qF "$SSH_MARKER_FILE" "$HOME/.ssh/config"; then
		cat "$blockfile" >> "$HOME/.ssh/config"
	fi
	chmod 600 "$HOME/.ssh/config"
	rm -f "$blockfile"
}

# Test hook: lets test harnesses source helper functions without running.
[[ "${MOCKVPS_TEST:-}" == "1" ]] && return 0 2>/dev/null || true

### -i. CLI + validation ###############################################

ASSUME_YES=0
parse_args "$@"

# Recompute what depends on the (possibly flag-overridden) identity vars
DISK="${WORKDIR}/${VM_NAME}.vdi"
CRED_DIR="${WORKDIR}/credentials"
CRED_FILE="${CRED_DIR}/${VM_NAME}.env"
KEY_FILE="${HOME}/.ssh/${VM_NAME}_id"
SSH_MARKER_FILE="${VM_NAME} (managed by mockvps-vbox.sh)"

# env-var paths skipped flag validation, so re-validate everything here
is_uint "${SSH_HOST_PORT}" 1 65535       || die "SSH_HOST_PORT must be 1-65535 (got '$SSH_HOST_PORT')"
is_uint "${VM_VCPUS}" 1 32               || die "VM_VCPUS must be 1-32 (got '$VM_VCPUS')"
is_uint "${VM_MEMORY}" 512 131072        || die "VM_MEMORY (MiB) must be 512-131072 (got '$VM_MEMORY')"
is_uint "${VM_DISK_SIZE_MB}" 4000 2097152 || die "VM_DISK_SIZE_MB must be 4000-2097152 (got '$VM_DISK_SIZE_MB')"
[[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "VM_USER must be a lowercase POSIX user name (got '$VM_USER')"
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || die "VM_NAME must be 1-64 chars [A-Za-z0-9_.-], not starting with - . (got '$VM_NAME')"

if [[ "$SSH_HOST_IP" != 127.0.0.1 ]]; then
	if ! [[ "$SSH_HOST_IP" =~ ^127\. ]]; then
		printf 'WARNING: NAT forward bound to %s -- SSH and the lab will be reachable from OTHER MACHINES.\nSet a host firewall before running.\n' "$SSH_HOST_IP" >&2
		confirm "Proceed with a non-loopback bind?" || die "aborted by user"
	fi
fi

# Port conflict preflight: VirtualBox forwards need the port after the VM
# boots; die early with a clear message instead of confusing TCP turmoils.
if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$SSH_HOST_PORT" 2>/dev/null | grep -q .; then
	die "host port $SSH_HOST_PORT is already LISTENing locally. Pick another port (-p/--port or SSH_HOST_PORT)."
fi

### 0. sudo warmup #####################################################

[[ $EUID -eq 0 ]] || sudo -v || die "sudo access required."

### 1. Install VirtualBox #############################################

log "Installing VirtualBox from the official Oracle repository"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wget gnupg ca-certificates

source /etc/os-release
CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"
[[ -n "$CODENAME" ]] || die "Could not detect Debian codename."

# Oracle's repo splits per codename; probe it and fall back to bookworm
# (older packages still install fine on newer Debian).
REPO_CODENAME=""
for cand in "$CODENAME" "bookworm"; do
	# Oracle's Release files ship 'Codename:' but no 'Suite:' line, so probe Codename
	if wget -qO- --timeout=30 "https://download.virtualbox.org/virtualbox/debian/dists/$cand/Release" | grep -q "^Codename: $cand$"; then
		REPO_CODENAME="$cand"
		break
	fi
done
[[ -n "$REPO_CODENAME" ]] || die "Oracle VirtualBox repo is unreachable or has no release for this distro."
[[ "$REPO_CODENAME" != "$CODENAME" ]] && log "Using repo branch '$REPO_CODENAME' for codename '$CODENAME'"

wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc |
	sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian $REPO_CODENAME contrib" |
	sudo tee /etc/apt/sources.list.d/virtualbox.list >/dev/null

sudo apt-get update

VB_PKG=""
for candidate in virtualbox-7.2 virtualbox-7.1 virtualbox-7.0 virtualbox; do
	cand="$(apt-cache policy "$candidate" 2>/dev/null | awk '/^ *Candidate:/ { print $2 }')"
	if [[ -n "$cand" && "$cand" != "(none)" ]]; then
		VB_PKG="$candidate"
		break
	fi
done
[[ -n "$VB_PKG" ]] || die "No VirtualBox package available for this distro."

log "Installing $VB_PKG (+ DKMS and kernel headers for the host module)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
	"$VB_PKG" dkms "linux-headers-$(uname -r)" build-essential ||
	die "VirtualBox install failed."

log "Checking the VirtualBox host kernel module"
# NOTE: do NOT run vboxconfig on every invocation -- its `setup` stops
# (unloads) + rebuilds + "cleans" the module tree, and its start() decides
# "already running" from the leftover /dev node, not the kernel. On this
# machine it repeatedly left the module unloaded. Modules built by an
# earlier DKMS/vboxconfig run persist in /lib/modules; just modprobe them.
if [[ ! -e "/lib/modules/$(uname -r)/misc/vboxdrv.ko" ]]; then
	log "No prebuilt modules for $(uname -r) -- running vboxconfig (one-time build, a few minutes)"
	sudo /sbin/vboxconfig || log "vboxconfig exited nonzero -- init load attempt will tell us"
	ensure_vboxusers	# keep rule regeneration pairing with group permission
	sudo /usr/lib/virtualbox/vboxdrv.sh start || true
else
	log "Prebuilt vboxdrv modules present"
fi

if ! module_loaded; then
	log "Loading vboxdrv via modprobe"
	sudo modprobe vboxdrv || die "modprobe vboxdrv failed. Capture evidence with: sudo dmesg | tail -30 > ~/error.log and share it."
fi
for m in vboxnetflt vboxnetadp; do
	grep -q "^$m " /proc/modules || sudo modprobe "$m" || true
done

verify_vboxdrv
fix_udev_rules

VBoxManage --version

ensure_vboxusers

### 2. (Re)create the VM ##############################################

log "Preparing VM '$VM_NAME'"
REINSTALL=1	# fresh install unless an existing VM is being reused

if VBoxManage list vms 2>/dev/null | grep -Fq "\"$VM_NAME\""; then
	state="$(vm_state)"
	log "VM already exists, state: ${state:-unknown}"
	if [[ $ASSUME_YES -eq 1 ]]; then
		log "-y given: deleting the existing VM and reinstalling"
	else
		confirm "Delete the existing VM and reinstall?" &&
			log "Deleting existing VM" ||
			{ log "Reusing existing VM (will resume and wait for SSH)"; REINSTALL=0; }
	fi

	if [[ $REINSTALL -eq 1 ]]; then
		if [[ "$state" == "running" || "$state" == "saved" || "$state" == "gurumeditation" ]]; then
			run_vbox VBoxManage controlvm "$VM_NAME" acpipowerbutton 2>/dev/null ||
				run_vbox VBoxManage controlvm "$VM_NAME" poweroff 2>/dev/null || true
			wait_poweroff || run_vbox VBoxManage controlvm "$VM_NAME" poweroff || true
		fi
		run_vbox VBoxManage unregistervm "$VM_NAME" --delete
	fi
fi

if [[ $REINSTALL -eq 1 ]]; then
	create_vm
else
	log "Existing VM kept; verifying secure bindings"
fi

# Hardening safety net for both fresh and reused VMs
ensure_nat_binding || true
secure_serial

### 3. SSH key + ISO###################################################

ensure_host_key

ISO_FILE=""
if [[ -n "$ISO_URL" ]]; then
	ISO_FILE="$WORKDIR/$(basename "$ISO_URL")"
fi

log "Downloading installer ISO (skipped if it already exists)"
if [[ -z "$ISO_FILE" ]]; then
	latest="$(wget -qO- --timeout=30 "$CDIMAGE_BASE/" |
		grep -oE 'debian-[0-9]+\.[0-9]+\.[0-9]+-amd64-netinst\.iso' |
		sort -uV | tail -n1)" || true
	[[ -n "$latest" ]] || die "Could not resolve the latest ISO. Set ISO_URL='/path/to.iso' or a full direct URL and re-run."
	ISO_URL="${CDIMAGE_BASE%/}/$latest"
	ISO_FILE="$WORKDIR/$latest"
	log "Selected ISO: $ISO_URL"
fi

if [[ ! -f "$ISO_FILE" ]]; then
	rm -f "$ISO_FILE.part"
	wget -c -O "$ISO_FILE.part" "$ISO_URL" || {
		rm -f "$ISO_FILE.part"
		die "ISO download failed. You may download it manually and re-run with ISO_URL=/path/to/the.iso"
	}
	mv "$ISO_FILE.part" "$ISO_FILE"
fi
[[ -s "$ISO_FILE" ]] || die "ISO file is empty or missing: $ISO_FILE"

### 4. Run the install #################################################

# VirtualBox cannot share VT-x with the KVM hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
# Stop the earlier KVM setup (libvirtd + any KVM VMs) and unload the kvm modules.
if grep -q '^kvm[ _-]' /proc/modules; then
	log "KVM hypervisor is loaded -- stopping libvirtd/KVM VMs and unloading KVM"
	sudo systemctl stop libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
	for kvm_vm in $(sudo virsh --connect qemu:///system list --name 2>/dev/null); do
		[[ -n "$kvm_vm" ]] && sudo virsh --connect qemu:///system destroy "$kvm_vm" 2>/dev/null || true
	done
	sudo modprobe -r kvm_intel 2>/dev/null || sudo modprobe -r kvm_amd 2>/dev/null || true
	sudo modprobe -r kvm 2>/dev/null || true
fi
if grep -q '^kvm[ _-]' /proc/modules; then
	die "KVM is still running and VirtualBox needs VT-x exclusively. Free it with:
  sudo systemctl stop libvirtd; sudo virsh --connect qemu:///system destroy <vm>; sudo modprobe -r kvm_intel kvm"
fi

# The module can get churned by a concurrent `sudo /sbin/vboxconfig` run
# (do NOT run that while this script executes). Recheck right before booting:
if ! module_loaded; then
	log "vboxdrv dropped mid-run -- reloading once"
	sudo modprobe vboxdrv
fi
verify_vboxdrv

if [[ "$MANUAL" != "1" && $REINSTALL -eq 1 ]]; then
	setup_credentials 1
	log "Running unattended Debian install (takes ~10-20 minutes)"

	# Password handed over via a 0600 file, never via the command line
	# (keeps it out of shell history and process lists).
	pwfile="$CRED_DIR/${VM_NAME}.pwfile"
	oldumask="$(umask)"
	umask 077
	# shellcheck disable=SC1090
	source "$CRED_FILE"
	printf '%s\n' "$VM_PASSWORD" > "$pwfile"
	unset VM_PASSWORD
	umask "$oldumask"

	if ! run_vbox VBoxManage unattended install "$VM_NAME" \
		--iso "$ISO_FILE" \
		--script-template "$(build_preseed_template)" \
		--user "$VM_USER" \
		--user-password-file "$pwfile" \
		--hostname "${VM_NAME}.debian.local" \
		--time-zone UTC \
		--locale en_US \
		--country US; then
		rm -f "$pwfile"
		die "The full unattended flag set was rejected. Run 'MANUAL=1 $0' for the interactive installer instead."
	fi
	rm -f "$pwfile"
elif [[ "$MANUAL" == "1" && $REINSTALL -eq 1 ]]; then
	log "MANUAL=1: attaching the ISO and booting the interactive installer"
	log "NOTE: the interactive installer does NOT inject the SSH key; add it yourself afterwards."
	run_vbox VBoxManage storageattach "$VM_NAME" --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium "$ISO_FILE"
fi

state="$(vm_state)"
[[ "$state" == "running" ]] || run_vbox VBoxManage startvm "$VM_NAME" --type headless

### 5. Wait for SSH ####################################################

log "Waiting for SSH on $SSH_HOST_IP:$SSH_HOST_PORT (up to 30 minutes)"
ok=0
for _ in $(seq 1 180); do
	# bail out early if the VM turned off unexpectedly during install
	state="$(vm_state)"
	if [[ -n "$state" && "$state" != "running" && "$state" != "gurumeditation" ]]; then
		if [[ "$MANUAL" != "1" && "$state" == "poweroff" ]]; then
			# unattended installs typically finish with a running VM; if it
			# powered off, the install likely failed -> tell the user
			break
		fi
	fi
	if (timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$SSH_HOST_PORT; read -t 3 -r line <&3 2>/dev/null; [[ \$line == SSH-* ]]") 2>/dev/null; then
		ok=1
		break
	fi
	sleep 10
done

if [[ $ok -ne 1 ]]; then
	log "SSH is not reachable yet."
	cat <<EOF
If you used MANUAL=1, finish the Debian installer (openssh-server option)
in the GUI console:
    VBoxManage startvm "$VM_NAME" --type gui
Then detach the ISO afterwards:
    VBoxManage storageattach "$VM_NAME" --storagectl IDE --port 1 --device 0 \\
        --type dvddrive --medium emptydrive
Rerun this script to wait for SSH, or just try: ssh -p $SSH_HOST_PORT $VM_USER@$SSH_HOST_IP
EOF
	exit 0
fi

### 6. SSH config snippet ##############################################

write_ssh_block

### 7. Verify key auth #################################################

if [[ "$MANUAL" != "1" ]]; then
	log "Probing key-based login into the guest"
	if ssh -o BatchMode=yes \
		-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
		-o IdentitiesOnly=yes -i "$KEY_FILE" \
		-p "$SSH_HOST_PORT" "$VM_USER@127.0.0.1" true 2>/dev/null; then
		log "Key-based SSH works; guest password auth for SSH is disabled."
	else
		log "NOTE: key login not confirmed yet (first boot may still be finishing)."
		if [[ "$REINSTALL" == "0" ]]; then
			log "      Existing VM may predate key injection; log in once with the stored password, then: sudo systemctl restart ssh"
		fi
	fi
fi

### 8. Summary #########################################################

cat <<EOF

VM is ready.

Connect:
    ssh $VM_NAME                    # dedicated key; IdentitiesOnly
    (or) ssh -p $SSH_HOST_PORT $VM_USER@127.0.0.1

Install Apache in the guest (sudo asks for the stored password):
    ssh $VM_NAME
    sudo apt-get update && sudo apt-get install -y apache2

Browse the guest's website from the host's Firefox via the SSH tunnel
(any \`ssh $VM_NAME\` session activates the forward):
    http://localhost:8080

Management ($VM_NAME):
    run headless        : VBoxManage startvm "$VM_NAME" --type headless
    GUI console         : VBoxManage startvm "$VM_NAME" --type gui
    graceful power off  : VBoxManage controlvm "$VM_NAME" acpipowerbutton
    hard power off      : VBoxManage controlvm "$VM_NAME" poweroff
    show VM status      : VBoxManage list runningvms
    snapshot clean state: VBoxManage snapshot "$VM_NAME" take clean
    restore snapshot    : VBoxManage snapshot "$VM_NAME" restore clean

Guest console fallback password: $CRED_FILE (mode 0600)
EOF
