# SSH & YubiKey Setup

Run `tech`, choose **SSH & YubiKey Setup** (J), or run `Manage-RoamingSsh`.
Existing Nano/NFC aliases are unchanged. No enrollment, key deletion, or server
authorization changes are performed by this version.

## Add or edit a server

1. Authorize the selected key's public key on the server separately.
2. Choose **1**, enter the alias, hostname/IP, username and `Nano` or `NFC`.
   Editing an existing block preserves all of its aliases. Advanced blocks
   (ports, wildcard patterns, extra directives) must be edited manually.
3. Review the endpoint/key and type `YES` to save. The old config is backed up
   under `~/.ssh/roaming-wizard/`, outside Git.
4. Agree to the live test and select/touch the key. Unknown host keys must first
   be independently verified and accepted through a normal SSH connection.
   The test requires the remote command `echo ROAMING_SSH_VERIFIED` to work;
   appliances without this capability need manual validation outside the wizard.
5. Choose **4** to review the Git diff and destination. Type `YES` to commit and
   push. Success includes the commit ID and confirmation from the remote.

Failed/skipped tests block publishing. Option **3** retries a test. Each changed
alias needs a successful test against the current config in the same session.
Tests use only the selected identity: no password, agent or reused SSH session.
Local SSH overrides that change the resolved host/user/identity block verification.

## Set up another computer

Choose **2**, then Nano or NFC to call the existing import helper. Import requires
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

The wizard publishes **only `SSH/roaming.conf`**. It does not publish other profile
work or prove that all servers authorize all keys. See [SSH-QUICKSTART.md](SSH-QUICKSTART.md)
for the overall workflow and [SSH.md](SSH.md) for key details.

Developer checks (no hardware or real remote required):
`pwsh -NoProfile -File Tests/Test-RoamingSshWizard.ps1`
