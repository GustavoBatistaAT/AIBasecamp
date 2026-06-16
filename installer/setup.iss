; Basecamp MCP Installer
; Compiles to: installer\Output\BasecampMCP_Setup.exe
; Build with: Inno Setup Compiler (https://jrsoftware.org/isinfo.php)

#define AppName      "Basecamp AI Assistant"
#define AppVersion   "1.4"
#define AppPublisher "Artistic Tile IT"
#define AppURL       "https://github.com/GustavoBatistaAT/AIBasecamp"
#define InstallDir   "{localappdata}\Programs\BasecampMCP"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
DefaultDirName={#InstallDir}
DisableDirPage=yes
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=BasecampMCP_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\basecamp.exe
CloseApplications=no
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Welcome to the Basecamp AI Assistant Setup
WelcomeLabel2=This will install the Basecamp AI Assistant on your computer.%n%nSetup will check for required software and ask your permission before installing anything additional.%n%nClick Next to continue.
FinishedHeadingLabel=Basecamp AI Assistant is almost ready
FinishedLabel=Installation is complete.%n%nClick Finish to connect your Basecamp account. Your browser will open — log in and click Authorize to finish.

[Files]
Source: "..\basecamp.exe";            DestDir: "{app}"; Flags: ignoreversion
Source: "..\app\basecamp_mcp_server.py"; DestDir: "{app}"; Flags: ignoreversion
; Kept after install (no deleteafterinstall) so the uninstaller can call -Phase Unconfigure
Source: "install_helper.ps1";         DestDir: "{app}"; Flags: ignoreversion

[Run]
; 1. Close Claude Desktop if running (excludes Claude Code CLI)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -Command ""Get-Process claude -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -notlike '*claude-code*' }} | Stop-Process -Force -ErrorAction SilentlyContinue"""; \
  StatusMsg: "Closing Claude Desktop..."; \
  Flags: runhidden waituntilterminated

; 1b. On ARM64: download native ARM64 basecamp.exe (overwrites the bundled x64 binary)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Basecamp -InstallDir ""{app}"""; \
  StatusMsg: "Downloading ARM64 Basecamp CLI..."; \
  Check: IsArm64; \
  Flags: runhidden waituntilterminated

; 2. Install Python (only runs if user approved it)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Python -InstallDir ""{app}"" -InstallPython {code:GetInstallPython} -InstallClaude {code:GetInstallClaude}"; \
  StatusMsg: "Installing Python 3.12..."; \
  Check: ShouldInstallPython; \
  Flags: runhidden waituntilterminated

; 3. Install Claude Desktop (only runs if user approved it)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Claude -InstallDir ""{app}"" -InstallPython {code:GetInstallPython} -InstallClaude {code:GetInstallClaude}"; \
  StatusMsg: "Installing Claude Desktop..."; \
  Check: ShouldInstallClaude; \
  Flags: runhidden waituntilterminated

; 4. Install MCP Python package
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase MCP -InstallDir ""{app}"" -InstallPython {code:GetInstallPython} -InstallClaude {code:GetInstallClaude}"; \
  StatusMsg: "Installing Python packages..."; \
  Flags: runhidden waituntilterminated

; 5. Configure Claude Desktop config + Basecamp account ID
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Configure -InstallDir ""{app}"" -InstallPython {code:GetInstallPython} -InstallClaude {code:GetInstallClaude}"; \
  StatusMsg: "Configuring Basecamp AI Assistant..."; \
  Flags: runhidden waituntilterminated

; 6. Restart Claude Desktop (handles Store MSIX + standalone)
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Restart -InstallDir ""{app}"""; \
  StatusMsg: "Starting Claude Desktop..."; \
  Flags: runhidden waituntilterminated

; 7. Basecamp auth login — postinstall checkbox on final screen
Filename: "{app}\basecamp.exe"; \
  Parameters: "auth login"; \
  Description: "Connect your Basecamp account (opens browser)"; \
  StatusMsg: "Opening Basecamp login..."; \
  Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; \
  Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install_helper.ps1"" -Phase Unconfigure -InstallDir ""{app}"""; \
  RunOnceId: "RemoveBasecampMCPConfig"; \
  Flags: runhidden waituntilterminated

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
var
  NeedsPython: Boolean;
  NeedsClaude: Boolean;
  UserWantsPython: Boolean;
  UserWantsClaude: Boolean;

// ── Architecture detection ────────────────────────────────────────────────────
function IsArm64(): Boolean;
begin
  Result := (GetEnv('PROCESSOR_ARCHITECTURE') = 'ARM64');
end;

// ── Detect Python ─────────────────────────────────────────────────────────────
// Real interpreters exit 0 on '--version'. The Microsoft Store execution-alias
// stub (WindowsApps\python.exe) exits 9009, so a plain 'where python' is not
// enough — it would falsely report Python as installed.
function PythonRuns(Cmd: String): Boolean;
var
  Code: Integer;
