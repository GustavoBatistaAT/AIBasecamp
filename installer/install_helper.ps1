# Basecamp MCP — Install Helper
# Called once per phase by the Inno Setup installer.
# Usage: install_helper.ps1 -Phase <Python|Claude|MCP|Configure|Basecamp>

param (
    [string]$Phase        = "",
    [string]$InstallDir   = "",
    [string]$InstallPython = "0",
    [string]$InstallClaude = "0"
)

$ErrorActionPreference = "Stop"
$TempDir = $env:TEMP

# Detect CPU architecture — ARM64 gets native binaries, everything else gets amd64
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }

function Log($msg) { Write-Host "[BasecampMCP] $msg" }

# ── Shared helpers ────────────────────────────────────────────────────────────

function HasWinget {
    return $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
}

function WingetInstall($id, $label) {
    Log "Installing $label via winget..."
    winget install --id $id -e --silent `
        --accept-package-agreements --accept-source-agreements `
        --scope user 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function PythonWorks($exe) {
    # Reject the Microsoft Store execution-alias stub: it lives under WindowsApps
    # and exits non-zero (9009) with a "Python was not found" message on --version.
    if (-not $exe) { return $false }
    if ($exe -match '\\WindowsApps\\') { return $false }
    try {
        & $exe --version *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function FindPython {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($p in $candidates) { if ((Test-Path $p) -and (PythonWorks $p)) { return $p } }
    foreach ($name in @("python", "python3")) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found -and (PythonWorks $found.Source)) { return $found.Source }
    }
    # py launcher — resolve to the real interpreter path
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $exe = & py -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe -and (Test-Path $exe)) { return $exe }
    }
    return $null
}

# Resolve the Claude Desktop config directory. The Microsoft Store (MSIX) build
# reads from a virtualized LocalCache path, NOT %APPDATA%\Claude.
function Get-ClaudeConfigDir {
    $pkgRoot = "$env:LOCALAPPDATA\Packages"
    if (Test-Path $pkgRoot) {
        $pkg = Get-ChildItem $pkgRoot -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($pkg) { return (Join-Path $pkg.FullName "LocalCache\Roaming\Claude") }
    }
    return "$env:APPDATA\Claude"
}

function FindPythonOrFail {
    $p = FindPython
    if (-not $p) {
        Write-Error "Python not found. Install Python 3.10+ from python.org and re-run setup."
        exit 1
    }
    return $p
}

