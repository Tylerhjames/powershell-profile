# YubiKey SSH — quick guide

**Key = your identity. Server = who is allowed in. Profile = connection shortcuts.**

The YubiKey holds the signing secret. Each computer needs a local identity file
that points to it. Each server needs the matching **public** key for your login account.
Git syncs shortcuts and setup helpers—not private identity files or PINs.

## Everyday use

| Destination | Nano | NFC |
| --- | --- | --- |
| Arca | `ssh arca` | `ssh arca2` |
| Proxy | `ssh proxy` | `ssh proxy2` |

Plug in the key, run the command, select **Security key** if asked, and touch.
Both keys can stay connected; the alias chooses the identity. These tested keys
need no PIN or file passphrase for login. **Creating/importing a key still needs its PIN.**

## Add a server

1. Add each desired key's `.pub` contents to the server account's authorized keys
   (Linux: that user's `~/.ssh/authorized_keys`). Keep existing entries.
   On this laptop, public files are in `C:\Users\Tyler\.ssh\`:
   `id_tyler_5cnano.pub` and `id_tyler_5cnfc.pub`.
2. Edit [SSH/roaming.conf](SSH/roaming.conf) in this repo
   (`C:\Git\powershell-profile` on this laptop). Before the final `Host *`, add:

```sshconfig
Host newserver
    HostName 10.31.31.10
    User tyler
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_tyler_5cnano
```

3. Replace the example address/user. For NFC, add a separate `newserver2` block
   using `~/.ssh/id_tyler_5cnfc`. Test before closing your existing server session.
4. Commit and push the config; update the profile on other computers.

Switches/appliances must support the `ed25519-sk` SSH key type; check compatibility first.

## Use an existing key on another Windows computer

1. Install Git for Windows and this roaming profile. If already installed, run
   `Update-Profile`. Open fresh PowerShell 7 **as Administrator under your usual account**.
2. Connect only the key being imported, then run one:

```powershell
Initialize-RoamingSsh -ImportKey Nano
Initialize-RoamingSsh -ImportKey NFC
```

3. Type its PIN locally, then touch when prompted. At optional **file passphrase**
   prompts, press Enter twice for no passphrase. Never overwrite existing identity files.
4. Use a normal PowerShell window for SSH. Verify a new server host-key fingerprint
   through a trusted source before accepting it. No server changes are needed for an already-authorized key.

## Add another physical YubiKey

Use `tech` > **SSH & YubiKey Setup** > **5 — Add a key**.
Choose enrollment for a new resident credential, or recovery to register one already on the hardware. The wizard verifies recovery, installs the local identity without overwriting existing files, and records public metadata in `SSH/keys.json`.

Choose **4 — Review & publish** to sync the registry. Authorize the new `.pub` on the desired servers separately, then use **1 — Add/edit server** and **3 — Test connection**. Keep working access while testing. Other computers can then use **2** or `Initialize-RoamingSsh -ImportKey <name>` to recover the registered identity.

Nano and NFC continue to work unchanged. See [SSH-WIZARD.md](SSH-WIZARD.md) for PIN/touch choices, recovery, and publishing behavior. Never commit PINs or private identity files.
