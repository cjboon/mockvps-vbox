# mockvps-vbox

A disposable Debian server "VPS" on your own machine, for zero dollars a month.

`mockvps-vbox.sh` turns VirtualBox into a private VPS provider: it runs an unattended, headless Debian install, sets up key-only SSH reachable from your host, and leaves you at a familiar prompt with `ssh mockvps-vbox`. From there you can `apt install` anything, break things recklessly, `sudo shutdown -r now`, and start over with a fresh VM whenever you like. No credit card, no quotas, no waiting on a provider.

```
+---------------------------------------+        +--------------------------------+
|  host (x86_64 Linux, VirtualBox 7.x)  |        |  guest VM (Debian, no GUI)     |
|                                       |        |                                |
|  ssh mockvps-vbox  -------------------|--NAT-->|  :22   (bound to 127.0.0.1)    |
|  http://localhost:8080  --------------|--ssh-->|  :80   (tunnel inside ssh)     |
+---------------------------------------+        +--------------------------------+
```

## Why not just use a container?

Because you already use containers. A mock VPS gives you the parts you otherwise don't get to practice on: systemd boots, GRUB and kernel updates, firewall and network configuration by hand, package upgrades, real servers listening on real ports, and a filesystem you can fill up and wreck as root. It is a scratch machine that reacts like a server, not like a container runtime.

## Requirements

- An **x86_64 Linux** host with `bash`, `sudo`, `ssh`, `wget`, and about 20 GB of free disk. (`gpg` is needed to check the ISO signature; without it the script warns and relies on the checksum only.)
- **VirtualBox 7.0 or newer.**
  - If it is already installed, the script uses it as-is, on any distribution.
  - If it is missing, the script offers to install it from Oracle's apt repository. That works on **Debian, Ubuntu and derivatives only**. On other distributions, install VirtualBox yourself first.
- Outbound internet access (the Debian netinst ISO is about 750 MB and is downloaded once).

Not supported: Windows hosts, macOS hosts, and ARM machines. On Apple silicon, look at Lima or Multipass instead.

## Quick start

```
git clone <your-repo> && cd <your-repo>
./mockvps-vbox.sh          # answer the prompts; the install typically takes 10-20 minutes
ssh mockvps-vbox           # key-only login, no password asked
```

Serve a website, in the guest:

```
sudo apt-get update && sudo apt-get install -y apache2
```

When `sudo` asks for a password, use the guest password the script generated: it is stored in `~/vps/credentials/mockvps-vbox.env` (mode 0600, readable only by you; the file is named after the VM if you used `-n`). SSH itself never needs that password.

Then open `http://localhost:8080` in your host browser while an `ssh mockvps-vbox` session is open. The SSH config block the script writes includes `LocalForward 8080 localhost:80`.

## Options

```
./mockvps-vbox.sh -y                      # no prompts (reinstalls an existing VM)
./mockvps-vbox.sh -p 2300                 # use another host port for SSH
./mockvps-vbox.sh -n lab1 -m 4096         # named VM, more RAM
./mockvps-vbox.sh -f 8443:443 -f 3000:3000   # extra tunnels: host port -> guest port
./mockvps-vbox.sh --help                  # everything
```

| Option | Meaning |
| --- | --- |
| `-n, --name NAME` | VM name (default `mockvps-vbox`) |
| `-u, --user USER` | guest user (default `vps`) |
| `-p, --port PORT` | host port of the SSH forward (default `2222`) |
| `-c, --cpus N` / `-m, --memory MIB` / `-d, --disk MB` | VM size (defaults 2 / 2048 / 20000) |
| `-w, --workdir DIR` | state directory (default `~/vps`) |
| `-i, --iso-url URL\|FILE` | use a specific ISO, either a URL or a local file (default: latest Debian netinst, verified) |
| `-f, --forward L:G` | also tunnel host port `L` (1024-65535) to guest port `G` over SSH; repeatable |
| `--no-web-tunnel` | drop the default `8080 -> 80` tunnel |
| `-k, --ip IP` | bind the NAT forward to this IPv4 address (default `127.0.0.1`; see Security) |
| `--manual` | boot the interactive installer in a GUI window instead of the unattended install |
| `--serial` | log the guest serial console to `<workdir>/<name>-serial.log` (no network listener) |
| `--stop-kvm` | unload KVM so VirtualBox can run (see below) |
| `--require-signature` | fail if the ISO checksum file's GPG signature cannot be verified |
| `--cd-key-fpr FPR` | accept an additional Debian CD signing key |
| `-y, --yes` | non-interactive; confirms prompts |

