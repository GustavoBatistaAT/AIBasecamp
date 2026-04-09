# Basecamp + Claude Desktop Setup Guide
**Prepared by: Artistic Tile IT**

---

## Overview

This guide sets up the official Basecamp CLI as an MCP (Model Context Protocol) server so Claude Desktop can interact with Basecamp directly — reading projects, todos, messages, and more.

**What you'll need:**
- Windows 10/11
- Internet connection
- A Basecamp account (already have one)
- Claude Desktop app (install first if not already installed)

---

## Step 1: Install Scoop (Windows Package Manager)

Scoop is needed to install the Basecamp CLI on Windows.

Open **PowerShell** (search "PowerShell" in the Start menu) and run:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
```

Verify it worked:
```powershell
scoop --version
```

---

## Step 2: Install the Basecamp CLI

In the same PowerShell window:

```powershell
scoop bucket add basecamp https://github.com/basecamp/homebrew-tap
scoop install basecamp-cli
```

Verify:
```powershell
basecamp --version
```

You should see something like: `basecamp version X.Y.Z`

---

## Step 3: Authenticate with Basecamp

```powershell
basecamp auth login
```

- This opens your browser automatically.
- Log in with your Basecamp account and click **Authorize**.
- Return to PowerShell — it should say **Authenticated**.

Verify:
```powershell
basecamp auth status
```

---

## Step 4: Configure Claude Desktop

The Claude Desktop app reads its MCP server settings from a JSON config file.

### 4a. Find (or create) the config file

The config file lives at:
```
C:\Users\<YourName>\AppData\Roaming\Claude\claude_desktop_config.json
```

To open it quickly, press `Win + R`, paste this, and hit Enter:
```
%APPDATA%\Claude\
```

If `claude_desktop_config.json` doesn't exist yet, create a new text file with that exact name.

### 4b. Edit the config file

Open the file in Notepad and paste the following:

```json
{
  "mcpServers": {
    "basecamp": {
      "command": "basecamp",
      "args": ["mcp", "serve"],
      "env": {}
    }
  }
}
```

> **Note:** If the file already has content (other MCP servers), add the `"basecamp": { ... }` block inside the existing `"mcpServers"` section rather than replacing everything.

Save the file.

### 4c. Restart Claude Desktop

Close and reopen Claude Desktop. After restarting, you should see a small hammer icon (tools) in the chat input area — this confirms MCP servers are active.

---

## Step 5: Test It

In Claude Desktop, try asking:

> "Show me my Basecamp projects"

or

> "What are my assigned todos in Basecamp?"

Claude will use the Basecamp CLI in the background to fetch the information.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `basecamp: command not found` | Restart PowerShell after installing Scoop/basecamp |
| Browser doesn't open for login | Run `basecamp auth login` again |
| Claude doesn't show hammer icon | Double-check the JSON file — it must be valid JSON (no trailing commas) |
| Wrong Basecamp account | Run `basecamp auth logout` then `basecamp auth login` |

**Diagnostics:**
```powershell
basecamp doctor
```

---

## Reference

- Basecamp CLI GitHub: https://github.com/basecamp/basecamp-cli
- Claude Desktop download: https://claude.ai/download
- Scoop: https://scoop.sh
