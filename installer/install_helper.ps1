# Basecamp MCP — Install Helper
# Called once per phase by the Inno Setup installer.
# Usage: install_helper.ps1 -Phase <Python|Claude|MCP|Configure>

param (
    [string]$Phase        = "",
    [string]$InstallDir   = "",
    [string]$InstallPython = "0",
    [string]$InstallClaude = "0"
)

$ErrorActionPreference = "Stop"
$TempDir = $env:TEMP

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

# ── PHASE: Python ─────────────────────────────────────────────────────────────
function Phase-Python {
    $PythonExe = FindPython
    if ($PythonExe) { Log "Python already installed at: $PythonExe"; return }
    if ($InstallPython -ne "1") {
        Write-Error "Python is required but not installed and installation was not approved."
        exit 1
    }

    Log "Installing Python 3.12..."
    $installed = $false

    if (HasWinget) {
        $installed = WingetInstall "Python.Python.3.12" "Python 3.12"
        if ($installed) {
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","User") + ";" + $env:PATH
            $PythonExe = FindPython
        }
    }

    if (-not $installed -or -not $PythonExe) {
        Log "Downloading Python 3.12 from python.org..."
        $installer = "$TempDir\python-installer.exe"
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe" `
            -OutFile $installer -UseBasicParsing
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
        Log "Downloading Claude Desktop installer..."
        $installer = "$TempDir\ClaudeSetup.exe"
        Invoke-WebRequest `
            -Uri "https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe" `
            -OutFile $installer -UseBasicParsing
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
        $config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
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
    "Python"    { Phase-Python }
    "Claude"    { Phase-Claude }
    "MCP"       { Phase-MCP }
    "Configure" { Phase-Configure }
    default {
        Write-Error "Unknown phase: '$Phase'. Use Python, Claude, MCP, or Configure."
        exit 1
    }
}

Log "Phase '$Phase' complete."
exit 0
