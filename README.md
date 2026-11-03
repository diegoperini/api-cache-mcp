# api-cache-mcp

A local MCP server that gives your AI agents a shared, semantic cache of
everything they learn about the APIs they use: CLI tools, other MCP servers,
REST APIs, SDKs, and apps such as Blender, Unreal Engine, Krita or Cheat
Engine. Agents ask it questions and tell it what they discovered, in plain
language. A small Claude model (Haiku by default) reads the relevant cache,
answers or edits it, and forgets everything before the next call.

- Runs on Windows with the built-in Windows PowerShell 5.1. Nothing to
  install, no dependencies.
- Works with any MCP client that launches local (stdio) servers, such as
  Claude Desktop or Claude Code.
- **Local use only.** See [Security](#security-local-use-only).

> [!NOTE]
> **Maintainer's note**
>
> Hi! Obviously, everything in this README is written by an AI, but this one paragraph is fully mine to write. I built this because I drive headless Blender, Unreal Engine and many other tools that may or may not have any MCPs, and over time, I realized my token consumption was growing beyond what I can afford with my modest budget. This tool helped me save money and also gave a small speed boost to the responses to my prompts. If you wanna give it a try, fork it and make it yours by adding custom context. You can also use it as is, since it already provides the toolset to populate it with knowledge. This tool cannot have conversations, and that's not a bug but a feature. Enjoy hacking!

## How it works

- Each agent has one cache per API: a free-form text file in that agent's
  own words, at `cache\<agent>\<api>.md`.
- Every `cache_query`, `cache_insert`, `cache_upsert` or `cache_delete` starts
  a fresh Claude call that sees, in this fixed order:
  1. `system-prompt.md` (your standing instructions)
  2. every text file in `context\`, sorted by path
  3. the requesting agent's whole cache for the requested API
  4. the request itself
- **Lookups** return a status: `covered`, `partial`, `not_covered`, or
  `refused` when the request is too ambiguous to answer reliably.
  - The `answer` only uses what is in the cache.
  - When the cache doesn't fully cover the request, a separate `guess` field
    may add one short paragraph from general knowledge, marked as unverified.
    The server cuts it to one paragraph of at most about 600 characters.
- **Changes** start with a decision: `apply`, `no_change`, or `refuse`.
  - Unclear, vague or off-topic requests, and requests to store secrets, are
    refused with a reason.
  - Applied changes are small edits anchored on exact passages of the file.
    The server writes them only if every quoted passage is found exactly
    once. Otherwise the file stays untouched and Claude gets one retry.
  - A file lock keeps two server instances from overwriting each other.
- **Prompt caching is always on.** Parts 1-3 are sent as a cached prefix, so
  repeated lookups on the same cache cost about a tenth of the normal input
  price once cached. Caching needs at least about 512 tokens (roughly 2,000
  characters) of prefix for Haiku 5.5.

## Requirements

- Windows 10 or 11, with Windows PowerShell 5.1 (included with Windows).
- A Claude API key from the [Claude Console](https://console.anthropic.com).
  If your Claude plan includes monthly API credits, create the key in the
  Console organization linked to your plan, so calls use those credits.
- Microsoft Edge (optional) for the debug window. Without it, the debug page
  opens in your default browser.

## Install

1. Get the project into a folder of your choice. You can clone it:

   ```
   git clone https://github.com/diegoperini/api-cache-mcp.git
   ```

   Or download the ZIP and extract it. The rest of this guide calls that
   folder `<install-dir>`, for example `C:\Tools\api-cache-mcp`.
2. In `<install-dir>`, copy `.env.example` to `.env` and add your key:

   ```
   ANTHROPIC_API_KEY=sk-ant-...
   ```

   Optional settings:

   | Setting | Default | Meaning |
   | --- | --- | --- |
   | `CLAUDE_MODEL` | `claude-haiku-5-5` | Model for every call |
   | `CLAUDE_MAX_TOKENS` | `4096` | Output limit per call |
   | `CLAUDE_CACHE_TTL` | `5m` | Prompt cache lifetime: `5m` or `1h` |
   | `MCP_UI_PORT` | `8765` | Debug page port (tries the next 9 if busy). Only held while the debug window is open |
   | `MCP_UI_OPEN` | `true` | Open the debug window at startup |

3. Optionally, edit `system-prompt.md` and put reference material in
   `context\`.
4. Check that it starts: run `<install-dir>\mcp-server.bat` in a terminal and
   paste this line:

   ```
   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
   ```

   You should get one line of JSON back, and the debug window should open.
   Press Ctrl+C to stop it.

## Connect it to Claude

Replace `C:\Tools\api-cache-mcp` with your `<install-dir>`. In JSON, write
each backslash twice.

**Claude Desktop:** open Settings, then Developer, then Edit Config. Add this
to `mcpServers` in `claude_desktop_config.json`, then fully quit and reopen
Claude Desktop:

```json
"api-cache": {
  "command": "cmd",
  "args": ["/c", "C:\\Tools\\api-cache-mcp\\mcp-server.bat"]
}
```

`cmd /c` is needed because Claude starts servers through Node.js, which
refuses to launch `.bat` files directly.

**Claude Code:**

```
claude mcp add api-cache --scope user -- cmd /c C:\Tools\api-cache-mcp\mcp-server.bat
```

**Other MCP clients:** run `cmd /c <install-dir>\mcp-server.bat` as a stdio
server.

## Tools

| Tool | What it does |
| --- | --- |
| `cache_guide` | Explains the cache to an agent. With `agent`, also shows its caches and migration status. Agents should call this first. |
| `cache_query` | Look something up in an agent's cache for an API. |
| `cache_insert` | Record new knowledge. Duplicates are reported; contradictions are refused (use upsert). |
| `cache_upsert` | Correct or add knowledge. Rewrites what a discovery contradicts. |
| `cache_delete` | Remove knowledge described in plain language. |
| `cache_load` | Raw text of a cache, for inspection. |
| `cache_import` | Copy an existing cache in verbatim (migration). |
| `vault_store` / `vault_read` | Fallback vault, write-once: records where an agent's original cache went, or keeps a copy. Tracks `migration_complete`. |
| `debug_open_webview` | Open or focus the debug window. Never opens a second one. |
| `ask_claude` | One stateless prompt to Claude, not tied to a cache. |

Every call names the agent (`agent`, a stable unique name such as `scout`)
and, for cache calls, the API (`api`, such as `blender`). Names use 1-64
lowercase letters, digits, `.`, `_` or `-`. An agent can only change its own
caches. When an agent connects, the server also sends it short instructions
to prefer this cache over its own and to migrate.

## Migrating an agent's existing cache

Ask the agent to call `cache_guide` with its name and follow the migration
steps. For each API, the agent:

1. copies its old cache text in with `cache_import` (stored as is),
2. checks it with `cache_load` and a test `cache_query`,
3. keeps the original in a vault,
4. uses only this tool from then on.

The "vault" name is shared on purpose. An agent that already has a vault of
its own (for example, an artifact named after the agent) always uses that
one. At most it calls `vault_store` with just a `location`, to record where
the original went and mark the migration complete. Only an agent with no
vault of its own sends the content, and this server keeps a write-once copy.
That way an existing agent never switches to a new vault by accident.

## Debug window

When the server starts, it opens a small Edge app window on
`http://localhost:8765/`. It shows:

- every Claude call: the tool, the request, the answer or the edits, and the
  tokens and cache use;
- a live server log;
- an input box that sends a test prompt through `ask_claude` (Enter sends,
  Shift+Enter adds a new line).

There is only ever one window, and it shows the calls of every connected
client. Each MCP client starts its own copy of the server (Claude Desktop can
start two), but only the first copy, the primary, serves: it holds
`primary.lock` in the install folder, owns the window and the history, and
answers every client. Copies started later open no window; they pass their
client's messages to the primary over a named pipe. If the primary goes
away, one of them takes over.

The primary keeps running after the client that started it disconnects,
while other clients are connected or the window is open. When nothing is
left, it stops and closes the window. If you close the window by accident,
ask any connected agent to call `debug_open_webview`.

The port is only held while the window is open: the primary takes a port
when the window opens and releases it when the window closes, so a closed
window never blocks other programs. The server notices a closed window in
three ways:

- the page says goodbye when it closes (after 5 seconds, so a reload keeps
  the port);
- the Edge window's process no longer has a window (checked every 5 seconds);
- the page sends no request for 3 minutes (a backstop, for example for a
  default-browser tab left open after the computer slept).

Reopening may use a different port. History and the server log are kept in
memory while the window is closed and show up again when it reopens. With
`MCP_UI_OPEN=false`, no port is taken until an agent calls
`debug_open_webview`.

## Files

| Path | What it is |
| --- | --- |
| `mcp-server.bat` | Launcher. This is what the MCP client runs. |
| `mcp-server.ps1` | The server and its debug page. |
| `.env.example` | Settings template. Copy it to `.env`. |
| `system-prompt.md` | Standing instructions sent first on every call. |
| `context\` | Extra reference files, sent after the system prompt. Empty and binary files are skipped. |
| `cache\<agent>\<api>.md` | The caches, plain text. Created at runtime; you can read or edit them by hand. |
| `cache\<agent>\_vault\` | Fallback vault for agents that have no vault of their own. |
| `history.jsonl` | Log of every Claude call, shown on the debug page. Created at runtime. |
| `primary.lock` | Held by the copy of the server that serves every client. Created at runtime; ignored by git. |

`.env`, `cache\`, `history.jsonl` and the contents of `context\` are listed
in `.gitignore`, so your key and your data stay out of the repository.

## Security: local use only

This server is built for one person on one computer. **Run it only on your
own machine and only reach it through `localhost`.** Nothing it serves
locally is encrypted.

- **The debug page is plain HTTP**, with no TLS and no login.
  - It listens on `localhost` only, rejects connections from other machines,
    and needs a random token that changes on every launch. These guard
    against accidents and against other websites open in your browser. They
    are not a replacement for encryption or authentication.
  - Never expose the port: no port forwarding, reverse proxies, tunnels (such
    as ngrok or Cloudflare Tunnel), published container ports, or
    firewall exceptions.
  - Don't run it on a shared, multi-user or remote machine.
- **Everything on disk is plain text**, in your install folder: your API key
  in `.env`, the caches, the vault, and `history.jsonl`, which holds every
  prompt and answer. Keep the folder private and don't commit those files.
- **Calls to the Claude API use HTTPS.** The server refuses an
  `ANTHROPIC_BASE_URL` that isn't `https://`, except `http://localhost` for
  local testing.
- **MCP traffic** goes over the stdin and stdout of a process your MCP
  client starts on the same machine. It never touches the network.
- **Never store secrets** (keys, tokens, passwords) in caches. The cache
  agent is told to refuse them, but don't rely on that alone.

## Troubleshooting

- **Tools don't show up in Claude Desktop:** check
  `%APPDATA%\Claude\logs\mcp-server-api-cache.log`. The server only writes to
  the terminal on a fatal error, or when no debug port is free.
- **A call waits while another client's call runs:** one server answers
  every client, one call at a time, so calls from several clients queue up
  behind each other.
- **A client's log says "serving this client on its own":** a copy of the
  server found the primary's lock taken but couldn't reach it through the
  pipe, so it serves its client alone, without the window. Restarting the
  MCP client usually fixes it.
- **The debug window says "page closed":** the server released the page's
  port after deciding the window was gone. Ask any connected agent to call
  `debug_open_webview`.
- **`cache 0 read / 0 written` on every call:** the cached prefix is shorter
  than the model's minimum (512 tokens for Haiku 5.5). Add more to
  `system-prompt.md` or `context\`, or wait until the cache itself grows.
- **A request keeps getting refused:** make it about one specific thing, and
  include the exact call form, version and date.
- **The debug window opens in a browser tab instead of a window:** Edge
  wasn't found. That tab can't be closed automatically when the server stops.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Diego Perini; see [NOTICE](NOTICE).