begin
  Result := Exec('cmd.exe', '/C ' + Cmd + ' --version', '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function FindPython(): Boolean;
var
  Candidates: TArrayOfString;
  LocalAppData: String;
  i: Integer;
begin
  LocalAppData := GetEnv('LOCALAPPDATA');
  SetArrayLength(Candidates, 5);
  Candidates[0] := LocalAppData + '\Programs\Python\Python312\python.exe';
  Candidates[1] := LocalAppData + '\Programs\Python\Python311\python.exe';
  Candidates[2] := LocalAppData + '\Programs\Python\Python310\python.exe';
  Candidates[3] := 'C:\Python312\python.exe';
  Candidates[4] := 'C:\Python311\python.exe';
  for i := 0 to GetArrayLength(Candidates) - 1 do
    if FileExists(Candidates[i]) then begin Result := True; Exit; end;
  if PythonRuns('python') then begin Result := True; Exit; end;
  if PythonRuns('py -3') then begin Result := True; Exit; end;
  Result := False;
end;

// ── Detect Claude Desktop ─────────────────────────────────────────────────────
function FindClaude(): Boolean;
var
  AppData, LocalAppData: String;
  FindRec: TFindRec;
begin
  // Use GetEnv so resolution works at InitializeSetup time (before shell constants load)
  AppData      := GetEnv('APPDATA');
  LocalAppData := GetEnv('LOCALAPPDATA');

  // EXE / winget install — Claude writes user data to %APPDATA%\Claude
  if DirExists(AppData + '\Claude') then begin Result := True; Exit; end;

  // Winget EXE path (non-Store install)
  if FileExists(LocalAppData + '\AnthropicClaude\claude.exe') then begin Result := True; Exit; end;

  // Microsoft Store (MSIX) install — match any versioned package folder
  // (%LOCALAPPDATA%\Packages\Claude_*), so detection survives version bumps.
  if FindFirst(LocalAppData + '\Packages\Claude_*', FindRec) then
  begin
    try
      Result := True;
      Exit;
    finally
      FindClose(FindRec);
    end;
  end;

  Result := False;
end;

// ── Prompt helpers ────────────────────────────────────────────────────────────
function GetInstallPython(Param: String): String;
begin
  if UserWantsPython then Result := '1' else Result := '0';
end;

function GetInstallClaude(Param: String): String;
begin
  if UserWantsClaude then Result := '1' else Result := '0';
end;

// ── Check functions — gate [Run] entries so status messages only appear when needed
function ShouldInstallPython(): Boolean;
begin
  Result := UserWantsPython;
end;

function ShouldInstallClaude(): Boolean;
begin
  Result := UserWantsClaude;
end;

// ── Pre-install checks and prompts ────────────────────────────────────────────
function InitializeSetup(): Boolean;
var
  Ans: Integer;
begin
  Result := True;
  UserWantsPython := False;
  UserWantsClaude := False;

  NeedsPython := not FindPython();
  NeedsClaude := not FindClaude();

  // Prompt for Python
  if NeedsPython then
  begin
    Ans := MsgBox(
      'Python was not found on this computer.' + #13#10 + #13#10 +
      'Python is required to run the Basecamp AI Assistant.' + #13#10 + #13#10 +
      'Would you like the installer to download and install Python 3.12 now?' + #13#10 +
      '(An internet connection is required)',
      mbConfirmation, MB_YESNOCANCEL);
    if Ans = IDCANCEL then begin Result := False; Exit; end;
    if Ans = IDNO then
    begin
      MsgBox(
        'Setup cannot continue without Python.' + #13#10 + #13#10 +
        'Please install Python 3.10 or later from python.org, then run this setup again.' + #13#10 +
        'Make sure to check "Add Python to PATH" during installation.',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    UserWantsPython := True;
  end;

  // Prompt for Claude Desktop
  if NeedsClaude then
  begin
    Ans := MsgBox(
      'Claude Desktop was not found on this computer.' + #13#10 + #13#10 +
      'Claude Desktop is required to use the Basecamp AI Assistant.' + #13#10 + #13#10 +
      'Would you like the installer to download and install Claude Desktop now?' + #13#10 +
      '(An internet connection is required)',
      mbConfirmation, MB_YESNOCANCEL);
    if Ans = IDCANCEL then begin Result := False; Exit; end;
    if Ans = IDNO then
    begin
      MsgBox(
        'Setup cannot continue without Claude Desktop.' + #13#10 + #13#10 +
        'Please install Claude Desktop from claude.ai/download, then run this setup again.',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    UserWantsClaude := True;
  end;
end;
