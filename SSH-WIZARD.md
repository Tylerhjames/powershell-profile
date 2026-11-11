# SSH & YubiKey Setup

Run `tech`, choose **SSH & YubiKey Setup** (J), or run `Manage-RoamingSsh`.
Existing Nano/NFC aliases, filenames, and fingerprints are unchanged. The menu is vertical:

1. Add/edit server
2. Set up this computer / import a registered key
3. Test connection
4. Review & publish
5. Add a key (enroll or recover)
6. View registered keys and local status
7. Resume authorization / test / publish walkthrough
Q. Return to menu

No server authorization changes, key deletion, or hardware reset are performed.

## Add or edit a server

1. Keep an existing SSH session open on the server under an account with sudo access.
2. Choose **1**, enter the alias, hostname/IP, username and a registered key name (including `Nano` or `NFC`).
   Editing an existing block preserves all of its aliases. Advanced blocks
   (ports, wildcard patterns, extra directives) must be edited manually.
3. Review the endpoint/key and type `yes` to save (any capitalization accepted). The old config is backed up
   under `~/.ssh/roaming-wizard/`, outside Git.
4. Follow the authorization walkthrough. Verify the target account exists. **S** copies
   the complete Linux server command with the verified public key already included.
   Paste it into the existing server session and press Enter. Wait for `Key authorized`.
   Existing entries are retained; running the same command again skips the exact existing key line.
   The command is highlighted in amber. **C** optionally copies only the public key for manual use.
   If already authorized, skip copying. The wizard does not run these server commands itself.
5. Choose **T**, agree to the live test and select/touch the key. Unknown host keys must first
   be independently verified and accepted through a normal SSH connection.
   The test requires the remote command `echo ROAMING_SSH_VERIFIED` to work;
   appliances without this capability need manual validation outside the wizard.
6. After successful testing, accept the offer to review/publish (or choose **4** later).
   Review the Git diff and destination. Type `yes` to commit and
   push. Success includes the commit ID and confirmation from the remote.

Failed/skipped tests block publishing. Option **3** retries a test; option **7**
resumes the walkthrough. Choosing Q retains local work. Each changed alias needs
a successful test against the current config in the same session.
Tests use only the selected identity: no password, agent or reused SSH session.
Local SSH overrides that change the resolved host/user/identity block verification.

## Set up another computer

Choose **2**, then any registered key name to call the import helper. Existing `Initialize-RoamingSsh -ImportKey Nano` and `-ImportKey NFC` commands still work. Import requires
Administrator PowerShell under your usual account and the key's PIN entered
locally. Connect only the key being imported. Leave the choice blank to link
configuration without importing. Local setup has nothing to commit or push.

## If interrupted or publishing fails

Pending edits/commit details remain in a local journal. Reopen the wizard and
retest the pending aliases before publishing. A failed push retains the local
commit and can be retried without creating a second commit. No force-push,
automatic merge, reset, or rollback is performed. Remote changes require manual
reconciliation. Existing tracked/index changes block wizard editing/publishing;
untracked files are never included. External edits to a pending config also stop
the wizard: review those changes and the local journal before proceeding.

The wizard publishes **only `SSH/roaming.conf` and `SSH/keys.json`**. The registry contains names, local filenames, public labels, and expected public fingerprints; no private identity handles or PINs. It does not publish other profile
work or prove that all servers authorize all keys. See [SSH-QUICKSTART.md](SSH-QUICKSTART.md)
for the overall workflow and [SSH.md](SSH.md) for key details.

## Add a key

Choose **5**, give the key a unique name, then choose enrollment or recovery.

- **Enrollment** creates a new `ed25519-sk` resident credential with a unique SSH application name. It asks whether each login should require PIN verification; No retains the current touch-only behavior. A FIDO2 key supporting this algorithm and a configured FIDO PIN are required. PIN setup/reset is not performed by this wizard.
- **Recovery** retrieves existing resident credentials from the connected key. Select the intended fingerprint; a fingerprint already registered should instead be imported through option 2.

Connect only the intended hardware key. Enter PINs and optional file passphrases directly into OpenSSH. Enrollment is followed by recovery and matching-fingerprint verification before registration. Confirm the name/fingerprint before the recovered identity is installed locally. Existing identity files are never overwritten.

The new local filename is `~/.ssh/id_roaming_<name>`. Public metadata is added to `SSH/keys.json`; use **4** to review and publish it. A key-only registration does not require a server login. Host edits still require their successful live connection tests. Then authorize the `.pub` on the desired server separately, use **1** to assign the new key to an alias, and test it.

Working/recovery files remain under `~/.ssh/key-setup-*` outside Git, including after failure or cancellation. If enrollment succeeded but later steps failed, recover the existing credential on the next attempt rather than enrolling another one. No automatic cleanup deletes credentials. Local file status in option 6 is not a hardware-presence or server-authorization test.

Older pending wizard journals are preserved but refused by this version because verification now covers both configuration and registry. Finish those pending edits with the previous version or review them manually before using the new wizard.

Developer checks (no hardware or real remote required):

```powershell
pwsh -NoProfile -File Tests/Test-RoamingSshWizard.ps1
pwsh -NoProfile -File Tests/Test-RoamingSshKeys.ps1
pwsh -NoProfile -File Tests/Test-RoamingSshMenu.ps1
```

Enrollment/recovery flags follow the [OpenSSH ssh-keygen documentation](https://man.openbsd.org/ssh-keygen#FIDO_AUTHENTICATOR). Tests use mocked hardware; actual enrollment and live login remain operator validation.
