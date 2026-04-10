# PowerShell Profile Optimization Changelog

## 2026-04-10 — Phase 1–4 Initial Optimization Pass

**Baseline measurement:** 956ms avg startup (662–1506ms range) on P16SG3, PS 7.6.0

### Phase 1: Background Git Sync (~560ms saved)

**File:** `Profile.ps1` lines 14–73 (replaced lines 14–50)
**Rationale:** The synchronous git fetch/compare/pull block was the #1 bottleneck at 563ms combined. `git fetch --quiet` alone averaged 454ms.
**Change:** Replaced the blocking git sync with a background runspace that:
- Runs the full fetch → diff → pull sequence off the main thread
- Writes result status to a temp flag file (`$env:TEMP\ps-profile-git-sync-result.txt`)
- Uses `Register-EngineEvent PowerShell.OnIdle` to check the flag on next idle and display a one-liner notification
- Stores runspace/powershell references in script-scope vars to prevent GC collection mid-flight
**Edge cases:** Handles offline/timeout (silently swallowed), local changes (skips pull, notifies), pull failures (notifies)
**Expected impact:** ~560ms removed from blocking startup path

### Phase 2: Eliminate Redundant Module Availability Checks (~50ms saved)

**File:** `Profile.ps1` lines 104–117 (replaced lines 103–138)
**Rationale:** `Install-ProfileModule` called `Get-Module -ListAvailable` for Terminal-Icons AND all three lazy modules (Pester, SecretManagement, SecretStore) every startup. Each call averaged ~17ms. The lazy modules were never imported — just checked for existence.
**Change:**
- Terminal-Icons: simplified to a direct `Get-Module` (loaded check) + `Import-Module` — no `ListAvailable` scan
- Lazy modules: removed all startup checks. They're installed once via `bootstrap.ps1` and loaded on-demand
- `Install-ProfileModule` function retained for manual use but no longer called automatically
**Expected impact:** ~67ms removed (4× ListAvailable calls eliminated)

### Phase 3: PSReadLine Version Check Removed (~16ms saved)

**File:** `Profile.ps1` lines 80–87 (replaced lines 62–73)
**Rationale:** The `Get-Module PSReadLine -ListAvailable` scan ran every startup to check for a newer version. On PS 7.4+ the bundled PSReadLine is current, and manually installed newer versions are loaded automatically via module path precedence.
**Change:** Removed the version comparison block entirely. PSReadLine configuration settings left unchanged.
**Expected impact:** ~16ms removed

### Phase 4: Code Cleanup (no perf impact)

**`Functions/publicip.ps1`** — Removed duplicate function definition (identical 20-line function was pasted twice)

**`Functions/gitprofile.ps1`** — Replaced hardcoded `C:\Users\tyler\...` path with `$HOME\Documents\Git\powershell-profile\Profile.ps1` for portability across workstations

**`Functions/test.ps1`** — Deleted. File contained only `#Test-AppLockerPolicy` comment, no functional code

**`Profile.ps1` line 266** — Renamed alias `ps` → `pstat` for `Show-ProfileStatus`. The `ps` alias shadowed the built-in `Get-Process` alias, which could cause confusion

### Summary

| Phase | Target | Measured Cost | Status |
|-------|--------|--------------|--------|
| 1 | Git sync → background | 563ms | Deferred to runspace |
| 2 | Module availability checks | 67ms | Eliminated |
| 3 | PSReadLine version scan | 16ms | Removed |
| 4 | Code cleanup | 0ms | Fixed |
| **Total estimated savings** | | **~646ms** | **Pending re-benchmark** |

**Expected post-optimization startup:** ~250–350ms (down from 956ms avg)
**Measured post-optimization startup:** 342ms avg (75–863ms range), 1046ms total system time

---

## 2026-04-10 — Function Bug Fixes & Portability Pass

### Bug Fixes

**`Get-SystemDetails.ps1` line 166 — Wrong variable in RAM recommendation**
Used `${speed}` (leftover from foreach loop) instead of `$recommendSpeed` (set from `$firstModule.Speed`). Would display the last iterated module's speed instead of the matching module's speed.

**`test-site.ps1` — Double URL prefix when user passes full URL**
`Test-Site https://example.com` would create `https://https://example.com`. Added input normalization to strip protocol prefix before use. Also improved error messages to show actual exception details.

**`renew-safe.ps1` — Case-sensitive YES comparison**
Required exact `YES` (all caps); `yes` or `Yes` was rejected. Changed to case-insensitive match. Also improved RDP detection logic — old check using `$env:CLIENTNAME` could misfire on non-RDP sessions where that var is empty. Now also shows the renewed IP config after completion.

### Portability Fixes

**`npp.ps1` — Hardcoded Notepad++ path**
Replaced single hardcoded path with search across Program Files, Program Files (x86), and LocalAppData. Removed mandatory `$file` parameter so `npp` opens Notepad++ standalone. Shows install command if not found.

**`bootstrap.ps1` — Added Notepad++ auto-install**
Bootstrap now installs Notepad++ via winget as part of workstation setup. Non-blocking, best-effort — warns if winget unavailable.

**`Update-ProfileRepo.ps1` — Hardcoded repo path**
Replaced hardcoded `$HOME\Documents\Git\powershell-profile` with cascading detection: checks `$script:ProfileRepo` (from Profile.ps1), then derives from `$PSScriptRoot`, then falls back to the hardcoded path. Also switched from `Set-Location`/`Set-Location $HOME` to `Push-Location`/`Pop-Location` for safety.

**`Invoke-InternetSpeedTest.ps1` — Hardcoded bin path**
Replaced hardcoded bin path with `$PSScriptRoot`-derived path that works regardless of where the repo is cloned.

**`Profile.ps1` — All Set-Alias calls use -Scope Global**
Fixed scoping issue where aliases created during `Reload-Profile` were lost because they were set in the function's scope instead of global. Also renamed `sp` alias (conflicted with built-in `Set-ItemProperty`) to `save`.
