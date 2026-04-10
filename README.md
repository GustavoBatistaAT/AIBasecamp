# Basecamp AI Assistant

A Claude Desktop integration that lets Artistic Tile team members interact with Basecamp using natural language — read projects, manage todos, post messages, check schedules, and more — all from within Claude Desktop.

Built by Artistic Tile IT

---

## How It Works

```
Claude Desktop  ──MCP──►  Python MCP Server  ──subprocess──►  Basecamp CLI  ──OAuth──►  Basecamp API
```

- **Claude Desktop** handles the conversation and AI reasoning
- **Python MCP Server** (`app/basecamp_mcp_server.py`) exposes 30 Basecamp tools via the [Model Context Protocol](https://modelcontextprotocol.io)
- **Basecamp CLI** (official, by 37signals) handles all API calls and OAuth token storage
- Authentication is stored securely in the Windows Credential Store — no API keys in config files

---

## Features

| Category | What you can ask |
|---|---|
| Projects | List all projects, drill down into any project |
| Todos | View, create, complete, and bulk-create tasks |
| Messages | Read message boards, post and reply |
| Schedule | View upcoming events and milestones |
| People | Look up team members and profiles |
| Cards | Browse Kanban card tables |
| Docs & Files | Browse the Vault and document lists |
| Reports | Overdue items, assigned tasks, schedule reports |
| Search | Full-text search across all of Basecamp |
| Notifications | Check your notification inbox |

Claude presents results in clean tables, drills down two levels into projects, and can act as a project advisor — flagging overdue items, suggesting task assignments, and recommending focus areas.

---

## Installation

Run the installer — it handles everything automatically:

```
BasecampMCP_Setup.exe
```

**What the installer does:**
1. Detects whether Python 3.12 and Claude Desktop are already installed (prompts to install only if missing)
2. Installs the Basecamp CLI to `%LOCALAPPDATA%\Programs\BasecampMCP\`
3. Installs the `mcp` Python package
4. Patches `%APPDATA%\Claude\claude_desktop_config.json` to register the MCP server
5. Sets the Artistic Tile Basecamp account ID globally
6. Restarts Claude Desktop automatically

After the installer finishes, a checkbox offers to open the browser for Basecamp login (required on first run).

### Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Windows | 10 / 11 | 64-bit |
| Claude Desktop | Latest | Installer can download it |
| Python | 3.10+ | Installer can download 3.12 |
| Internet connection | — | Required for Basecamp auth |

> **Compiling the installer** requires [Inno Setup 6](https://jrsoftware.org/isdl.php). Run:
> ```
> iscc.exe installer\setup.iss
> ```
> Output: `installer\Output\BasecampMCP_Setup.exe`

---

## First-Time Setup After Install

1. Open Claude Desktop
2. Confirm the Basecamp MCP server is active:
   - Go to **File → Settings → Developer** — `basecamp` should appear with a blue status
   
   To disconnect: click **Remove** next to `basecamp` in that same screen, then restart Claude Desktop.
3. Run Basecamp authentication if not done during install:
   - Open PowerShell and run: `basecamp auth login`
   - Authorize in the browser that opens
4. In Claude Desktop, open or create a **Project** and paste the contents of `docs/system-prompt.md` as the project instructions

---

## Repository Structure

```
Basecamp-MCP/
├── app/
│   └── basecamp_mcp_server.py      # Python MCP server — 27 Basecamp tools
├── config/
│   └── claude_desktop_config.json  # Reference MCP config (template)
├── docs/
│   ├── system-prompt.md            # System prompt for Claude Desktop project
│   └── setup-guide.md              # Manual setup guide (no installer)
├── installer/
│   ├── setup.iss                   # Inno Setup script
│   ├── install_helper.ps1          # PowerShell install phases
│   └── Output/                     # Compiled .exe lives here (gitignored)
└── .gitignore
```

---

## MCP Tools Reference

The server exposes 30 tools. Claude routes to them automatically based on natural language.

| Tool | Description |
|---|---|
| `list_projects` | List all Basecamp projects |
| `show_project` | Project details |
| `project_overview` | Combined drill-down: details + todos + messages |
| `list_todolists` | Todo lists within a project |
| `list_todos` | Todos (filter by status/assignee) |
| `show_todo` | Single todo details |
| `create_todo` | Create a single todo |
| `create_todos_bulk` | Create multiple todos at once |
| `complete_todo` | Mark a todo complete |
| `list_messages` | Message board posts |
| `read_message` | Full message with comments |
| `post_message` | Post a new message |
| `list_comments` | Comments on a resource |
| `create_comment` | Post a comment |
| `post_chat` | Send a Campfire chat message |
| `list_schedule_entries` | Upcoming schedule entries |
| `show_schedule_entry` | Single event details |
| `list_people` | Team members |
| `my_profile` | Current user profile |
| `my_assignments` | Your assigned todos |
| `list_cards` | Kanban card table |
| `show_card` | Single card details |
| `browse_vault` | Vault / file storage |
| `list_docs` | Documents list |
| `list_notifications` | Notification inbox |
| `reports_overdue` | Overdue todos report |
| `reports_assigned` | Assigned todos report |
| `reports_schedule` | Schedule report |
| `search` | Full-text search |
| `check_auth` | Verify Basecamp authentication |

---

## Security Notes

- OAuth tokens are stored in the **Windows Credential Store** (managed by the Basecamp CLI) — never written to disk in plaintext
- The MCP server uses `subprocess.run()` with list arguments — no shell interpolation, immune to command injection
- No Basecamp API keys or secrets are stored anywhere in this repository
- `basecamp.exe` and compiled installer output are excluded from git via `.gitignore`

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Basecamp not showing in File → Settings → Developer | Restart Claude Desktop; check `claude_desktop_config.json` has `mcpServers.basecamp` |
| `basecamp: command not found` | Verify `%LOCALAPPDATA%\Programs\BasecampMCP\basecamp.exe` exists |
| Auth error / token expired | Run `basecamp auth login` in PowerShell |
| Malformed config warning from CLI | Re-run the installer Configure phase or check `~/.config/basecamp/config.json` for BOM |
| Python not found | Ensure Python 3.10+ is installed and on PATH |

---

## References

- [Basecamp CLI](https://github.com/basecamp/basecamp-cli) — official CLI by 37signals
- [Model Context Protocol](https://modelcontextprotocol.io) — MCP specification
- [FastMCP](https://pypi.org/project/mcp/) — Python MCP library
- [Claude Desktop](https://claude.ai/download) — Anthropic desktop app
- [Inno Setup](https://jrsoftware.org/isinfo.php) — Windows installer compiler
