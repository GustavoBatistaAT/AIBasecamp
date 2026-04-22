"""
Basecamp MCP Server
Wraps the Basecamp CLI as an MCP server for Claude Desktop.
"""

import json
import os
import re
import shutil
import subprocess
from html.parser import HTMLParser
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("Basecamp")


class _HTMLStripper(HTMLParser):
    """Strips HTML tags and decodes entities to plain text."""
    def __init__(self):
        super().__init__()
        self._parts = []

    def handle_data(self, data):
        self._parts.append(data)

    def handle_starttag(self, tag, attrs):
        if tag in ("br", "p", "div", "li"):
            self._parts.append("\n")

    def get_text(self):
        text = "".join(self._parts)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return "\n".join(line.rstrip() for line in text.splitlines()).strip()


def _strip_html(html: str) -> str:
    stripper = _HTMLStripper()
    stripper.feed(html)
    return stripper.get_text()


def _clean_html_fields(data: list, fields: list[str]) -> list:
    """Strip HTML from specified fields in a list of dicts."""
    for item in data:
        for field in fields:
            if field in item and item[field]:
                item[field] = _strip_html(str(item[field]))
    return data


def _clean_messages(raw_json: str) -> str:
    """Parse message list JSON and return with HTML-stripped content fields."""
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError:
        return raw_json
    if isinstance(data.get("data"), list):
        data["data"] = _clean_html_fields(data["data"], ["content"])
    return json.dumps(data)


def _find_basecamp_exe() -> str | None:
    """Locate the Basecamp CLI binary on this machine.

    Checks PATH first, then a platform-specific list of install locations.
    Returns None if not found — callers must handle that case.
    """
    if found := shutil.which("basecamp"):
        return found

    candidates = [
        # Windows — installer default and older layout
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\BasecampMCP\basecamp.exe"),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\basecamp\basecamp.exe"),
        # macOS — installer default + Homebrew (arm64 and x64)
        os.path.expanduser("~/Library/Application Support/BasecampMCP/basecamp"),
        "/opt/homebrew/bin/basecamp",
        "/usr/local/bin/basecamp",
        # Linux / manual install
        os.path.expanduser("~/.local/bin/basecamp"),
    ]
    for p in candidates:
        if p and os.path.exists(p):
            return p
    return None


BASECAMP_EXE = _find_basecamp_exe()


