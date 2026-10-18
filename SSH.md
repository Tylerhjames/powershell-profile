# Roaming YubiKey SSH

The profile loads `Functions/ssh.ps1` and `Initialize-RoamingSsh.ps1`.
`ssh` discovers Git for Windows OpenSSH and temporarily prepends its library
directory to process PATH, restoring it afterward. Arguments and native exit
codes are preserved. Without Git SSH it falls back to the SSH application on
PATH; native Windows FIDO signing may still fail. No global PATH is changed.

`SSH/roaming.conf` contains host aliases and local identity filenames only.
Use `ssh arca` / `ssh proxy` with the Nano, or `ssh arca2` / `ssh proxy2`
with the NFC. Each alias selects only its designated identity for user `tyler`.
The legacy aliases and direct IP connections default to the Nano.
Private identity handles, PINs, known_hosts, and passphrases never belong in Git.
Git's own SSH transport, scp, and sftp are not wrapped.

## One-time setup on another Windows computer

1. Install Git for Windows and bootstrap/update this roaming PowerShell profile.
2. On an existing profile installation, run `Update-Profile`, then open a fresh
   PowerShell 7 window as Administrator **under your normal Windows account**.
3. Connect just the key to import and run one command:

```powershell
Initialize-RoamingSsh -ImportKey Nano
# Or, with only the NFC connected:
Initialize-RoamingSsh -ImportKey NFC
```

The command appends an Include pointing at this checkout, backing up an existing
SSH config first. Existing local host settings take precedence; review overlapping
Host entries with `ssh -G arca2` if an old NFC identity is still listed. Keep the
checkout on the same drive as your Windows user profile for the relative Include.
Running without
`-ImportKey` only links configuration. If the checkout moves, remove its old Include
and run setup again. No SSH files are written automatically at profile startup.

Import uses `ssh-keygen -K`, asks for the key's PIN locally, and may require touch.
For no local file passphrase, press Enter at both passphrase prompts. It verifies
the recovered public fingerprint before copying the identity to the configured
filename, and refuses to overwrite existing identities. Recovery copies remain
under `~/.ssh/resident-import-*`; they are local identity handles, not Git assets.
No credential is generated or reset during setup. The NFC may yield both old and
replacement credentials; the importer selects the replacement by fingerprint.
Keep only the intended key connected during import. After setup, both keys may
remain connected: choose the key using its host alias.

Then use a normal, non-administrator PowerShell tab:

```powershell
ssh -V
ssh -G arca | Select-String 'hostname|user |identityfile|identitiesonly'
ssh arca
# Equivalent:
ssh tyler@10.31.31.5
# With the NFC instead:
ssh arca2
ssh proxy2
```

On a new computer, independently verify the server host-key fingerprint when
SSH asks. The profile does not disable host-key verification or copy known_hosts.
Both resident identities were recovered and their fingerprints verified. The user
has confirmed login with both keys. Separate aliases avoid Windows Security
waiting for an absent Nano before offering the NFC. The laptop's former proxy
override has been removed so these shared settings control both servers.

## Identities

| Key | Local filename | Verified public fingerprint |
| --- | --- | --- |
| Nano resident | `id_tyler_5cnano_resident` | `SHA256:4i1Rjisp469kzCb4ZdqwCY3rPopj7Yu2d6m3Z6Ynu1s` |
| NFC resident | `id_tyler_5nfc_resident` | `SHA256:mt+unzaPxJS88nvCqkBtZVe/ovTRG56IZSsFdcSSJWg` |

The replacement NFC credential was created without `verify-required`, recovered
from the key, and successfully used as the sole identity to log in as `tyler` on
both servers. The old `id_tyler_5nfc` file is retained locally for rollback; the
NFC aliases and import command now select only the replacement.

The old Nano identity `id_ed25519_sk` is retained locally for rollback/other
servers. Its old Arca authorization is retired separately after successful tests.
Credential replacement requires updating both the fingerprint in the setup
function and server authorizations; import will not silently trust a different key.

## Rollback

Remove the roaming Include from `~/.ssh/config` or restore the timestamped/GUID
backup made before setup. Remove `ssh.ps1` and `Initialize-RoamingSsh.ps1` from
the eager-load list and open a new tab to disable these helpers. For just this
session, `Remove-Item Function:\ssh` returns normal SSH application resolution.
Server authorization changes have separate backups in the affected account's
`~/.ssh/` (`cbit` or `tyler`); local
Git rollback does not undo server changes. Preserve working access when restoring.

## Windows Security dialog

The Windows Security selection dialog may precede touch. No provider/PIN settings
are changed to suppress it. Enrollment required explicit USB selection in an
elevated session; this is not part of everyday SSH use. No hardware key creation
or reset happens as part of the roaming profile.