Every option also exists as an environment variable (`VM_NAME`, `VM_USER`, `SSH_HOST_PORT`, `VM_VCPUS`, `VM_MEMORY`, `VM_DISK_SIZE_MB`, `WORKDIR`, `ISO_URL`, `SSH_HOST_IP`, `MANUAL`, `SERIAL`, `STOP_KVM`, `REQUIRE_SIG`, `WEB_TUNNEL=0|1`, `FORWARDS="8443:443,3000:3000"`). Flags win over environment variables.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | the VM is up and key login works |
| 1 | an error (bad option, missing prerequisite, failed verification, ...) |
| 2 | the install did not complete: the VM powered off before SSH came up, or SSH did not appear within 30 minutes |
| 3 | SSH is up but key login failed |

## What the script does

1. Checks the host (Linux, x86_64) and finds VirtualBox, offering to install it on apt-based systems if it is missing.
2. Makes sure the `vboxdrv` kernel module is loaded, you are in the `vboxusers` group, and the device permissions are sane.
3. Leaves KVM alone unless you pass `--stop-kvm` (see below).
4. Creates the VM: SATA disk, NAT networking with the SSH forward bound to `127.0.0.1`, no GUI, no audio. The disk is first in the boot order; while it is empty the BIOS falls through to the installer ISO.
5. Downloads the latest Debian netinst ISO and **verifies it** (see below).
6. Generates a random 30-character guest password (stored mode 0600) and a dedicated Ed25519 key `~/.ssh/<name>_id`.
7. Builds a preseed from VirtualBox's own Debian template, adding:
   - `openssh-server` as a *global* package line (VirtualBox strips conditional blocks for this install's flags, so a plain `tasksel` selection does not survive),
   - a `late_command` that injects your public key with a **numeric** `chown` (d-i runs `chown` in its own environment where your guest user does not exist, so a name-based `chown` silently does nothing) and writes key-only `sshd_config.d` hardening,
   - `pkgsel/run_tasksel boolean false`, because Debian 13's tasksel ignores a preseeded `standard`-only selection and installs a desktop anyway.
8. Runs the unattended install headless, waits for the SSH banner, writes a managed block into `~/.ssh/config`, and checks that key-only login works.

Re-running the script on an existing VM asks whether to delete and reinstall it (`-y` answers yes). If you answer no, it reuses the VM: it starts it if needed, fixes the NAT rule if it drifted, and waits for SSH.

## ISO verification

The ISO is checked in two steps:

1. **Checksum.** `SHA512SUMS` is downloaded from the same directory as the ISO and the ISO must match. On a mismatch the file is deleted, so a re-run downloads it again.
2. **Signature.** `SHA512SUMS.sign` is verified with GnuPG against the Debian CD signing keys, fetched by fingerprint from `keyring.debian.org` (falling back to `keyserver.ubuntu.com`). The accepted fingerprints are the ones listed at <https://www.debian.org/CD/verify>:
   - `1046 0DAD 7616 5AD8 1FBC 0CE9 9880 21A9 64E6 EA7D`
   - `DF9B 9C49 EAA9 2984 3258 9D76 DA87 E80D 6294 BE9B`

   If the signature cannot be checked at all (no `gpg`, no keyserver access), the script warns and continues with the checksum only; add `--require-signature` to make that fatal instead. A signature that is present but *bad* is always fatal. If Debian rotates its signing key, add the new fingerprint with `--cd-key-fpr`.

A local ISO (`-i /path/to.iso`) or a custom URL without a `SHA512SUMS` next to it is used with a warning that it is **not** verified.

## KVM and VirtualBox

Older VirtualBox versions cannot share VT-x/AMD-V with the KVM hypervisor. The script never touches KVM on its own. If KVM is loaded it prints a warning, and if VirtualBox then refuses to start, it tells you to re-run with `--stop-kvm`.

With `--stop-kvm`, the script lists any running libvirt VMs, asks for confirmation (unless `-y`), and sends each an ACPI shutdown. If they have not stopped after about two minutes it gives up. **It never force-kills a VM.** It then stops libvirt and unloads the KVM modules, and prints the command to bring KVM back afterwards (typically `sudo modprobe kvm_intel && sudo systemctl start libvirtd.socket`).

## Several VMs

Use `-n` to create more than one VM (and `-p` to give each its own SSH port). Each VM has its own disk, credentials file, SSH key, and a separate `BEGIN`/`END`-delimited block in `~/.ssh/config`, so they never overwrite each other:

```
./mockvps-vbox.sh -n lab1 -p 2301
./mockvps-vbox.sh -n lab2 -p 2302 -m 4096
ssh lab1
```

Before editing `~/.ssh/config`, the script saves a copy as `~/.ssh/config.mockvps.bak`. It also recognises and replaces the block format written by the first version of the script.

## Security model

- **Loopback-only exposure.** The NAT forward binds `127.0.0.1`, so other machines on your LAN cannot reach the VM. `-k`/`SSH_HOST_IP` overrides this, prints a warning, and asks for confirmation. Only use it behind a host firewall.
- **No serial console listener.** `--serial` writes the guest's serial output to a log file (mode 0600). An older install that left a TCP serial listener on all interfaces is detected and disabled.
- **Key-only SSH.** `PasswordAuthentication no` is written during the install. The generated password is for `sudo` and the local console only; rotate it any time with `passwd` in the guest.
- **Verified ISO.** See above.
- **The VM is not a security boundary against your host.** It is a local lab. Treat it like a home directory with context, not like cloud isolation, and if you would not run something in your user session, do not run it in the VM.

## Files the script creates

| Path | Contents |
| --- | --- |
| `~/vps/<name>.vdi` | the VM disk |
| `~/vps/credentials/<name>.env` | the guest password (0600) |
| `~/vps/templates/debian_preseed.cfg` | the generated preseed (0600) |
| `~/vps/verify/` | the downloaded `SHA512SUMS` and signature |
| `~/vps/<name>-serial.log` | only with `--serial` |
| `~/.ssh/<name>_id`, `~/.ssh/<name>_id.pub` | the dedicated SSH key pair |
| `~/.ssh/config` | one managed block per VM (backup: `~/.ssh/config.mockvps.bak`) |

## Uninstalling

```
VBoxManage unregistervm mockvps-vbox --delete     # use your VM's name
rm -rf ~/vps                                      # disk, credentials, ISO, templates
rm -f ~/.ssh/mockvps-vbox_id ~/.ssh/mockvps-vbox_id.pub
ssh-keygen -R mockvps-vbox
```

Then delete the block between the `# BEGIN mockvps-vbox:<name>` and `# END mockvps-vbox:<name>` lines in `~/.ssh/config`.

## Troubleshooting

- **The script exits with code 2 and says the VM powered off.** The unattended install most likely failed. Start the VM with a window to see where it stopped: `VBoxManage startvm mockvps-vbox --type gui`. On a fresh run, add `--serial` to capture installer output in `~/vps/mockvps-vbox-serial.log`.
- **Code 2 with an SSH timeout.** The install may simply still be running, especially on a slow connection. Check with the GUI command above. If it finished, re-run the script and answer **N** to reuse the VM.
- **"VirtualBox cannot start while KVM is loaded."** Re-run with `--stop-kvm`, or stop libvirt and unload the modules yourself: `sudo systemctl stop libvirtd; sudo modprobe -r kvm_intel kvm`.
- **"The vboxdrv kernel module is not loaded."** Run `sudo modprobe vboxdrv` and check `sudo dmesg | tail -30`. If Secure Boot is enabled, the VirtualBox kernel modules must be signed or enrolled (MOK) first.
- **Key login refused after a manual change.** sshd's StrictModes rejects an `authorized_keys` owned by someone else. As root in the guest: `chown -R vps:vps /home/vps/.ssh; chmod 700 /home/vps/.ssh`.
- **Host-key warning after a rebuild.** The script clears the old entries on reinstall and the SSH block sets a `HostKeyAlias`, so this should not appear. If it does, run `ssh-keygen -R mockvps-vbox`.
- **"Host port ... is already in use."** Pick another with `-p`.
- **ISO verification fails.** A checksum mismatch means a corrupt or tampered download; the file is removed and a re-run fetches it again. "Unexpected key" or "bad signature" messages should be taken seriously: check <https://www.debian.org/CD/verify> before using `--cd-key-fpr`.
- **Other VirtualBox install on a non-apt distribution.** Install VirtualBox 7.x yourself, make sure `VBoxManage` is on your `PATH`, and re-run.

## License

MIT. Provided as-is; you are running a local, root-capable installer, so read the script before you run it.
