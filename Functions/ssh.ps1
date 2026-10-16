# Prefer Git for Windows OpenSSH for FIDO security-key support. Resolve at call
# time so this profile also works on machines without Git or after installation.
function global:Get-ProfileGitSsh {
    if ($IsWindows) {
        $candidates = @(
            foreach ($git in (Get-Command git.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
                Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'usr\bin\ssh.exe'
            }
            if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git\usr\bin\ssh.exe' }
            if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\ssh.exe' }
        )
        $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
}

function global:ssh {
    # Keep this a simple function: SSH owns all argument/flag parsing.
    $gitSsh = Get-ProfileGitSsh
    $sshExe = $gitSsh
    if (-not $sshExe) {
        $commandName = if ($IsWindows) { 'ssh.exe' } else { 'ssh' }
        $sshExe = (Get-Command $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    }
    if (-not $sshExe) {
        $global:LASTEXITCODE = 127
        Write-Error 'SSH client not found. Install Git for Windows or OpenSSH Client.'
        return
    }

    $originalPath = $env:PATH
    try {
        if ($gitSsh) { $env:PATH = "$(Split-Path $gitSsh -Parent);$originalPath" }
        & $sshExe @args
    }
    finally {
        # Native exit status is otherwise local to this function's scope.
        $sshExitCode = $LASTEXITCODE
        $env:PATH = $originalPath
        $global:LASTEXITCODE = $sshExitCode
    }
}
