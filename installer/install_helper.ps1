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

function FindPython {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe",
        "C:\Python312\python.exe",
        "C:\Python311\python.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    return $null
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
    $configPath  = "$env:APPDATA\Claude\claude_desktop_config.json"
    $serverScript = "$InstallDir\basecamp_mcp_server.py"

    # Ensure Claude config dir exists
    New-Item -ItemType Directory -Force -Path "$env:APPDATA\Claude" | Out-Null

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

    # Initialise Basecamp global config with account ID
    $bcConfigDir = "$env:USERPROFILE\.config\basecamp"
    New-Item -ItemType Directory -Force -Path $bcConfigDir | Out-Null
    $bcConfig = "$bcConfigDir\config.json"
    if (Test-Path $bcConfig) {
        $raw = [System.IO.File]::ReadAllText($bcConfig, $utf8NoBom).TrimStart([char]0xFEFF)
        $cfg = $raw | ConvertFrom-Json
    } else {
        $cfg = [PSCustomObject]@{}
    }
    if (-not $cfg.PSObject.Properties["account_id"]) {
        $cfg | Add-Member -MemberType NoteProperty -Name "account_id" -Value "3268280"
    }
    [System.IO.File]::WriteAllText($bcConfig, ($cfg | ConvertTo-Json), $utf8NoBom)
    Log "Basecamp account ID set."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
switch ($Phase) {
    "Basecamp"  { Phase-Basecamp }
    "Python"    { Phase-Python }
    "Claude"    { Phase-Claude }
    "MCP"       { Phase-MCP }
    "Configure" { Phase-Configure }
    default {
        Write-Error "Unknown phase: '$Phase'. Use Basecamp, Python, Claude, MCP, or Configure."
        exit 1
    }
}

Log "Phase '$Phase' complete."
exit 0
