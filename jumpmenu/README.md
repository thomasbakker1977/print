# jumpmenu

Open iTerm2 on the MacBook → you land straight in an ASCII menu on the
jumphost → pick a service group, a Proxmox guest or a Proxmox node → SSH
session with your private key. Log out of the target and you are back in
the menu.

```
+----------------------------------------------------------------------+
| Jumphost  -  Proxmox guests                                          |
+----------------------------------------------------------------------+

       VMID   T   NAME                         STATUS   NODE       TAGS
    1) 101    vm  gitlab                       running  pve1       dev,web
    2) 200    ct  pihole                       running  pve2       network
    3) 102    vm  win11                        stopped  pve1

 [nr] connect  [text] filter  [b] back  [q] quit >
```

```
MacBook (iTerm2 profile "Jumphost Menu")
   └─ ssh jump-menu  ──►  jumphost: ~/bin/jumpmenu
                              ├─ Service groups   (hosts.conf + Proxmox tags)
                              ├─ Proxmox guests   (Proxmox API)
                              └─ Proxmox nodes    (Proxmox API)
                                     └─ ssh -i ~/.ssh/id_ed25519 user@target
```

## 1. Jumphost

Needs `bash` 4+, `ssh`, `curl`, `jq` (`sudo apt install curl jq`).

```bash
git clone <this repo> && cd print/jumpmenu
./install.sh                      # -> ~/bin/jumpmenu + ~/.config/jumpmenu/
```

Edit `~/.config/jumpmenu/jumpmenu.conf` and `~/.config/jumpmenu/hosts.conf`
(see the `.example` files – every option is commented).

**Key for the targets.** Two options:

* **Key on the jumphost** (default): `SSH_KEY="$HOME/.ssh/id_ed25519"`.
  Generate with `ssh-keygen -t ed25519` and put the `.pub` on every target /
  Proxmox node (`ssh-copy-id root@10.0.0.11`).
* **Key stays on the Mac**: set `SSH_KEY=""` in `jumpmenu.conf` and enable
  `ForwardAgent yes` in the Mac's ssh config. Only do this if you trust the
  jumphost's root users – they can use your agent while you are logged in.

## 2. Proxmox API token (read-only)

On any Proxmox node:

```bash
pveum user add jumpmenu@pve --comment "jumphost menu"
pveum role add JumpMenu -privs "VM.Audit Sys.Audit VM.Monitor"          # PVE 8
# pveum role add JumpMenu -privs "VM.Audit Sys.Audit VM.GuestAgent.Audit"  # PVE 9
pveum acl modify / -user jumpmenu@pve -role JumpMenu
pveum user token add jumpmenu@pve menu --privsep 0
```

Put the token into `jumpmenu.conf` (`PVE_TOKEN_ID='jumpmenu@pve!menu'`,
`PVE_TOKEN_SECRET=...`). The file is `chmod 600`; the token is passed to curl
through a file descriptor so it never shows in `ps`.

`VM.Monitor` / `VM.GuestAgent.Audit` is only needed to read VM IP addresses
from the qemu-guest-agent. Without it (or without the agent in the VM) the
menu falls back to `<guestname>.<GUEST_DOMAIN>` (`GUEST_ADDR_ORDER="agent dns"`).
Container (LXC) IPs work with `VM.Audit` alone. A fixed address/user/port per
guest can be set in the `[pve-overrides]` section of `hosts.conf`.

Guest tags in Proxmox (e.g. `web`, `database`) automatically appear as
service groups (`#web`) – set `PVE_TAGS_AS_GROUPS=0` to disable.

## 3. MacBook

1. Append [`mac/ssh_config`](mac/ssh_config) to `~/.ssh/config` and set your
   jumphost name/user. Test it:
   ```bash
   ssh jump-menu
   ```
   (`ssh jump` still gives a normal shell, so `scp`/`rsync` keep working.)
2. Load the Mac key into the Keychain once so there is no passphrase prompt:
   ```bash
   ssh-add --apple-use-keychain ~/.ssh/id_ed25519
   ```
3. Install the iTerm2 profile:
   ```bash
   mkdir -p ~/Library/Application\ Support/iTerm2/DynamicProfiles
   ```
   ```bash
   cp mac/jumpmenu-iterm2.json ~/Library/Application\ Support/iTerm2/DynamicProfiles/
   ```
4. iTerm2 → Settings → Profiles → **Jumphost Menu** → *Other Actions…* →
   **Set as Default**. Every new window/tab now opens the menu.
   (Prefer to keep a local shell as default? Leave it, and open the menu with
   *Profiles → Jumphost Menu* or ⌘O.)

Thanks to `ControlMaster`, additional tabs reuse the existing connection and
open instantly.

## Usage

| Key       | Action                                              |
|-----------|-----------------------------------------------------|
| `1` `2` `3` | service groups / Proxmox guests / Proxmox nodes   |
| number    | connect to that entry                               |
| any text  | filter the list (`/text` also works); empty = clear |
| `/text`   | (main menu) search across everything                |
| `r`       | reload hosts.conf and refresh the Proxmox list      |
| `s`       | normal shell on the jumphost (`exit` returns)       |
| `b` / `q` | back / quit (closes the iTerm2 tab)                 |

Direct connect without the menu: `ssh -t jump jumpmenu gitlab`
(name or VMID; ambiguous names open a filtered list). `jumpmenu --list` prints
all targets. Connections are logged to `~/.local/state/jumpmenu/history.log`.

## Optional: force the menu for a dedicated account

If a jumphost account should *only* ever get the menu, add to its
`~/.ssh/authorized_keys` line: `command="/home/<user>/bin/jumpmenu",no-port-forwarding ssh-ed25519 AAAA…`
(this also disables `scp` for that key – that's why the ssh_config
`RemoteCommand` approach above is the default).