def _run(args: list[str]) -> str:
    """Run a basecamp CLI command and return JSON output as a string."""
    if not BASECAMP_EXE or not os.path.exists(BASECAMP_EXE):
        return json.dumps({"ok": False, "error": "Basecamp CLI not found."})
    cmd = [BASECAMP_EXE] + args + ["--json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            err = result.stderr.strip() or result.stdout.strip()
            return json.dumps({"ok": False, "error": err})
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        return json.dumps({"ok": False, "error": "Command timed out after 30 seconds."})
    except Exception as e:
        return json.dumps({"ok": False, "error": str(e)})


# ─────────────────────────────────────────────────────────────────────────────
# PROJECTS
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_projects() -> str:
    """List all Basecamp projects the user has access to."""
    return _run(["projects", "list"])


@mcp.tool()
def show_project(project: str) -> str:
    """Show details of a specific Basecamp project by ID or name."""
    return _run(["projects", "show", "--project", project])


@mcp.tool()
def project_overview(project: str) -> str:
    """
    Combined project drill-down: returns project details, todo lists, open todos,
    and message board posts in a single call. Use this when the user asks about
    a specific project.
    """
    p  = json.loads(_run(["projects", "show", "--project", project]))
    tl = json.loads(_run(["todolists", "list", "--project", project]))
    td = json.loads(_run(["todos", "list", "--project", project, "--status", "incomplete"]))
    ms = json.loads(_clean_messages(_run(["messages", "list", "--project", project])))
    return json.dumps({
        "ok": True,
        "project":   p.get("data", {}),
        "todolists": tl.get("data", []),
        "todos":     td.get("data", []),
        "messages":  ms.get("data", []),
    })


# ─────────────────────────────────────────────────────────────────────────────
# TO-DOS
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_todos(project: str, status: str = "incomplete") -> str:
    """
    List to-dos in a Basecamp project.
    - project: project ID or name
    - status: 'incomplete' (default) or 'completed'
    """
    return _run(["todos", "list", "--project", project, "--status", status])


@mcp.tool()
def show_todo(todo_id: str) -> str:
    """Show full details of a specific to-do by ID."""
    return _run(["todos", "show", todo_id])


@mcp.tool()
def create_todo(title: str, project: str, notes: str = "", due_on: str = "", assignee: str = "") -> str:
    """
    Create a new to-do.
    - title: the to-do text
    - project: project ID or name
    - notes: optional description
    - due_on: optional due date (e.g. 'tomorrow', '2026-04-15')
    - assignee: optional name or email to assign
    """
    args = ["todos", "create", title, "--project", project]
    if notes:    args += ["--notes", notes]
    if due_on:   args += ["--due", due_on]
    if assignee: args += ["--assignee", assignee]
    return _run(args)


@mcp.tool()
def create_todos_bulk(titles: list[str], project: str, due_on: str = "", assignee: str = "") -> str:
    """
    Create multiple to-dos at once from a list of titles.
    - titles: list of to-do titles
    - project: project ID or name
    - due_on: optional due date applied to all
    - assignee: optional person to assign all todos to
    """
    results = []
    for title in titles:
        args = ["todos", "create", title, "--project", project]
        if due_on:   args += ["--due", due_on]
        if assignee: args += ["--assignee", assignee]
        raw = _run(args)
        try:
            data = json.loads(raw)
            results.append({"title": title, "ok": data.get("ok", False)})
        except json.JSONDecodeError:
            results.append({"title": title, "ok": False, "error": "parse error"})
    succeeded = [r for r in results if r["ok"]]
    failed    = [r for r in results if not r["ok"]]
    return json.dumps({
        "ok": True,
        "created": len(succeeded),
        "failed":  len(failed),
        "failures": failed,
        "summary": f"Created {len(succeeded)} of {len(titles)} todos.",
    })


@mcp.tool()
def complete_todo(todo_id: str) -> str:
    """Mark a to-do as complete by its ID."""
    return _run(["todos", "complete", todo_id])


@mcp.tool()
def my_assignments() -> str:
    """List all todos assigned to the currently authenticated user across all projects."""
    return _run(["todos", "list", "--assignee", "me", "--all"])


@mcp.tool()
def reports_overdue() -> str:
    """List all overdue todos across all projects, grouped by how late they are."""
    return _run(["reports", "overdue"])


@mcp.tool()
def reports_assigned(person: str = "") -> str:
    """
    List todos assigned to a specific person across all projects.
    Leave person empty to see all assigned work.
    """
    args = ["reports", "assigned"]
    if person: args += ["--assignee", person]
    return _run(args)


@mcp.tool()
def reports_schedule() -> str:
    """View upcoming schedule entries across all projects."""
    return _run(["reports", "schedule"])


# ─────────────────────────────────────────────────────────────────────────────
# TO-DO LISTS
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_todolists(project: str) -> str:
    """List all to-do lists in a Basecamp project."""
    return _run(["todolists", "list", "--project", project])


# ─────────────────────────────────────────────────────────────────────────────
# MESSAGES
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_messages(project: str) -> str:
    """List all messages on a project's message board with full plain-text content."""
    return _clean_messages(_run(["messages", "list", "--project", project]))


@mcp.tool()
def read_message(message_id: str, project: str) -> str:
    """Read a specific message and all its comments by message ID."""
    msg  = json.loads(_clean_messages(_run(["messages", "show", message_id, "--project", project])))
    cmts = json.loads(_run(["comments", "list", message_id, "--project", project]))
    if isinstance(cmts.get("data"), list):
        cmts["data"] = _clean_html_fields(cmts["data"], ["content"])
    return json.dumps({
        "ok":      True,
        "message": msg.get("data", {}),
        "comments": cmts.get("data", []),
    })


@mcp.tool()
def post_message(title: str, content: str, project: str) -> str:
    """
    Post a new message to a project's message board.
    - title: subject line
    - content: body text (Markdown supported)
    - project: project ID or name
    """
    return _run(["messages", "create", "--title", title, "--content", content, "--project", project])


# ─────────────────────────────────────────────────────────────────────────────
# COMMENTS
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_comments(recording_id: str, project: str) -> str:
    """
    List all comments on any Basecamp item (todo, message, card, etc.) by its ID.
    - recording_id: the ID of the item to fetch comments for
    - project: project ID or name
    """
    raw = _run(["comments", "list", recording_id, "--project", project])
    try:
        data = json.loads(raw)
        if isinstance(data.get("data"), list):
            data["data"] = _clean_html_fields(data["data"], ["content"])
        return json.dumps(data)
    except json.JSONDecodeError:
        return raw


@mcp.tool()
def create_comment(recording_id: str, content: str, project: str) -> str:
    """
    Add a comment to any Basecamp item (todo, message, card, etc.).
    - recording_id: the ID of the item to comment on
    - content: the comment text (Markdown supported)
    - project: project ID or name
    """
    return _run(["comments", "create", recording_id, "--content", content, "--project", project])


# ─────────────────────────────────────────────────────────────────────────────
# CHAT
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def post_chat(message: str, project: str) -> str:
    """Post a message to a project's Campfire chat."""
    return _run(["chat", "post", message, "--project", project])


# ─────────────────────────────────────────────────────────────────────────────
# SCHEDULE
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_schedule_entries(project: str) -> str:
    """List all schedule entries (calendar events) in a Basecamp project."""
    return _run(["schedule", "entries", "--project", project])


@mcp.tool()
def show_schedule_entry(entry_id: str, project: str) -> str:
    """Show a specific schedule entry and its comments by ID."""
    entry = json.loads(_run(["schedule", "show", entry_id, "--project", project]))
    cmts  = json.loads(_run(["comments", "list", entry_id, "--project", project]))
    if isinstance(cmts.get("data"), list):
        cmts["data"] = _clean_html_fields(cmts["data"], ["content"])
    return json.dumps({
        "ok":      True,
        "entry":   entry.get("data", {}),
        "comments": cmts.get("data", []),
    })


# ─────────────────────────────────────────────────────────────────────────────
# PEOPLE
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_people(project: str = "") -> str:
    """
    List people in the Basecamp account, or in a specific project.
    - project: optional project ID or name to filter by
    """
    args = ["people", "list"]
    if project: args += ["--project", project]
    return _run(args)


@mcp.tool()
def my_profile() -> str:
    """Return the profile of the currently authenticated user."""
    return _run(["me"])


# ─────────────────────────────────────────────────────────────────────────────
# DOCS & FILES (VAULT)
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def browse_vault(project: str, folder_id: str = "") -> str:
    """
    Browse the Docs & Files section of a project.
    - project: project ID or name
    - folder_id: optional folder ID to browse inside a subfolder
    """
    args = ["vaults", "list", "--project", project]
    if folder_id: args += ["--vault", folder_id]
    return _run(args)


@mcp.tool()
def list_docs(project: str, folder_id: str = "") -> str:
    """
    List documents in a project's Docs & Files.
    - project: project ID or name
    - folder_id: optional folder ID to list docs within a specific folder
    """
    args = ["docs", "list", "--project", project]
    if folder_id: args += ["--vault", folder_id]
    return _run(args)


# ─────────────────────────────────────────────────────────────────────────────
# CARDS (KANBAN)
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_cards(project: str, column: str = "") -> str:
    """
    List cards in a project's Card Table (Kanban board).
    - project: project ID or name
    - column: optional column name or ID to filter by
    """
    args = ["cards", "list", "--project", project]
    if column: args += ["--column", column]
    return _run(args)


@mcp.tool()
def show_card(card_id: str, project: str) -> str:
    """Show full details of a Kanban card including its steps and comments."""
    card = json.loads(_run(["cards", "show", card_id, "--project", project]))
    cmts = json.loads(_run(["comments", "list", card_id, "--project", project]))
    if isinstance(cmts.get("data"), list):
        cmts["data"] = _clean_html_fields(cmts["data"], ["content"])
    return json.dumps({
        "ok":      True,
        "card":    card.get("data", {}),
        "comments": cmts.get("data", []),
    })


# ─────────────────────────────────────────────────────────────────────────────
# NOTIFICATIONS
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def list_notifications() -> str:
    """List the current user's Basecamp notifications."""
    return _run(["notifications", "list"])


# ─────────────────────────────────────────────────────────────────────────────
# SEARCH
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def search(query: str) -> str:
    """Search across all Basecamp content."""
    return _run(["search", query])


# ─────────────────────────────────────────────────────────────────────────────
# AUTH CHECK
# ─────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def check_auth() -> str:
    """Check whether the Basecamp CLI is authenticated."""
    if not BASECAMP_EXE or not os.path.exists(BASECAMP_EXE):
        return json.dumps({"ok": False, "authenticated": False, "error": "Basecamp CLI not installed."})
    try:
        result = subprocess.run(
            [BASECAMP_EXE, "auth", "token"],
            capture_output=True, text=True, timeout=10
        )
        authenticated = result.returncode == 0 and bool(result.stdout.strip())
        return json.dumps({"ok": True, "authenticated": authenticated})
    except Exception as e:
        return json.dumps({"ok": False, "authenticated": False, "error": str(e)})


if __name__ == "__main__":
    mcp.run()
