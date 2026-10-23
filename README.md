# mockvps-vbox

A disposable Debian server "VPS" on your own machine, in about five minutes,
for zero dollars a month.

`mockvps-vbox.sh` is one script that turns VirtualBox into a private VPS
provider: it installs a headless Debian guest unattended, wires up key-only
SSH reachable from your host, and leaves you at a familiar prompt --
`ssh mockvps-vbox` -- from which you can apt-install anything, break things
recklessly, `sudo shutdown -r now`, and start over with a fresh VM any time
you like. No credit card, no quotas, no waiting.

```
+---------------------------------------+        +--------------------------------+
|  host (Linux, VirtualBox 7.x)         |        |  guest VM (Debian, no GUI)     |
|                                       |        |                                |
|  ssh mockvps-vbox  -------------------|--NAT--->|  :2222  (127.0.0.1 only)      |
|  browser http://localhost:8080  ------|--ssh--->|  :80   (tunnel inside ssh)    |
+---------------------------------------+        +--------------------------------+
```

## Why not just use a container?

Because you already use containers. A mock VPS gives you the parts you
otherwise don't get to practice on: systemd boots, GRUB/kernel updates,
firewall and networking configs by hand, package upgrades, real servers
listening on real ports, a filesystem you can fill up and wreck from root.
It is a scratch machine that reacts like a server, not like a container
runtime.

## Requirements

- Linux host, x86_64, with `bash`, `sudo` rights, and ~20 GB free disk
- Oracle VirtualBox 7.x (the script can install it for you from Oracle's repo)
- Outbound internet (the Debian netinst ISO, ~750 MB, is auto-downloaded once)

## Quick start

```bash
git clone <your-repo> && cd <your-repo>
./mockvps-vbox.sh          # confirm prompts, watch it run, ~5 min
ssh mockvps-vbox           # key-only login, no passwords asked
```

Serve a website, in the guest:

```bash
sudo apt-get update && sudo apt-get install -y apache2
```

When `sudo` asks for a password, use the guest password the script
generated for you: it is stored in `~/vps/credentials/mockvps-vbox.env`
(mode 0600, readable only by you; use `~/vps/credentials/<name>.env` if you
renamed the VM with `-n`). SSH itself never needs that password -- remote
login is key-only.

...then open `http://localhost:8080` in your host browser while an
`ssh mockvps-vbox` session is running. The SSH config block the script
writes includes a `LocalForward 8080 localhost:80`.

## Useful flags

```bash
./mockvps-vbox.sh -y                 # no prompts (reinstalls an existing VM)
./mockvps-vbox.sh -p 2300            # pick another host port
./mockvps-vbox.sh -n lab1 -m 4096    # named VM / more RAM
./mockvps-vbox.sh --help             # everything
```

Every flag also exists as an env var (`VM_NAME`, `SSH_HOST_PORT`, ...); flags
win. All VM state lives in `~/vps/` (disk image, credentials, templates);
delete the directory + `VBoxManage unregistervm mockvps-vbox --delete` and
you have uninstalled it cleanly.

## What the script actually does

1. Installs VirtualBox from Oracle's repo (skipped if already present)
2. Generates a random 30-char guest password once, stores it mode-0600 in
   `~/vps/credentials/<vm>.env` (never on the command line, never in history)
3. Generates a dedicated Ed25519 key `~/.ssh/<vm>_id`
4. Builds a preseed from VirtualBox's own Debian template, adding:
   - `openssh-server` as a *global* package line (VBox strips conditional
     blocks for this install's flags -- a plain `tasksel` selection does not survive)
   - a patched-in `late_command` that injects your public key with a
     NUMERIC chown (d-i runs chown against its own /etc/passwd where your
     guest user does not exist -- name-based chown silently no-ops) and
     writes `sshd_config.d` key-only hardening
   - `pkgsel/run_tasksel boolean false` for a headless server (Debian 13's
     tasksel ignores a preseeded `standard`-only selection and installs a
     desktop anyway)
5. Runs the unattended install headless, then waits for the SSH banner,
   writes the `~/.ssh/config` managed block, and verifies key-only login

Re-running the script idempotently finishes/repairs/reinstalls as needed;
reinstalls keep the stored password so your `sudo` habit survives rebuilds.

## Security model

- **Loopback-only exposure.** The NAT forward binds `127.0.0.1`. Other hosts
  on your LAN cannot even TCP-connect to the VM. Overriding with `-k` /
  `SSH_HOST_IP` prints a loud warning and requires `-y` or confirmation.
- **No serial console listener by default.** VirtualBox 7.x cannot bind its
  TCP serial console to loopback, so `SERIAL=1` / `--serial` (kept only for
  debugging install failures) listens on all interfaces; a host firewall
  (e.g. ufw) is strongly recommended while it is on.
- **Key-only SSH + stored password.** The generated password is for
  `sudo`/local console inside the guest, not for SSH (`PasswordAuthentication
  no` is written during install). Rotate it any time with `passwd` in the VM.
- **The VM is not a security boundary against your host.** It is a local lab:
  treat it like a home directory with context, not like cloud isolation. If
  you would not run it in your user session, do not run it in the VM.

## Troubleshooting

- **`ssh mockvps-vbox` warns "REMOTE HOST IDENTIFICATION CHANGED" right
  after a rebuild?** That is expected -- the guest sshd generated a new host
  key for a fresh disk, and your known_hosts still remembers the old one:
  `ssh-keygen -R '[127.0.0.1]:2222'`, then reconnect.
- **Key-only login refused after a manual intervention?** StrictModes rejects
  `authorized_keys` owned by anyone else. As root in the guest:
  `chown -R vps:vps /home/vps/.ssh; chmod 700 /home/vps/.ssh`
- **SSH never comes up?** Run the script again first (it resumes/repairs); if
  you suspect install-stage trouble, `--serial` plus a GUI console
  (`VBoxManage startvm mockvps-vbox --type gui`) will show you the installer.
  Note the guest program output is also on VGA (`console=tty0`).
- **"KVM is still running and VirtualBox needs VT-x exclusively"?** Stop
  libvirtd/KVM first: `sudo systemctl stop libvirtd; sudo modprobe -r kvm_intel kvm`
- **Port already in use?** The script dies early if something on the host
  listens on your chosen port -- try `-p 2300`.
- **Host firewall (ufw) safe?** Yes, the default loopback bind and SSH
  forward pass through ufw. With ufw *enabled*, however, `--serial` will be
  blocked on port 4555 unless you open it.
- **Windows/macOS hosts, ARM machines?** Not supported by this script; on
  Apple-silicon look at Lima/multipass instead.

## License

MIT. Provided as-is; you are running a local root-capable installer --
read it before you run it.
