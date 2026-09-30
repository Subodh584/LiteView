# LiteView one-command installer for Windows. Run in PowerShell:
#
#   irm https://raw.githubusercontent.com/Subodh584/LiteView/main/install.ps1 | iex
#
# Downloads LiteView, installs Python if needed, opens the firewall port (one UAC
# prompt), makes LiteView start at login, and starts it now. Re-run it to update.

& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # makes Invoke-WebRequest much faster

$Repo = 'Subodh584/LiteView'
$Dir = Join-Path $env:LOCALAPPDATA 'LiteView'
$Port = 8765
$Log = Join-Path $HOME '.liteview.log'

function Say($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Find-Python {
    $probes = @(
        { py -3 -c 'import sys; print(sys.executable)' },
        { python -c 'import sys; print(sys.executable)' }
    )
    foreach ($probe in $probes) {
        try {
            $exe = & $probe 2>$null | Select-Object -Last 1
            if ($LASTEXITCODE -eq 0 -and $exe -and (Test-Path $exe.Trim())) { return $exe.Trim() }
        } catch {}
    }
    $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

try {
    # ---- Python -------------------------------------------------------------
    $py = Find-Python
    if (-not $py) {
        Say 'Python not found - installing Python 3.12 with winget...'
        try {
            winget install -e --id Python.Python.3.12 --scope user --silent `
                --accept-package-agreements --accept-source-agreements | Out-Host
        } catch {}
        $py = Find-Python
        if (-not $py) {
            throw 'Could not install Python automatically. Install it from https://www.python.org/downloads/ and run this command again.'
        }
    }
    Say "Using Python: $py"

    # ---- stop a running copy so its files can be replaced ----------------------
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" |
        Where-Object { $_.CommandLine -like "*$Dir*host.py*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # ---- download ---------------------------------------------------------------
    Say "Downloading LiteView to $Dir ..."
    $zip = Join-Path $env:TEMP 'liteview.zip'
    $unpacked = Join-Path $env:TEMP 'liteview-unpacked'
    Invoke-WebRequest "https://github.com/$Repo/archive/refs/heads/main.zip" -OutFile $zip -UseBasicParsing
    Remove-Item $unpacked -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip $unpacked -Force
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $src = Get-ChildItem $unpacked -Directory | Select-Object -First 1
    Copy-Item (Join-Path $src.FullName '*') $Dir -Recurse -Force
    Remove-Item $zip, $unpacked -Recurse -Force -ErrorAction SilentlyContinue

    # ---- virtualenv + packages ------------------------------------------------
    Say 'Installing Python packages (first time takes a minute)...'
    $venvPy = Join-Path $Dir '.venv\Scripts\python.exe'
    $venvPyw = Join-Path $Dir '.venv\Scripts\pythonw.exe'
    if (-not (Test-Path $venvPy)) {
        & $py -m venv (Join-Path $Dir '.venv')
        if ($LASTEXITCODE) { throw 'Creating the Python virtual environment failed.' }
    }
    & $venvPy -m pip install --disable-pip-version-check -q -r (Join-Path $Dir 'requirements.txt')
    if ($LASTEXITCODE) { throw 'Installing Python packages failed (see the messages above).' }

    # ---- Tailscale --------------------------------------------------------------
    $tailscale = @((Get-Command tailscale -ErrorAction SilentlyContinue).Source,
                   (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $hostPy = Join-Path $Dir 'host.py'
    $hostArgs = @("`"$hostPy`"")
    if ($tailscale) {
        $hostArgs += '--tailscale-only'
    } else {
        Warn 'Tailscale is not installed, so LiteView will only work on this local network.'
        Warn 'For access over the internet, install it from https://tailscale.com/download and re-run this command.'
    }
    $argLine = $hostArgs -join ' '

    # ---- firewall (one UAC prompt, only the first time) --------------------------
    if (-not (Get-NetFirewallRule -DisplayName 'LiteView' -ErrorAction SilentlyContinue)) {
        Say 'Opening the firewall for LiteView (click Yes on the Windows prompt)...'
        # The venv launcher starts the real interpreter, which is what actually listens.
        $baseDir = Split-Path (& $venvPy -c 'import sys; print(sys._base_executable)')
        $programs = @((Join-Path $baseDir 'python.exe'), (Join-Path $baseDir 'pythonw.exe'))
        $cmd = "foreach (`$p in @('" + (($programs | ForEach-Object { $_ -replace "'", "''" }) -join "','") + "')) { " +
               "New-NetFirewallRule -DisplayName 'LiteView' -Direction Inbound -Action Allow -Protocol TCP " +
               "-LocalPort $Port -RemoteAddress LocalSubnet,100.64.0.0/10 -Program `$p -Profile Any | Out-Null }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        try {
            Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden `
                -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
        } catch {
            Warn 'Firewall prompt was declined. If connecting fails, re-run this command and click Yes.'
        }
    }

    # ---- start at login ---------------------------------------------------------
    Say 'Making LiteView start automatically when you log in...'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'LiteView.lnk'))
    $shortcut.TargetPath = $venvPyw
    $shortcut.Arguments = $argLine
    $shortcut.WorkingDirectory = $Dir
    $shortcut.Save()

    # ---- start now ----------------------------------------------------------------
    Say 'Starting LiteView in the background...'
    $proc = Start-Process $venvPyw -ArgumentList $argLine -WorkingDirectory $Dir -PassThru
    Start-Sleep -Seconds 4
    if ($proc.HasExited) {
        Warn "LiteView stopped right after starting. Last lines of $Log :"
        if (Test-Path $Log) { Get-Content $Log -Tail 15 | Out-Host }
        return
    }

    Write-Host ''
    Write-Host 'LiteView is running. On the other computer, open:' -ForegroundColor Green
    $showArgs = @($hostPy, '--show-address')
    if ($tailscale) { $showArgs += '--tailscale-only' }
    & $venvPy @showArgs
    Write-Host ''
    Write-Host "It starts automatically at every login. Log file: $Log"
    Write-Host 'To stop it: Task Manager -> end "pythonw.exe". To remove it from startup:'
    Write-Host '  Remove-Item "$([Environment]::GetFolderPath(''Startup''))\LiteView.lnk"'
} catch {
    Write-Host "LiteView install failed: $($_.Exception.Message)" -ForegroundColor Red
}
}