# ── PHASE: Basecamp CLI ───────────────────────────────────────────────────────
# Downloads the correct architecture binary from the latest GitHub release.
# On x64 the installer already bundles basecamp.exe; this phase only runs on ARM64.
function Phase-Basecamp {
    Log "Downloading Basecamp CLI for $Arch..."

    $release = Invoke-RestMethod "https://api.github.com/repos/basecamp/basecamp-cli/releases/latest" `
        -UseBasicParsing -Headers @{ "User-Agent" = "BasecampMCP-Installer" }

    $assetName = "basecamp_*_windows_${Arch}.zip"
    $asset = $release.assets | Where-Object { $_.name -like $assetName } | Select-Object -First 1

    if (-not $asset) {
        Write-Error "No Basecamp CLI release found for windows_${Arch}."
        exit 1
    }

    $zipPath = "$TempDir\basecamp_windows_${Arch}.zip"
    Log "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

    $extractDir = "$TempDir\basecamp_extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    $exe = Get-ChildItem -Path $extractDir -Filter "basecamp.exe" -Recurse | Select-Object -First 1
    if (-not $exe) {
        Write-Error "basecamp.exe not found in downloaded archive."
        exit 1
    }

    Copy-Item $exe.FullName "$InstallDir\basecamp.exe" -Force
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    Log "Basecamp CLI ($Arch) installed to $InstallDir."
}

# ── PHASE: Python ─────────────────────────────────────────────────────────────
function Phase-Python {
    $PythonExe = FindPython
    if ($PythonExe) { Log "Python already installed at: $PythonExe"; return }
    if ($InstallPython -ne "1") {
        Write-Error "Python is required but not installed and installation was not approved."
        exit 1
    }

    Log "Installing Python 3.12 ($Arch)..."
    $installed = $false

    if (HasWinget) {
        $installed = WingetInstall "Python.Python.3.12" "Python 3.12"
        if ($installed) {
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + $env:PATH
            $PythonExe = FindPython
        }
    }

    if (-not $installed -or -not $PythonExe) {
        # Select the correct installer for this architecture
        $pyFile = if ($Arch -eq "arm64") { "python-3.12.10-arm64.exe" } else { "python-3.12.10-amd64.exe" }
        $pyUrl  = "https://www.python.org/ftp/python/3.12.10/$pyFile"

        Log "Downloading $pyFile from python.org..."
        $installer = "$TempDir\python-installer.exe"
        Invoke-WebRequest -Uri $pyUrl -OutFile $installer -UseBasicParsing
        Start-Process -Wait $installer -ArgumentList @(
            "/quiet", "InstallAllUsers=0", "PrependPath=1",
            "Include_launcher=0", "Include_test=0"
        )
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + $env:PATH
        $PythonExe = FindPython
    }

    if (-not $PythonExe) {
        Write-Error "Python installation failed. Please install Python 3.10+ from python.org and re-run setup."
        exit 1
    }
    Log "Python installed at: $PythonExe"
}

# ── PHASE: Claude ─────────────────────────────────────────────────────────────
function Phase-Claude {
    $claudeDir = "$env:APPDATA\Claude"
    $claudeExe = "$env:LOCALAPPDATA\AnthropicClaude\claude.exe"

    if ((Test-Path $claudeDir) -or (Test-Path $claudeExe)) {
        Log "Claude Desktop already installed."
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
        return
    }

    if ($InstallClaude -ne "1") {
        Write-Error "Claude Desktop is required but not installed and installation was not approved."
        exit 1
    }

    Log "Installing Claude Desktop..."
    $installed = $false

    if (HasWinget) {
        $installed = WingetInstall "Anthropic.Claude" "Claude Desktop"
    }

    if (-not $installed) {
        # Download the correct Claude Desktop installer for this architecture
        $claudeUrl = if ($Arch -eq "arm64") {
            "https://claude.ai/api/desktop/win32/arm64/setup/latest/redirect"
        } else {
            "https://claude.ai/api/desktop/win32/x64/setup/latest/redirect"
        }
        Log "Downloading Claude Desktop installer ($Arch)..."
        $installer = "$TempDir\ClaudeSetup.exe"
        Invoke-WebRequest -Uri $claudeUrl -OutFile $installer -UseBasicParsing
        Start-Process -Wait $installer -ArgumentList "--silent"
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    Log "Claude Desktop installed."
}

# ── PHASE: MCP ────────────────────────────────────────────────────────────────
function Phase-MCP {
    $PythonExe = FindPythonOrFail
    Log "Installing Python MCP package..."
    & $PythonExe -m pip install mcp --quiet --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) {
        Write-Error "pip install mcp failed."
        exit 1
    }
    Log "MCP package installed."
}

# ── PHASE: Configure ──────────────────────────────────────────────────────────
function Phase-Configure {
    $PythonExe   = FindPythonOrFail
    $configDir   = Get-ClaudeConfigDir
    $configPath  = Join-Path $configDir "claude_desktop_config.json"
    $serverScript = "$InstallDir\basecamp_mcp_server.py"

    Log "Using Claude config: $configPath"
    # Ensure Claude config dir exists (Store MSIX uses a virtualized LocalCache path)
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    Log "Patching Claude Desktop config..."
    $entry = [PSCustomObject]@{
        command = $PythonExe
        args    = @($serverScript)
        env     = [PSCustomObject]@{
            USERPROFILE  = $env:USERPROFILE
            LOCALAPPDATA = $env:LOCALAPPDATA
            APPDATA      = $env:APPDATA
            PATH         = "$InstallDir;$(Split-Path $PythonExe);$env:SystemRoot\System32"
        }
    }

    if (-not (Test-Path $configPath)) {
        $config = [PSCustomObject]@{
            mcpServers = [PSCustomObject]@{ basecamp = $entry }
        }
    } else {
        $raw = [System.IO.File]::ReadAllText($configPath, $utf8NoBom).TrimStart([char]0xFEFF)
        $config = $raw | ConvertFrom-Json
        if (-not $config.PSObject.Properties["mcpServers"]) {
            $config | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value ([PSCustomObject]@{})
        }
        $config.mcpServers | Add-Member -MemberType NoteProperty -Name "basecamp" -Value $entry -Force
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)
    Log "Claude Desktop config updated."

    # Pin the Basecamp account ID. REQUIRED — the CLI does NOT infer it from auth;
    # without it every account-scoped call fails with "--account is required".
    # Artistic Tile is a single-account org (3268280). Multi-account orgs should
    # instead derive this from https://launchpad.37signals.com/authorization.json
    # after login and let the user pick.
    $bcExe = "$InstallDir\basecamp.exe"
    if (Test-Path $bcExe) {
        & $bcExe config set account_id 3268280 --global 2>&1 | Out-Null
        Log "Basecamp account ID set (3268280)."
    } else {
        Log "WARNING: basecamp.exe not found; account_id not set."
    }
}

# ── PHASE: Restart ────────────────────────────────────────────────────────────
# Re-launches Claude Desktop after configuration. Handles both the Microsoft
# Store (MSIX) build and the standalone/winget build.
function Phase-Restart {
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($pkg) {
        try {
            $appx = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($appx) {
                $appId = (Get-AppxPackageManifest $appx).Package.Applications.Application.Id
                if ($appId) {
                    Start-Process "shell:AppsFolder\$($appx.PackageFamilyName)!$appId"
                    Log "Restarted Claude Desktop (Store)."
                    return
                }
            }
        } catch { Log "Could not auto-launch Store Claude ($_); open it manually." }
    }
    $exe = "$env:LOCALAPPDATA\AnthropicClaude\claude.exe"
    if (Test-Path $exe) { Start-Process $exe; Log "Restarted Claude Desktop." }
    else { Log "Claude Desktop not auto-launched; please open it manually." }
}

# ── PHASE: Unconfigure ────────────────────────────────────────────────────────
# Removes the basecamp entry from the Claude config on uninstall (Store-aware).
function Phase-Unconfigure {
    $configPath = Join-Path (Get-ClaudeConfigDir) "claude_desktop_config.json"
    if (-not (Test-Path $configPath)) { return }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($configPath, $utf8NoBom).TrimStart([char]0xFEFF)
    try { $config = $raw | ConvertFrom-Json } catch { return }
    if ($config.PSObject.Properties["mcpServers"] -and
        $config.mcpServers.PSObject.Properties["basecamp"]) {
        $config.mcpServers.PSObject.Properties.Remove("basecamp")
        [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), $utf8NoBom)
        Log "Removed basecamp from Claude config."
    }
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
switch ($Phase) {
    "Basecamp"    { Phase-Basecamp }
    "Python"      { Phase-Python }
    "Claude"      { Phase-Claude }
    "MCP"         { Phase-MCP }
    "Configure"   { Phase-Configure }
    "Restart"     { Phase-Restart }
    "Unconfigure" { Phase-Unconfigure }
    default {
        Write-Error "Unknown phase: '$Phase'. Use Basecamp, Python, Claude, MCP, Configure, Restart, or Unconfigure."
        exit 1
    }
}

Log "Phase '$Phase' complete."
exit 0
