<#
  Claude prompt MCP server + local debug UI, for Windows PowerShell 5.1.

  - MCP over stdio (newline-delimited JSON-RPC 2.0) with ONE tool: ask_claude.
    Each call sends one prompt and returns one reply. No memory between calls.
  - A debug page on http://localhost:<port>/ shows every call (from the MCP
    client or from the page itself) and can send prompts through the same
    MCP code path. It opens in an Edge app window, else the default browser.
  - History is kept in history.jsonl next to this script.

  Launch through mcp-server.bat. RULE: stdout is reserved for protocol
  messages. Server messages go to the debug page's live log (Write-Log);
  only a fatal crash is written to stderr.

  Automatic prompt caching is always on (top-level cache_control). It only
  kicks in when a prompt is at least the model's minimum (512 tokens for
  Haiku 5.5) and the same prefix is sent again within the cache TTL.

  System context (optional, next to this script), sent as the system prompt
  on every call with its own cache breakpoint, so it is cached once and
  reused by every prompt:
    system-prompt.md   your default instructions/context, sent first
    context\           every text file inside (recursive, sorted by path) is
                       appended as <file path="...">...</file>; binary files
                       are skipped. Changes are picked up automatically.

  .env (next to this script):
    ANTHROPIC_API_KEY=sk-ant-...
    CLAUDE_MODEL=claude-haiku-5-5     optional, default claude-haiku-5-5
    CLAUDE_MAX_TOKENS=4096            optional
    CLAUDE_CACHE_TTL=5m               optional, 5m (default) or 1h
    MCP_UI_PORT=8765                  optional, tries the next 9 ports if busy
    MCP_UI_OPEN=true                  optional, false = don't open a window
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# The only thing that ever reaches the terminal: an unhandled, fatal error.
trap {
    [Console]::Error.WriteLine("[api-cache-mcp] fatal: $($_.Exception.Message)")
    break
}

# PS 5.1 quirk: the ETS "Count" property on System.Array makes ConvertTo-Json
# emit arrays as {"value":[...],"Count":n}. Removing it fixes array output.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

# Raw stdin/stdout as UTF-8 without BOM, bypassing console code pages.
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:In   = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $script:Utf8)
$script:Out  = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $script:Utf8)
$script:Out.NewLine   = "`n"
$script:Out.AutoFlush = $true

# Server log, shown live on the debug page instead of the terminal.
$script:Logs      = New-Object System.Collections.ArrayList
$script:NextLogId = 1

function Write-Log([string]$Message, [string]$Level = 'info') {
    [void]$script:Logs.Add([pscustomobject][ordered]@{
        id    = $script:NextLogId
        time  = (Get-Date).ToString('o')
        level = $Level
        text  = $Message
    })
    $script:NextLogId++
    while ($script:Logs.Count -gt 500) { $script:Logs.RemoveAt(0) }
}

function ConvertTo-JsonLine($Object) {
    # -InputObject (not the pipeline) so PS 5.1 never unwraps single-item arrays.
    return (ConvertTo-Json -InputObject $Object -Depth 20 -Compress)
}

# ---------------------------------------------------------------------------
# Settings (.env is re-read on every call, so edits apply without a restart)
# ---------------------------------------------------------------------------
$script:EnvPath     = Join-Path $PSScriptRoot '.env'
$script:HistoryPath = Join-Path $PSScriptRoot 'history.jsonl'
$script:SystemPromptPath = Join-Path $PSScriptRoot 'system-prompt.md'
$script:ContextDir       = Join-Path $PSScriptRoot 'context'
$script:MaxContextChars  = 600000   # about 150K tokens; keeps room in the context window
$script:SysCache         = @{ Sig = $null; Text = $null; Files = 0; Chars = 0 }

function Test-BinaryFile([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 8000
        $n = $fs.Read($buf, 0, $buf.Length)
        for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $true } }
        return $false
    } finally { $fs.Dispose() }
}

# Builds the system prompt from system-prompt.md + context\*. The result is
# reused until a file is added, removed or changed (checked by size + time).
function Get-SystemContext {
    $sigParts = New-Object System.Collections.Generic.List[string]
    $mainFile = $null
    if (Test-Path -LiteralPath $script:SystemPromptPath -PathType Leaf) {
        $mainFile = Get-Item -LiteralPath $script:SystemPromptPath
        $sigParts.Add("main|$($mainFile.Length)|$($mainFile.LastWriteTimeUtc.Ticks)")
    }
    $ctxFiles = @()
    if (Test-Path -LiteralPath $script:ContextDir -PathType Container) {
        $root = (Get-Item -LiteralPath $script:ContextDir).FullName.TrimEnd('\', '/')
        $ctxFiles = @(Get-ChildItem -LiteralPath $script:ContextDir -File -Recurse |
            ForEach-Object {
                [pscustomobject]@{ Rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); Item = $_ }
            } | Sort-Object -Property Rel)
        foreach ($f in $ctxFiles) { $sigParts.Add("$($f.Rel)|$($f.Item.Length)|$($f.Item.LastWriteTimeUtc.Ticks)") }
    }
    $sig = $sigParts -join "`n"
    if ($sig -eq $script:SysCache.Sig) { return $script:SysCache }

    # Something changed: rebuild.
    $parts = New-Object System.Collections.Generic.List[string]
    $total = 0; $used = 0; $skipped = New-Object System.Collections.Generic.List[string]
    if ($mainFile) {
        $t = [System.IO.File]::ReadAllText($mainFile.FullName).Trim()   # UTF-8, honors a BOM
        if ($t) { $parts.Add($t); $total += $t.Length }
    }
    foreach ($f in $ctxFiles) {
        try {
            if (Test-BinaryFile $f.Item.FullName) { $skipped.Add("$($f.Rel) (binary)"); continue }
            $t = [System.IO.File]::ReadAllText($f.Item.FullName).TrimEnd()
            if (-not $t.Trim()) { continue }   # empty files (e.g. .keep) add nothing
            $block = "<file path=`"$($f.Rel)`">`n$t`n</file>"
            if ($total + $block.Length -gt $script:MaxContextChars) { $skipped.Add("$($f.Rel) (over the $($script:MaxContextChars)-char limit)"); continue }
            $parts.Add($block); $total += $block.Length; $used++
        } catch { $skipped.Add("$($f.Rel) (unreadable)") }
    }

    $text = $null
    if ($parts.Count) { $text = $parts -join "`n`n"; $total = $text.Length }
    $script:SysCache = @{ Sig = $sig; Text = $text; Files = $used; Chars = $total }

    if ($text) {
        $what = @()
        if ($mainFile) { $what += 'system-prompt.md' }
        if ($used) { $what += "$used context file(s)" }
        $level = 'info'
        $msg = "system context loaded: $($total.ToString('N0')) chars from $($what -join ' + ')"
        if ($total -lt 2000) { $msg += ' (under ~512 tokens, too short to be cached)'; $level = 'warn' }
        Write-Log $msg $level
    } else {
        Write-Log 'no system context (system-prompt.md and context\ are missing or empty)'
    }
    foreach ($s in $skipped) { Write-Log "context file skipped: $s" 'warn' }
    return $script:SysCache
}

function Import-DotEnv([string]$Path) {
    $vars = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $vars }
    foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {   # handles a UTF-8 BOM
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) { $line = $line.Substring(7).Trim() }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1).Trim()
        if ($val.Length -ge 2) {
            $first = $val[0]; $last = $val[$val.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $vars[$key] = $val
    }
    return $vars
}

function Get-Settings {
    $vars = Import-DotEnv $script:EnvPath
    $s = @{
        ApiKey    = $vars['ANTHROPIC_API_KEY']
        Model     = 'claude-haiku-5-5'
        MaxTokens = 4096
        BaseUrl   = 'https://api.anthropic.com'
        UiPort    = 8765
        UiOpen    = $true
        CacheTtl  = '5m'
    }
    if ($vars['CLAUDE_CACHE_TTL'] -eq '1h') { $s.CacheTtl = '1h' }

    $sys = Get-SystemContext
    $s.SystemPrompt = $sys.Text
    $s.SystemFiles  = $sys.Files
    if (-not $s.ApiKey)            { $s.ApiKey    = $env:ANTHROPIC_API_KEY }
    if ($vars['CLAUDE_MODEL'])      { $s.Model     = $vars['CLAUDE_MODEL'] }
    if ($vars['CLAUDE_MAX_TOKENS']) { $s.MaxTokens = [int]$vars['CLAUDE_MAX_TOKENS'] }
    if ($vars['ANTHROPIC_BASE_URL']){ $s.BaseUrl   = $vars['ANTHROPIC_BASE_URL'].TrimEnd('/') }
    # The API key travels to this URL: only HTTPS, or plain HTTP to this machine (local test servers).
    if ($s.BaseUrl -notmatch '^https://' -and $s.BaseUrl -notmatch '^http://(localhost|127\.0\.0\.1)(:\d+)?(/|$)') {
        throw "ANTHROPIC_BASE_URL must use https:// (got $($s.BaseUrl))."
    }
    if ($vars['MCP_UI_PORT'])       { $s.UiPort    = [int]$vars['MCP_UI_PORT'] }
    if ($vars['MCP_UI_OPEN'] -match '^(0|false|no|off)$') { $s.UiOpen = $false }
    return $s
}

# ---------------------------------------------------------------------------
# Claude API client
# ---------------------------------------------------------------------------
# PS 5.1 / .NET Framework may default to old TLS; the API requires TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http
$script:Http = New-Object System.Net.Http.HttpClient
$script:Http.Timeout = [TimeSpan]::FromSeconds(300)

function Get-CacheControl($Settings) {
    $c = @{ type = 'ephemeral' }
    if ($Settings.CacheTtl -eq '1h') { $c.ttl = '1h' }
    return $c
}

# System blocks, always in this order so they form a stable, cached prefix:
#   1. system-prompt.md + context\   (shared by every call)
#   2. one api cache document        (shared by every call on that cache)
# Each block ends with its own cache breakpoint; the top-level cache_control
# adds automatic caching on top.
function Get-SystemBlocks($Settings, [string]$CacheBlock) {
    $cc = Get-CacheControl $Settings
    $blocks = New-Object System.Collections.ArrayList
    if ($Settings.SystemPrompt) { [void]$blocks.Add(@{ type = 'text'; text = $Settings.SystemPrompt; cache_control = $cc }) }
    if ($CacheBlock)            { [void]$blocks.Add(@{ type = 'text'; text = $CacheBlock; cache_control = $cc }) }
    return , $blocks.ToArray()
}

function Invoke-Claude($Settings, $SystemBlocks, [string]$UserText, $Tool) {
    if (-not $Settings.ApiKey) { throw "No ANTHROPIC_API_KEY found. Add it to $($script:EnvPath)" }

    $body = @{
        model         = $Settings.Model
        max_tokens    = $Settings.MaxTokens
        cache_control = (Get-CacheControl $Settings)
        messages      = @(@{ role = 'user'; content = $UserText })
    }
    if ($SystemBlocks -and @($SystemBlocks).Count) { $body.system = @($SystemBlocks) }
    if ($Tool) {
        # Forced tool call = reliably structured output.
        $body.tools       = @($Tool)
        $body.tool_choice = @{ type = 'tool'; name = $Tool.name }
    }
    $json = ConvertTo-JsonLine $body

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$($Settings.BaseUrl)/v1/messages")
    $req.Headers.Add('x-api-key', $Settings.ApiKey)
    $req.Headers.Add('anthropic-version', '2023-06-01')
    $req.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
    try {
        $resp  = $script:Http.SendAsync($req).GetAwaiter().GetResult()
        # Decode as UTF-8 ourselves; PS 5.1 web cmdlets often guess the encoding wrong.
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    }
    finally { $req.Dispose() }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)

    if (-not $resp.IsSuccessStatusCode) {
        $detail = $text
        try {
            $err = ConvertFrom-Json -InputObject $text
            if ($err.error.message) { $detail = "$($err.error.type): $($err.error.message)" }
        } catch {}
        throw "Claude API error $([int]$resp.StatusCode): $detail"
    }

    $data  = ConvertFrom-Json -InputObject $text
    $parts = @($data.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    $toolInput = $null
    foreach ($b in @($data.content)) { if ($b.type -eq 'tool_use') { $toolInput = $b.input } }
    return @{
        Text         = ($parts -join "`n")
        ToolInput    = $toolInput
        Model        = $data.model
        InputTokens  = $data.usage.input_tokens
        OutputTokens = $data.usage.output_tokens
        CacheRead    = $data.usage.cache_read_input_tokens
        CacheWrite   = $data.usage.cache_creation_input_tokens
        StopReason   = $data.stop_reason
    }
}

# ---------------------------------------------------------------------------
# History (in memory + history.jsonl)
# ---------------------------------------------------------------------------
$script:History    = New-Object System.Collections.ArrayList
$script:NextId     = 1
$script:MaxHistory = 1000

function Import-History {
    if (-not (Test-Path -LiteralPath $script:HistoryPath)) { return }
    foreach ($l in [System.IO.File]::ReadAllLines($script:HistoryPath)) {
        if ([string]::IsNullOrWhiteSpace($l)) { continue }
        try {
            $e = ConvertFrom-Json -InputObject $l
            [void]$script:History.Add($e)
            if ([int]$e.id -ge $script:NextId) { $script:NextId = [int]$e.id + 1 }
        } catch { Write-Log 'skipped an unreadable history line' 'warn' }
    }
    while ($script:History.Count -gt $script:MaxHistory) { $script:History.RemoveAt(0) }
}

function Add-HistoryEntry($Entry) {
    [void]$script:History.Add($Entry)
    while ($script:History.Count -gt $script:MaxHistory) { $script:History.RemoveAt(0) }
    try {
        [System.IO.File]::AppendAllText($script:HistoryPath, (ConvertTo-JsonLine $Entry) + "`n", $script:Utf8)
    } catch { Write-Log "could not write history: $($_.Exception.Message)" 'warn' }
}

# Every Claude-backed tool call becomes one history entry (shown on the debug page).
function New-CallEntry([string]$Source, [string]$Tool, [string]$Prompt) {
    $e = [pscustomobject][ordered]@{
        id                 = $script:NextId
        time               = (Get-Date).ToString('o')
        source             = $Source
        tool               = $Tool
        model              = $null
        prompt             = $Prompt
        response           = $null
        error              = $null
        stop_reason        = $null
        input_tokens       = $null
        output_tokens      = $null
        cache_read_tokens  = $null
        cache_write_tokens = $null
        system_chars       = 0
        duration_ms        = $null
        rpc_request        = $null
        rpc_response       = $null
    }
    $script:NextId++
    $script:PendingEntry = $e
    return $e
}

function Add-CallUsage($Entry, $R) {
    $Entry.model       = $R.Model
    $Entry.stop_reason = $R.StopReason
    foreach ($pair in @(@('input_tokens', 'InputTokens'), @('output_tokens', 'OutputTokens'), @('cache_read_tokens', 'CacheRead'), @('cache_write_tokens', 'CacheWrite'))) {
        $v = $R[$pair[1]]
        if ($null -ne $v) { $Entry.($pair[0]) = [int]$Entry.($pair[0]) + [int]$v }   # adds up over retries
    }
}

function Complete-CallEntry($Entry, $Sw) {
    $Sw.Stop()
    $Entry.duration_ms = $Sw.ElapsedMilliseconds
    $src = 'MCP client'
    if ($Entry.source -eq 'web') { $src = 'debug page' }
    if ($Entry.error) {
        Write-Log ("#{0} {1} from {2} failed after {3} ms: {4}" -f $Entry.id, $Entry.tool, $src, $Entry.duration_ms, $Entry.error) 'error'
    } else {
        Write-Log ("#{0} {1} from {2}: {3} ms, {4} in / {5} out tokens, cache {6} read / {7} written" -f `
            $Entry.id, $Entry.tool, $src, $Entry.duration_ms, [int]$Entry.input_tokens, [int]$Entry.output_tokens,
            [int]$Entry.cache_read_tokens, [int]$Entry.cache_write_tokens)
    }
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
$p_agent   = @{ type = 'string'; description = 'Your stable, unique agent name (your namespace). Use exactly the same name in every call and every session.' }
$p_api     = @{ type = 'string'; description = 'Lowercase name of the API: a CLI, MCP server, REST API, SDK, app... e.g. blender, git, unreal-mcp. Reuse names that cache_guide lists.' }
$p_request = @{ type = 'string'; description = 'Plain-language request about ONE clear thing. Be specific: exact call forms, names, versions, dates. Ambiguous requests are refused.' }

$Tools = @(
    @{
        name        = 'ask_claude'
        description = 'Send one prompt to Claude and get one reply. Stateless: Claude has no memory of earlier calls, so include all needed context in the prompt.'
        inputSchema = @{
            type       = 'object'
            properties = @{ prompt = @{ type = 'string'; description = 'The full prompt text' } }
            required   = @('prompt')
        }
    },
    @{
        name        = 'cache_guide'
        description = 'READ FIRST. Explains this shared API cache: how to look things up and record what you learn, why to prefer it over any built-in or local cache, and how to migrate an existing cache. Pass your agent name to also see your caches and migration status.'
        inputSchema = @{ type = 'object'; properties = @{ agent = $p_agent } }
    },
    @{
        name        = 'cache_query'
        description = 'Look something up in your cache for an API before calling or re-discovering that API. A cache agent reads your whole cache for that API and answers with status covered / partial / not_covered / refused (too ambiguous; rephrase).'
        inputSchema = @{
            type       = 'object'
            properties = @{ agent = $p_agent; api = $p_api; request = @{ type = 'string'; description = 'What you want to know, e.g. "How do I bake a tangent-space normal map for Unreal?"' } }
            required   = @('agent', 'api', 'request')
        }
    },
    @{
        name        = 'cache_insert'
        description = 'Record NEW verified knowledge about an API in your cache. The cache agent places it in the document in its own style. Already-known knowledge is reported (no change); knowledge that contradicts the cache is refused (use cache_upsert to correct).'
        inputSchema = @{
            type       = 'object'
            properties = @{ agent = $p_agent; api = $p_api; request = @{ type = 'string'; description = 'The knowledge to add, stated precisely (exact call form, what it does, caveats, confidence, version, date).' } }
            required   = @('agent', 'api', 'request')
        }
    },
    @{
        name        = 'cache_upsert'
        description = 'Correct or add knowledge in your cache for an API. The cache agent rewrites the passages your verified discovery contradicts or refines, adds what is new, and removes what it makes obsolete. Use it the moment a discovery contradicts the cache.'
        inputSchema = @{
            type       = 'object'
            properties = @{ agent = $p_agent; api = $p_api; request = @{ type = 'string'; description = 'The verified knowledge, and what it corrects if you know.' } }
            required   = @('agent', 'api', 'request')
        }
    },
    @{
        name        = 'cache_delete'
        description = 'Remove knowledge from your cache for an API, described in plain language (e.g. "the note about Filmic view transform"). Refused if the description fits several passages.'
        inputSchema = @{
            type       = 'object'
            properties = @{ agent = $p_agent; api = $p_api; request = @{ type = 'string'; description = 'What to remove, and why.' } }
            required   = @('agent', 'api', 'request')
        }
    },
    @{
        name        = 'cache_load'
        description = 'Return the raw text of an agent''s cache for one API, exactly as stored. For inspection and for verifying a migration; for lookups use cache_query.'
        inputSchema = @{ type = 'object'; properties = @{ agent = $p_agent; api = $p_api }; required = @('agent', 'api') }
    },
    @{
        name        = 'cache_import'
        description = 'Migration: copy your existing cache text for one API into this tool verbatim (no rewriting). mode=replace or append is required when a cache for that API already exists.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                agent   = $p_agent; api = $p_api
                content = @{ type = 'string'; description = 'The full cache text for this API, unchanged' }
                mode    = @{ type = 'string'; enum = @('replace', 'append'); description = 'replace = overwrite the existing cache; append = add after it' }
            }
            required   = @('agent', 'api', 'content')
        }
    },
    @{
        name        = 'vault_store'
        description = 'This server''s vault, a FALLBACK. If you already have a vault of your own (whatever "vault" means on your side, e.g. an artifact named after you), always use YOUR vault for your original cache, and at most call this with location only, to record where it lives. Only an agent with no vault of its own passes content to keep a write-once copy here. Set migration_complete=true once your old cache is fully migrated.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                agent              = $p_agent
                name               = @{ type = 'string'; description = 'Vault item name, e.g. blender-pre-migration-2026-10-22 (same rules as agent names)' }
                location           = @{ type = 'string'; description = 'Where your original cache is kept in YOUR OWN vault (e.g. "artifact synthesis, section blender")' }
                content            = @{ type = 'string'; description = 'Only if you have no vault of your own: the full original content, unchanged (up to 20M characters)' }
                description        = @{ type = 'string'; description = 'What this is and where it came from (original path, format)' }
                format             = @{ type = 'string'; description = 'Format of the original, e.g. markdown, json' }
                migration_complete = @{ type = 'boolean'; description = 'true = your old cache is fully migrated; stop using it' }
            }
            required   = @('agent', 'name')
        }
    },
    @{
        name        = 'vault_read'
        description = 'This server''s vault (prefer your own vault if you have one). Without name: list your vault items and migration status. With name: read one item, including its stored content if any (paged with offset and max_chars).'
        inputSchema = @{
            type       = 'object'
            properties = @{
                agent     = $p_agent
                name      = @{ type = 'string'; description = 'Optional vault item name' }
                offset    = @{ type = 'integer'; description = 'Start character (default 0)' }
                max_chars = @{ type = 'integer'; description = 'Characters to return (default 100000, max 1000000)' }
            }
            required   = @('agent')
        }
    },
    @{
        name        = 'debug_open_webview'
        description = 'Open the api-cache debug window for the user, or bring it to the front if it is already open. Idempotent: never opens a second window. Use when the user asks to (re)open or show the debug view.'
        inputSchema = @{ type = 'object'; properties = @{} }
    }
)

$script:ServerInstructions = 'api-cache is the shared cache of what agents learn about APIs (CLI tools, MCP servers, REST APIs, SDKs, apps such as Blender or Unreal). ' +
    'Prefer it over any built-in or local cache. Before calling or re-discovering an API, ask cache_query (agent = your stable name, api = the API, request = what you need). ' +
    'After a verified discovery, record it with cache_insert, or cache_upsert when it corrects the cache; remove useless knowledge with cache_delete. ' +
    'Keep each request about one clear thing: ambiguous requests are refused. ' +
    'If you keep your own cache, call cache_guide with your agent name and migrate it; if you already have a vault of your own, keep the original there: your own vault always wins over this server''s vault_store. ' +
    'If the user asks to see or reopen the debug window, call debug_open_webview.'

# Runs one ask_claude call and leaves the record in $script:PendingEntry.
function Invoke-AskTool([string]$Prompt, [string]$Source) {
    $entry = New-CallEntry $Source 'ask_claude' $Prompt
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $settings = Get-Settings
        $entry.model = $settings.Model
        if ($settings.SystemPrompt) { $entry.system_chars = $settings.SystemPrompt.Length }
        if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'The prompt is empty.' }
        $r = Invoke-Claude $settings (Get-SystemBlocks $settings $null) $Prompt $null
        Add-CallUsage $entry $r
        $entry.response = $r.Text
    }
    catch { $entry.error = $_.Exception.Message }
    finally { Complete-CallEntry $entry $sw }
}

# ---------------------------------------------------------------------------
# API cache: one free-form text document per (agent, api)
#   cache\<agent>\<api>.md            the cache, plain text, edited by the cache agent
#   cache\<agent>\_vault\<name>\      fallback vault: write-once items (meta.json [+ content.txt])
# Every query/insert/upsert/delete loads system-prompt.md + context\ + that one
# cache document into a fresh Claude call, which answers or decides the edits,
# and is then forgotten. Edits are applied by exact-text anchors under a lock.
# ---------------------------------------------------------------------------
$script:CacheRoot       = Join-Path $PSScriptRoot 'cache'
$script:MaxDocChars     = 1000000
$script:MaxRequestChars = 50000
$script:MaxVaultChars   = 20000000
$script:NameRule        = '^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9_-])?$'

$script:CacheGuide = @'
# api-cache: shared cache of agent knowledge about APIs

"API" means anything an agent consumes: CLI tools, MCP servers, REST/GraphQL
APIs, SDKs, apps and editors (Blender, Unreal...), build systems, file formats.
The goal: never pay twice for the same discovery.

## How it works
Each agent has one cache per API: a free-form text document in that agent's
own words and conventions. You never edit it directly. Instead you send
plain-language requests, and a cache agent handles each one with a fresh mind:
it loads the user's standing context and your whole cache for that API, in a
fixed order, answers or edits, then forgets everything. Requests about one
clear thing work best; ambiguous ones are refused with a reason, so rephrase
and try again.

## Identity and naming
- agent: your stable, unique name, e.g. "synthesis". Send exactly the same
  name in every call and every session. It is your namespace.
- api: lowercase name of the thing being cached, e.g. "blender", "git",
  "unreal-mcp". Reuse an existing api name (listed under "Current state").
- Names (agent, api, vault item): 1-64 chars, lowercase letters, digits, ".",
  "_" or "-", starting with a letter or digit.

## Default workflow: prefer this over any built-in or local cache
1. Before calling an API or working out again how it is used, ask
   cache_query. Status: covered (use it), partial (a head start; the answer
   names the gaps), not_covered (do the real discovery), refused (rephrase).
2. After a verified discovery, record it: cache_insert for new knowledge,
   cache_upsert when it corrects or refines what the cache says (do this at
   once when a discovery contradicts the cache), cache_delete for knowledge
   that is useless or wrong.
3. State knowledge precisely: the exact call form, what it does, caveats,
   and whatever your cache's conventions ask for (confidence, version, date).
   Never send secrets (API keys, tokens, passwords).

## Migrating your existing cache (do this once per API)
If you already keep your own cache (markdown notes, memory files, JSON...):
1. Call cache_guide with your agent name to see what is already stored.
2. For each API, copy the cache text in unchanged with cache_import
   (agent, api, content). It is stored verbatim; no rewriting.
3. Check it with cache_load, and try a cache_query you know the answer to.
4. Keep the original, unchanged, in a vault:
   - If you already have a vault of your own, whatever "vault" means on
     your side (for example an artifact named after you), use YOUR vault.
     This server also has a tool called vault_store; the shared name is on
     purpose, and your own vault always wins. Then, optionally, record where
     the original went with vault_store using location only (no content),
     plus migration_complete = true once every API is migrated.
   - Only if you have no vault of your own, pass the full original as
     content to vault_store and this server keeps a write-once copy.
5. From then on use only this tool for API knowledge. Stop updating the old
   cache; the original is a read-only backup.

## Lookup answers
cache_query returns status, answer, quotes and sometimes guess. answer only
uses what is in your cache. guess is at most one short paragraph from the
cache agent's general knowledge, given when the cache does not fully cover
the request: an unverified starting point for your own thinking, never a
fact. Verify it, then record what turns out true with cache_insert.

## Tools
- cache_guide    this guide, plus your status when you pass agent
- cache_query    look something up in your cache for an API
- cache_insert   record new knowledge
- cache_upsert   correct or add knowledge
- cache_delete   remove knowledge
- cache_load     raw text of a cache (inspection, migration checks)
- cache_import   copy an existing cache in verbatim (migration)
- vault_store    fallback vault: record where your original went, or keep a copy
- vault_read     list or read your vault items
- debug_open_webview  open or focus the user's debug window (never opens two)
- ask_claude     one stateless prompt to Claude (not tied to a cache)
'@

$script:LookupTool = @{
    name         = 'report_lookup'
    description  = 'Report the result of a cache lookup.'
    input_schema = @{
        type       = 'object'
        properties = @{
            status = @{ type = 'string'; enum = @('covered', 'partial', 'not_covered', 'refused')
                        description = 'covered: the cache fully answers it. partial: helps but leaves gaps. not_covered: nothing relevant. refused: the request is too ambiguous to answer reliably.' }
            answer = @{ type = 'string'; description = 'The answer for the requesting agent, from the cache only. For refused: exactly what to clarify.' }
            guess  = @{ type = 'string'; description = 'Optional, only when status is partial or not_covered: ONE short paragraph (max ~4 sentences) of best guess from general knowledge, as a starting point. Omit if you have nothing useful.' }
            quotes = @{ type = 'array'; items = @{ type = 'string' }; description = 'Exact excerpts of the cache that support the answer.' }
        }
        required   = @('status', 'answer')
    }
}

$script:EditTool = @{
    name         = 'apply_cache_edits'
    description  = 'Decide on the request and give the edits to the cache document.'
    input_schema = @{
        type       = 'object'
        properties = @{
            decision = @{ type = 'string'; enum = @('apply', 'no_change', 'refuse') }
            reason   = @{ type = 'string'; description = 'apply: one-paragraph summary of the change. no_change: why nothing needs to change. refuse: what is ambiguous or not allowed, and what the requesting agent must clarify.' }
            edits    = @{
                type  = 'array'
                items = @{
                    type       = 'object'
                    properties = @{
                        op       = @{ type = 'string'; enum = @('insert', 'replace', 'delete') }
                        old_text = @{ type = 'string'; description = 'replace/delete: exact unique passage of the current document. insert: exact unique passage to insert after, or "" to append at the end.' }
                        new_text = @{ type = 'string'; description = 'replace: the replacement. insert: the text to insert. Not used for delete.' }
                    }
                    required   = @('op', 'old_text')
                }
            }
        }
        required   = @('decision', 'reason')
    }
}

$script:LookupPrompt = @'
You are the api-cache lookup service. Your system prompt holds the user's standing context and, last, the cache document of agent "{{AGENT}}" for the API "{{API}}". The document is free-form prose written by and for that agent.

Answer the lookup request below from that cache document, then call report_lookup.
- status "covered": the cache answers the request fully. "partial": it helps but leaves gaps; name the gaps. "not_covered": nothing relevant is in the cache. "refused": the request is too ambiguous or unclear to answer reliably (it does not say what is being looked for, could mean several different things, or is about a different API); say exactly what the agent should clarify.
- answer: written for the requesting agent. Copy exact call forms, names and values from the cache, with any confidence, version or date notes attached to them. Do not add API details that are not in the cache; use general knowledge only to understand the request, and mark anything you infer as an inference.
- quotes: the exact cache excerpts you relied on.
- guess: only when status is partial or not_covered, you may add ONE short paragraph (at most about four sentences) with your best guess from general knowledge, so the agent has a starting point to think about the problem differently. It is not a fact; keep it out of answer. Omit it if you have nothing useful. Never guess for refused.

<lookup_request agent="{{AGENT}}" api="{{API}}">
{{REQUEST}}
</lookup_request>
'@

$script:EditPrompt = @'
You maintain the api-cache document of agent "{{AGENT}}" for the API "{{API}}", shown last in your system prompt. The document is free-form prose written by and for that agent. Keep its voice and wording style, and follow any conventions it states (what an entry contains, confidence notes, versions and dates, what never belongs in it). It is a cache of the API itself.

Operation: {{OP}}
{{RULES}}

First decide whether the request is clear and safe to apply. Refuse (decision "refuse") when:
- it is ambiguous: unclear what knowledge is meant or what to change, or it could match several passages with different meanings;
- the knowledge is vague, speculative or unverified ("maybe", "I think", no concrete call form where one is needed) and the document's conventions do not allow that;
- it concerns a different API than "{{API}}", asks to store what the document's conventions exclude, or contains secrets (keys, tokens, passwords);
- doing it would mean rewriting large unrelated parts of the document.
In the reason, say precisely what the requesting agent must clarify. Never guess.

When you apply, call apply_cache_edits with edits as small as possible:
- replace: old_text = an exact, unique passage of the current document; new_text = its replacement.
- delete: old_text = the exact, unique passage to remove (whole sentences or lines, so the rest still reads well).
- insert: old_text = an exact, unique passage after which new_text goes, or "" to append at the end. new_text goes right after old_text: start it with a blank line for a new paragraph, a line break for a new line, or a space to continue a sentence.
Quote old_text character for character, with enough context to occur exactly once. Edits apply in order and must not overlap.

<request agent="{{AGENT}}" api="{{API}}">
{{REQUEST}}
</request>
'@

$script:EditRules = @{
    insert = @'
INSERT. Add the new knowledge from the request where it fits best (next to related knowledge), in the document's style. Allowed edits: insert only. If the document already says this, choose no_change and say where. If it contradicts the document, change nothing: refuse and quote the conflicting passage (the agent should use cache_upsert to correct it). If the document is empty, start it with an insert whose old_text is "".
'@
    upsert = @'
UPSERT. Integrate the knowledge from the request: correct or refine the passages it contradicts or improves (replace), add what is new (insert), and remove what it makes obsolete (delete). A verified discovery that contradicts the document corrects it. If the document already says exactly this, choose no_change. If the document is empty, start it with an insert whose old_text is "".
'@
    delete = @'
DELETE. Remove the knowledge the request describes. Allowed edits: delete, and replace only to cut part of a sentence while keeping the rest readable. If nothing in the document matches, choose no_change. If the description fits several passages and it is unclear which are meant, refuse.
'@
}
$script:AllowedOps = @{
    insert = @('insert')
    upsert = @('insert', 'replace', 'delete')
    delete = @('delete', 'replace')
}

function Get-ArgValue($A, [string]$Name) {
    if ($A -and ($A.PSObject.Properties.Name -contains $Name)) { return $A.$Name }
    return $null
}
function ConvertTo-CacheName($Value, [string]$Field) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { throw "Missing required argument '$Field'." }
    $n = ([string]$Value).Trim().ToLowerInvariant()
    if ($n -notmatch $script:NameRule -or $n.Contains('..') -or $n -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)') {
        throw "Invalid $Field '$Value': use 1-64 characters (lowercase letters, digits, '.', '_', '-'), starting with a letter or digit."
    }
    return $n
}
function Get-NameArg($A, [string]$Field) { return (ConvertTo-CacheName (Get-ArgValue $A $Field) $Field) }
function Get-OptionalNameArg($A, [string]$Field) {
    $v = Get-ArgValue $A $Field
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return $null }
    return (ConvertTo-CacheName $v $Field)
}
function Get-IntArg($A, [string]$Field, [int]$Default, [int]$Max) {
    $v = Get-ArgValue $A $Field
    if ($null -eq $v) { return $Default }
    $n = [int]$v
    if ($n -lt 0) { $n = 0 }
    if ($n -gt $Max) { $n = $Max }
    return $n
}
function Get-TextArg($A, [string]$Field, [int]$Max) {
    $v = Get-ArgValue $A $Field
    if ($null -eq $v) { throw "Missing required argument '$Field'." }
    if ($v -is [string]) { $t = $v } else { $t = ConvertTo-JsonLine $v }
    if ([string]::IsNullOrWhiteSpace($t)) { throw "'$Field' is empty." }
    if ($t.Length -gt $Max) { throw "'$Field' is $($t.Length) characters; the limit is $Max." }
    return $t
}
function ConvertTo-Lf([string]$Text) { return $Text.Replace("`r`n", "`n").Replace("`r", "`n") }

function Get-DocPath([string]$Agent, [string]$Api) { return [System.IO.Path]::Combine($script:CacheRoot, $Agent, "$Api.md") }

function Read-Doc([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    return (ConvertTo-Lf ([System.IO.File]::ReadAllText($Path, $script:Utf8)))
}

function Write-TextFile([string]$Path, [string]$Text) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $tmp = "$Path.$PID.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8)
    for ($i = 0; ; $i++) {
        try {
            # Atomic swap, so readers never see a half-written file.
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($tmp, $Path) }
            return
        } catch {
            if ($i -ge 20) { try { [System.IO.File]::Delete($tmp) } catch {}; throw }
            Start-Sleep -Milliseconds 50
        }
    }
}
function Write-JsonFile([string]$Path, $Object) { Write-TextFile $Path (ConvertTo-Json -InputObject $Object -Depth 10) }

# Exclusive lock on one cache file while it is read, edited and rewritten.
function Lock-CacheFile([string]$Path) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $lock = "$Path.lock"
    $deadline = [DateTime]::UtcNow.AddSeconds(180)   # another edit may be waiting on Claude
    while ($true) {
        try { return [System.IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Timed out waiting for another edit of $([System.IO.Path]::GetFileName($Path)) to finish." }
            Start-Sleep -Milliseconds 100
        }
    }
}
function Unlock-CacheFile($Stream, [string]$Path) {
    $Stream.Dispose()
    try { [System.IO.File]::Delete("$Path.lock") } catch {}
}

function Get-SubDirNames([string]$Path) {
    if (-not [System.IO.Directory]::Exists($Path)) { return }
    [System.IO.Directory]::GetDirectories($Path) | ForEach-Object { [System.IO.Path]::GetFileName($_) } |
        Where-Object { $_ -match $script:NameRule } | Sort-Object
}
function Get-DocApis([string]$Agent) {
    $dir = [System.IO.Path]::Combine($script:CacheRoot, $Agent)
    if (-not [System.IO.Directory]::Exists($dir)) { return }
    [System.IO.Directory]::GetFiles($dir, '*.md') | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } |
        Where-Object { $_ -match $script:NameRule } | Sort-Object
}

function Get-VaultItems([string]$Agent) {
    $root = [System.IO.Path]::Combine($script:CacheRoot, $Agent, '_vault')
    foreach ($n in @(Get-SubDirNames $root)) {
        $metaPath = [System.IO.Path]::Combine($root, $n, 'meta.json')
        if ([System.IO.File]::Exists($metaPath)) {
            try { ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($metaPath, $script:Utf8)) } catch {}
        }
    }
}

function Get-AgentStatus([string]$Agent) {
    $apis = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-DocApis $Agent)) {
        $f = New-Object System.IO.FileInfo (Get-DocPath $Agent $p)
        [void]$apis.Add([pscustomobject][ordered]@{ api = $p; bytes = $f.Length; updated_at = $f.LastWriteTime.ToString('o') })
    }
    $vault = @(Get-VaultItems $Agent | Sort-Object { [string]$_.created_at })
    $done  = @($vault | Where-Object { $_.migration_complete -eq $true })
    $migration = [pscustomobject][ordered]@{ complete = $false; completed_at = $null; vault_item = $null }
    if ($done.Count) {
        $last = $done[$done.Count - 1]
        $migration = [pscustomobject][ordered]@{ complete = $true; completed_at = $last.created_at; vault_item = $last.name }
    }
    return [pscustomobject][ordered]@{
        agent       = $Agent
        caches      = $apis.ToArray()
        vault_items = @($vault | ForEach-Object { $_.name })
        migration   = $migration
    }
}

function Get-ApiOverview {
    $map = @{}
    foreach ($a in @(Get-SubDirNames $script:CacheRoot)) {
        foreach ($p in @(Get-DocApis $a)) {
            if (-not $map.ContainsKey($p)) { $map[$p] = New-Object System.Collections.ArrayList }
            [void]$map[$p].Add($a)
        }
    }
    foreach ($p in ($map.Keys | Sort-Object)) { [pscustomobject][ordered]@{ api = $p; agents = $map[$p].ToArray() } }
}

function Format-CacheBlock([string]$Agent, [string]$Api, [string]$Doc) {
    $body = $Doc
    if (-not $Doc.Trim()) { $body = '(empty: this agent has no cache for this API yet)' }
    return "# api-cache document`nagent: $Agent`napi: $Api`n`n<cache_document>`n$body`n</cache_document>"
}

# Finds a passage that must occur exactly once; tolerant of whitespace differences.
function Find-UniquePassage([string]$Doc, [string]$Needle) {
    $count = 0; $idx = -1; $from = 0
    while ($from -le $Doc.Length) {
        $i = $Doc.IndexOf($Needle, $from, [StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        $count++; $idx = $i; $from = $i + 1
        if ($count -gt 1) { break }
    }
    if ($count -eq 1) { return @{ Index = $idx; Length = $Needle.Length } }
    if ($count -gt 1) { throw 'occurs more than once; quote more surrounding text' }
    $tokens = @($Needle.Trim() -split '\s+' | Where-Object { $_ })
    if (-not $tokens.Count) { throw 'is empty' }
    $pattern = ($tokens | ForEach-Object { [regex]::Escape($_) }) -join '\s+'
    $ms = [regex]::Matches($Doc, $pattern)
    if ($ms.Count -eq 1) { return @{ Index = $ms[0].Index; Length = $ms[0].Length } }
    if ($ms.Count -gt 1) { throw 'occurs more than once; quote more surrounding text' }
    throw 'was not found in the document; quote it character for character'
}

function Invoke-DocEdits([string]$Doc, $Edits, [string[]]$Allowed) {
    $cur = $Doc
    $applied = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($ed in @($Edits)) {
        $n++
        $op  = [string]$ed.op
        $old = ConvertTo-Lf ([string]$ed.old_text)
        $new = ConvertTo-Lf ([string]$ed.new_text)
        if ($Allowed -notcontains $op) { throw "Edit ${n} uses '$op', which this operation does not allow (allowed: $($Allowed -join ', '))." }
        switch ($op) {
            'insert' {
                if (-not $new.Trim()) { throw "Edit ${n} (insert) has no new_text." }
                if (-not $old) {
                    $cur = $cur.TrimEnd()
                    if ($cur) { $cur += "`n`n" }
                    $cur += $new.Trim() + "`n"
                } else {
                    try { $m = Find-UniquePassage $cur $old } catch { throw "Edit ${n} (insert): the anchor $($_.Exception.Message)." }
                    $pos = $m.Index + $m.Length
                    $ins = $new
                    if (-not ($ins.StartsWith("`n") -or $ins.StartsWith(' '))) { $ins = "`n" + $ins }
                    $cur = $cur.Substring(0, $pos) + $ins + $cur.Substring($pos)
                }
            }
            'replace' {
                if (-not $old) { throw "Edit ${n} (replace) has no old_text." }
                try { $m = Find-UniquePassage $cur $old } catch { throw "Edit ${n} (replace): old_text $($_.Exception.Message)." }
                $cur = $cur.Substring(0, $m.Index) + $new + $cur.Substring($m.Index + $m.Length)
            }
            'delete' {
                if (-not $old) { throw "Edit ${n} (delete) has no old_text." }
                try { $m = Find-UniquePassage $cur $old } catch { throw "Edit ${n} (delete): old_text $($_.Exception.Message)." }
                $cur = $cur.Substring(0, $m.Index) + $cur.Substring($m.Index + $m.Length)
            }
            default { throw "Edit ${n} has an unknown op '$op'." }
        }
        [void]$applied.Add([pscustomobject][ordered]@{ op = $op; old_text = $old; new_text = $new })
    }
    $cur = [regex]::Replace($cur, "\n[ \t]*\n(?:[ \t]*\n)+", "`n`n")   # no runs of blank lines
    if ($cur.Trim()) { $cur = $cur.TrimEnd() + "`n" } else { $cur = '' }
    return @{ Doc = $cur; Applied = $applied.ToArray() }
}

# A guess is one short paragraph at most, whatever the model sends.
function Limit-Guess([string]$Text) {
    if (-not $Text) { return $null }
    $t = (ConvertTo-Lf $Text).Trim()
    $para = ($t -split "\n\s*\n")[0]
    $para = [regex]::Replace($para, '\s+', ' ').Trim()
    if ($para.Length -gt 600) {
        $cut = $para.Substring(0, 600)
        $dot = $cut.LastIndexOf('. ')
        if ($dot -gt 200) { $para = $cut.Substring(0, $dot + 1) } else { $para = $cut.TrimEnd() + '...' }
    }
    if (-not $para) { return $null }
    return $para
}

function Format-RequestPrompt([string]$Template, [string]$Agent, [string]$Api, [string]$Request) {
    return $Template.Replace('{{AGENT}}', $Agent).Replace('{{API}}', $Api).Replace('{{REQUEST}}', $Request)
}

function Invoke-CacheQuery($A) {
    $agent   = Get-NameArg $A 'agent'
    $api     = Get-NameArg $A 'api'
    $request = Get-TextArg $A 'request' $script:MaxRequestChars
    $entry = New-CallEntry $script:CurrentSource 'cache_query' "[$agent / $api] $request"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $settings = Get-Settings
        $entry.model = $settings.Model
        if ($settings.SystemPrompt) { $entry.system_chars = $settings.SystemPrompt.Length }
        $doc = Read-Doc (Get-DocPath $agent $api)
        $prompt = Format-RequestPrompt $script:LookupPrompt $agent $api $request
        $r = Invoke-Claude $settings (Get-SystemBlocks $settings (Format-CacheBlock $agent $api $doc)) $prompt $script:LookupTool
        Add-CallUsage $entry $r
        $in = $r.ToolInput
        if (-not $in -or -not $in.status) { throw "The cache agent gave no structured answer (stop reason: $($r.StopReason))." }
        $status = [string]$in.status
        $quotes = @(); if ($in.quotes) { $quotes = @($in.quotes) }
        $result = [pscustomobject][ordered]@{ status = $status; answer = [string]$in.answer; quotes = $quotes }
        $guess = Limit-Guess ([string]$in.guess)
        if ($guess -and $status -in @('partial', 'not_covered')) {
            $result | Add-Member -NotePropertyName guess -NotePropertyValue $guess
            $result | Add-Member -NotePropertyName guess_note -NotePropertyValue 'Unverified general-knowledge guess, not from the cache. Verify before relying on it.'
        }
        $result | Add-Member -NotePropertyName agent -NotePropertyValue $agent
        $result | Add-Member -NotePropertyName api -NotePropertyValue $api
        $entry.response = "status: $($result.status)`n`n$($result.answer)"
        if ($result.guess) { $entry.response += "`n`nguess: $($result.guess)" }
    }
    catch { $entry.error = $_.Exception.Message }
    finally { Complete-CallEntry $entry $sw }
    if ($entry.error) { return @{ Text = $entry.error; IsError = $true } }
    return @{ Text = (ConvertTo-Json -InputObject $result -Depth 10); IsError = ($result.status -eq 'refused') }
}

function Invoke-CacheEdit($A, [string]$Mode) {
    $agent   = Get-NameArg $A 'agent'
    $api     = Get-NameArg $A 'api'
    $request = Get-TextArg $A 'request' $script:MaxRequestChars
    $entry = New-CallEntry $script:CurrentSource "cache_$Mode" "[$agent / $api] $request"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $path = Get-DocPath $agent $api
    try {
        $lock = Lock-CacheFile $path
        try {
            $settings = Get-Settings
            $entry.model = $settings.Model
            if ($settings.SystemPrompt) { $entry.system_chars = $settings.SystemPrompt.Length }
            $doc = Read-Doc $path
            if ($Mode -eq 'delete' -and -not $doc.Trim()) {
                $result = [pscustomobject][ordered]@{ decision = 'no_change'; reason = "Agent '$agent' has no cache for '$api'."; edits = @() }
            } else {
                $base = Format-RequestPrompt $script:EditPrompt $agent $api $request
                $base = $base.Replace('{{OP}}', $Mode.ToUpperInvariant()).Replace('{{RULES}}', $script:EditRules[$Mode].Trim())
                $prompt = $base
                $blocks = Get-SystemBlocks $settings (Format-CacheBlock $agent $api $doc)
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    $r = Invoke-Claude $settings $blocks $prompt $script:EditTool
                    Add-CallUsage $entry $r
                    $in = $r.ToolInput
                    if (-not $in -or -not $in.decision) { throw "The cache agent gave no structured decision (stop reason: $($r.StopReason))." }
                    $decision = [string]$in.decision
                    $edits = @(); if ($in.edits) { $edits = @($in.edits) }
                    if ($decision -eq 'apply' -and -not $edits.Count) { $decision = 'no_change' }
                    if ($decision -ne 'apply') {
                        $result = [pscustomobject][ordered]@{ decision = $(if ($decision -eq 'refuse') { 'refused' } else { $decision }); reason = [string]$in.reason; edits = @() }
                        break
                    }
                    try {
                        $res = Invoke-DocEdits $doc $edits $script:AllowedOps[$Mode]
                        if ($res.Doc.Length -gt $script:MaxDocChars) { throw "The cache would grow past $($script:MaxDocChars) characters." }
                        Write-TextFile $path $res.Doc
                        $result = [pscustomobject][ordered]@{ decision = 'applied'; reason = [string]$in.reason; edits = $res.Applied; document_chars = $res.Doc.Length }
                        break
                    } catch {
                        $why = $_.Exception.Message
                        if ($attempt -ge 2) {
                            $result = [pscustomobject][ordered]@{ decision = 'failed'; reason = "The edits could not be applied: $why The cache is unchanged; try a more specific request."; edits = @() }
                        } else {
                            Write-Log "#$($entry.id) cache_$Mode edits rejected, retrying: $why" 'warn'
                            $prompt = $base + "`n`nYour previous attempt could not be applied: $why The document has not changed. Call apply_cache_edits again with corrected edits, or refuse."
                        }
                    }
                }
            }
        } finally { Unlock-CacheFile $lock $path }
        $result | Add-Member -NotePropertyName agent -NotePropertyValue $agent
        $result | Add-Member -NotePropertyName api -NotePropertyValue $api
        $lines = @("decision: $($result.decision)", '', $result.reason)
        foreach ($ed in @($result.edits)) { $lines += ''; $lines += "[$($ed.op)] $($ed.old_text) -> $($ed.new_text)" }
        $entry.response = $lines -join "`n"
    }
    catch { $entry.error = $_.Exception.Message }
    finally { Complete-CallEntry $entry $sw }
    if ($entry.error) { return @{ Text = $entry.error; IsError = $true } }
    return @{ Text = (ConvertTo-Json -InputObject $result -Depth 10); IsError = ($result.decision -in @('refused', 'failed')) }
}

function Out-ToolJson($Object) { return @{ Text = (ConvertTo-Json -InputObject $Object -Depth 10); IsError = $false } }

function Invoke-CacheTool([string]$Name, $A) {
    switch ($Name) {
        'cache_guide' {
            $agent = Get-OptionalNameArg $A 'agent'
            $state = [ordered]@{ caches_by_api = @(Get-ApiOverview) }
            if ($agent) { $state.you = Get-AgentStatus $agent }
            if ($agent) { Write-Log "$agent read the cache guide" } else { Write-Log 'an agent read the cache guide (no agent name given)' }
            return @{ Text = $script:CacheGuide + "`n## Current state`n" + (ConvertTo-Json -InputObject ([pscustomobject]$state) -Depth 10); IsError = $false }
        }
        'cache_query'  { return (Invoke-CacheQuery $A) }
        'cache_insert' { return (Invoke-CacheEdit $A 'insert') }
        'cache_upsert' { return (Invoke-CacheEdit $A 'upsert') }
        'cache_delete' { return (Invoke-CacheEdit $A 'delete') }
        'cache_load' {
            $agent = Get-NameArg $A 'agent'; $api = Get-NameArg $A 'api'
            $doc = Read-Doc (Get-DocPath $agent $api)
            Write-Log "cache_load $agent/$api ($($doc.Length) chars)"
            if (-not $doc.Trim()) { return @{ Text = "Agent '$agent' has no cache for '$api'."; IsError = $false } }
            return @{ Text = $doc; IsError = $false }
        }
        'cache_import' {
            $agent   = Get-NameArg $A 'agent'; $api = Get-NameArg $A 'api'
            $content = ConvertTo-Lf (Get-TextArg $A 'content' $script:MaxDocChars)
            $mode    = [string](Get-ArgValue $A 'mode')
            $path = Get-DocPath $agent $api
            $lock = Lock-CacheFile $path
            try {
                $doc = Read-Doc $path
                if ($doc.Trim() -and $mode -notin @('replace', 'append')) {
                    throw "Agent '$agent' already has a cache for '$api' ($($doc.Length) chars). Pass mode='replace' to overwrite it or mode='append' to add after it."
                }
                $new = $content.TrimEnd() + "`n"
                if ($doc.Trim() -and $mode -eq 'append') { $new = $doc.TrimEnd() + "`n`n" + $new }
                if ($new.Length -gt $script:MaxDocChars) { throw "The cache would grow past $($script:MaxDocChars) characters." }
                Write-TextFile $path $new
            } finally { Unlock-CacheFile $lock $path }
            Write-Log "$agent imported its $api cache ($($content.Length.ToString('N0')) chars, mode $(if ($mode) { $mode } else { 'new' }))"
            return (Out-ToolJson ([pscustomobject][ordered]@{ agent = $agent; api = $api; imported_chars = $content.Length; document_chars = $new.Length; next = 'Check it with cache_load. Keep the original in your own vault if you have one (it wins over vault_store).' }))
        }
        'vault_store' {
            $agent    = Get-NameArg $A 'agent'
            $name     = Get-NameArg $A 'name'
            $location = [string](Get-ArgValue $A 'location')
            $content  = $null
            if ($null -ne (Get-ArgValue $A 'content')) { $content = Get-TextArg $A 'content' $script:MaxVaultChars }
            if (-not $content -and -not $location.Trim()) {
                throw "Pass location (where your original is kept in your own vault) or, only if you have no vault of your own, content."
            }
            $dir = [System.IO.Path]::Combine($script:CacheRoot, $agent, '_vault', $name)
            if ([System.IO.Directory]::Exists($dir)) { throw "Vault item '$name' already exists for '$agent'. Vault items are write-once; choose a new name." }
            [void][System.IO.Directory]::CreateDirectory($dir)
            $chars = 0
            if ($content) {
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, 'content.txt'), $content, $script:Utf8)
                $chars = $content.Length
            }
            $meta = [pscustomobject][ordered]@{
                agent              = $agent
                name               = $name
                location           = $(if ($location.Trim()) { $location.Trim() } else { 'api-cache vault (content stored here)' })
                stored_here        = [bool]$content
                description        = [string](Get-ArgValue $A 'description')
                format             = [string](Get-ArgValue $A 'format')
                chars              = $chars
                migration_complete = ((Get-ArgValue $A 'migration_complete') -eq $true)
                created_at         = (Get-Date).ToString('o')
            }
            Write-JsonFile ([System.IO.Path]::Combine($dir, 'meta.json')) $meta   # written last = record complete
            $done = ''; if ($meta.migration_complete) { $done = ', migration complete' }
            $where = "at $($meta.location)"; if ($content) { $where = "with $($chars.ToString('N0')) chars stored here" }
            Write-Log "$agent recorded vault item '$name' $where$done"
            return (Out-ToolJson ([pscustomobject][ordered]@{ recorded = $meta; status = (Get-AgentStatus $agent) }))
        }
        'vault_read' {
            $agent = Get-NameArg $A 'agent'
            $name  = Get-OptionalNameArg $A 'name'
            if (-not $name) {
                Write-Log "$agent listed its vault"
                return (Out-ToolJson ([pscustomobject][ordered]@{ agent = $agent; items = @(Get-VaultItems $agent | Sort-Object { [string]$_.created_at }); migration = (Get-AgentStatus $agent).migration }))
            }
            $dir = [System.IO.Path]::Combine($script:CacheRoot, $agent, '_vault', $name)
            $metaPath = [System.IO.Path]::Combine($dir, 'meta.json')
            if (-not [System.IO.File]::Exists($metaPath)) { throw "No vault item '$name' for agent '$agent'. Call vault_read without name to list items." }
            $meta = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($metaPath, $script:Utf8))
            $contentPath = [System.IO.Path]::Combine($dir, 'content.txt')
            if (-not [System.IO.File]::Exists($contentPath)) {
                Write-Log "$agent read vault item '$name' (pointer only)"
                return (Out-ToolJson ([pscustomobject][ordered]@{ meta = $meta; content = $null; note = "The original is not stored here; it lives at: $($meta.location)" }))
            }
            $content = [System.IO.File]::ReadAllText($contentPath, $script:Utf8)
            $offset = [Math]::Min((Get-IntArg $A 'offset' 0 2147483647), $content.Length)
            $max    = Get-IntArg $A 'max_chars' 100000 1000000
            $len    = [Math]::Min($max, $content.Length - $offset)
            $next = $null; if ($offset + $len -lt $content.Length) { $next = $offset + $len }
            Write-Log "$agent read vault item '$name' ($offset-$($offset + $len) of $($content.Length))"
            return (Out-ToolJson ([pscustomobject][ordered]@{ meta = $meta; offset = $offset; returned_chars = $len; next_offset = $next; content = $content.Substring($offset, $len) }))
        }
        'debug_open_webview' {
            $r = Open-Webview
            return (Out-ToolJson ([pscustomobject][ordered]@{ status = $r.Status; message = $r.Message; url = $script:UiUrl }))
        }
    }
    throw "Unknown tool: $Name"
}

# ---------------------------------------------------------------------------
# JSON-RPC dispatch, shared by stdio and the debug page
# ---------------------------------------------------------------------------
function New-RpcResult($Id, $Result) { return @{ jsonrpc = '2.0'; id = $Id; result = $Result } }
function New-RpcError($Id, [int]$Code, [string]$Message) {
    return @{ jsonrpc = '2.0'; id = $Id; error = @{ code = $Code; message = $Message } }
}

function Invoke-McpMessage($Msg) {
    $hasId = $Msg.PSObject.Properties.Name -contains 'id'
    switch ($Msg.method) {
        'initialize' {
            $version = '2025-06-18'
            if ($Msg.params -and $Msg.params.protocolVersion) { $version = $Msg.params.protocolVersion }
            return (New-RpcResult $Msg.id @{
                protocolVersion = $version
                capabilities    = @{ tools = @{} }
                serverInfo      = @{ name = 'api-cache'; version = '0.4.0' }
                instructions    = $script:ServerInstructions
            })
        }
        'ping'       { return (New-RpcResult $Msg.id @{}) }
        'tools/list' { return (New-RpcResult $Msg.id @{ tools = $Tools }) }
        'tools/call' {
            $toolName = [string]$Msg.params.name
            if ($toolName -ne 'ask_claude') {
                if (-not ($Tools | Where-Object { $_.name -eq $toolName })) {
                    return (New-RpcResult $Msg.id @{ content = @(@{ type = 'text'; text = "Unknown tool: $toolName" }); isError = $true })
                }
                try { $r = Invoke-CacheTool $toolName $Msg.params.arguments }
                catch {
                    Write-Log "$toolName failed: $($_.Exception.Message)" 'warn'
                    $r = @{ Text = $_.Exception.Message; IsError = $true }
                }
                return (New-RpcResult $Msg.id @{ content = @(@{ type = 'text'; text = [string]$r.Text }); isError = [bool]$r.IsError })
            }
            $prompt = $null
            $args0  = $Msg.params.arguments
            if ($args0 -and ($args0.PSObject.Properties.Name -contains 'prompt')) { $prompt = [string]$args0.prompt }
            Invoke-AskTool $prompt $script:CurrentSource
            $e = $script:PendingEntry
            if ($e.error) {
                return (New-RpcResult $Msg.id @{ content = @(@{ type = 'text'; text = $e.error }); isError = $true })
            }
            $text = [string]$e.response
            if ($e.stop_reason -eq 'max_tokens') { $text += "`n`n[Response cut off at the max_tokens limit]" }
            return (New-RpcResult $Msg.id @{ content = @(@{ type = 'text'; text = $text }) })
        }
        default {
            # Notifications (no id), e.g. notifications/initialized, get no reply.
            if ($hasId) { return (New-RpcError $Msg.id -32601 "Method not found: $($Msg.method)") }
            return $null
        }
    }
}

# Takes one raw JSON-RPC line, returns the raw response line (or $null),
# and records any tool call in history together with both raw messages.
function Invoke-RpcLine([string]$Line, [string]$Source) {
    $script:CurrentSource = $Source
    $script:PendingEntry  = $null
    try { $msg = ConvertFrom-Json -InputObject $Line }
    catch { return (ConvertTo-JsonLine (New-RpcError $null -32700 'Parse error')) }

    try { $resp = Invoke-McpMessage $msg }
    catch {
        $resp = $null
        if ($msg.PSObject.Properties.Name -contains 'id') { $resp = New-RpcError $msg.id -32603 $_.Exception.Message }
    }

    $json = $null
    if ($null -ne $resp) { $json = ConvertTo-JsonLine $resp }
    if ($script:PendingEntry) {
        $script:PendingEntry.rpc_request  = $Line
        $script:PendingEntry.rpc_response = $json
        Add-HistoryEntry $script:PendingEntry
    }
    return $json
}

# ---------------------------------------------------------------------------
# Debug page (localhost only)
# ---------------------------------------------------------------------------
$script:UiHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>api-cache debugger</title>
<style>
  :root {
    --bg: #f6f5f2; --panel: #ffffff; --text: #1f1e1c; --muted: #75726b; --line: #e3e0d9;
    --prompt-bg: #ece9e2; --reply-bg: #ffffff; --accent: #c2603a; --accent-text: #ffffff;
    --err-bg: #fbe9e6; --err-text: #9c2f1c; --ok: #2f8a4c; --bad: #b8402a; --code-bg: #f1efea;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1b1a18; --panel: #242320; --text: #ece9e3; --muted: #9d998f; --line: #36342f;
      --prompt-bg: #302e2a; --reply-bg: #242320; --accent: #e07a52; --accent-text: #1b1a18;
      --err-bg: #3a221c; --err-text: #f2a593; --ok: #5cc27d; --bad: #e8735a; --code-bg: #1f1e1b;
    }
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text);
    font: 14px/1.5 "Segoe UI", system-ui, -apple-system, sans-serif; }

  /* Full-height column: header / scrolling history / pinned dock. */
  body { display: flex; flex-direction: column; height: 100vh; height: 100dvh; overflow: hidden; }
  header { flex: none; display: flex; align-items: center; gap: 10px; padding: 10px 16px;
    background: var(--panel); border-bottom: 1px solid var(--line); }
  #scroller { flex: 1 1 auto; min-height: 0; overflow-y: auto; overscroll-behavior: contain; }
  .dock { flex: none; background: var(--panel); border-top: 1px solid var(--line); }

  header h1 { font-size: 15px; margin: 0; font-weight: 600; white-space: nowrap; }
  .pill { font: 12px/1 ui-monospace, Consolas, monospace; padding: 4px 8px; border-radius: 999px;
    background: var(--prompt-bg); color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status { margin-left: auto; display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 12px; white-space: nowrap; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: none; }
  .dot.ok { background: var(--ok); } .dot.bad { background: var(--bad); }

  main { max-width: 860px; margin: 0 auto; padding: 16px 16px 8px; }
  .empty { color: var(--muted); text-align: center; padding: 48px 16px; }
  .entry { margin: 0 0 22px; }
  .meta { display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: 12px; color: var(--muted); margin-bottom: 6px; }
  .meta .src { font-weight: 600; }
  .meta .src.web { color: var(--accent); }
  .meta .tool { font: 11px/1.6 ui-monospace, Consolas, monospace; padding: 0 6px; border-radius: 6px; background: var(--prompt-bg); }
  .bubble { white-space: pre-wrap; overflow-wrap: anywhere; padding: 10px 12px; border-radius: 10px;
    border: 1px solid var(--line); }
  .bubble.prompt { background: var(--prompt-bg); margin-left: 48px; border-color: transparent; }
  .bubble.reply { background: var(--reply-bg); margin-top: 8px; margin-right: 48px; }
  .bubble.error { background: var(--err-bg); color: var(--err-text); margin-top: 8px; margin-right: 48px; border-color: transparent; }
  .bubble.waiting { color: var(--muted); font-style: italic; }
  details { margin-top: 6px; margin-right: 48px; font-size: 12px; }
  summary { cursor: pointer; color: var(--muted); }
  pre { margin: 6px 0 0; padding: 8px 10px; background: var(--code-bg); border: 1px solid var(--line);
    border-radius: 8px; overflow-x: auto; font: 12px/1.45 ui-monospace, Consolas, monospace; }
  .label { margin-top: 8px; color: var(--muted); }

  /* Debug log: three lines tall, always visible, newest line always shown. */
  .log { height: calc(3 * 18px + 8px); overflow-y: auto; padding: 4px 16px;
    background: var(--code-bg); border-bottom: 1px solid var(--line);
    font: 12px/18px ui-monospace, Consolas, monospace; color: var(--muted); }
  .logline { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .logline .t { margin-right: 8px; opacity: .8; }
  .logline:last-child { color: var(--text); }
  .logline.warn, .logline.warn:last-child { color: var(--accent); }
  .logline.error, .logline.error:last-child { color: var(--bad); }

  .composer { max-width: 860px; margin: 0 auto; padding: 10px 16px 4px; display: flex; gap: 8px; align-items: stretch; }
  textarea { flex: 1; height: 64px; resize: none; padding: 10px 12px; border-radius: 10px;
    border: 1px solid var(--line); background: var(--bg); color: var(--text); font: inherit; }
  textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
  button { padding: 0 18px; border: 0; border-radius: 10px; background: var(--accent); color: var(--accent-text);
    font: inherit; font-weight: 600; cursor: pointer; }
  button:disabled { opacity: .5; cursor: default; }
  .hint { max-width: 860px; margin: 0 auto; padding: 0 16px 8px; font-size: 11px; color: var(--muted); }
  @media (max-width: 560px) {
    .bubble.prompt { margin-left: 16px; } .bubble.reply, .bubble.error, details { margin-right: 0; }
    header h1 { font-size: 14px; }
  }
</style>
</head>
<body>
<header>
  <h1>api-cache debugger</h1>
  <span class="pill" id="model">model: ?</span>
  <span class="pill" id="sys" title="system-prompt.md + files in context\, sent before every prompt">system: ?</span>
  <span class="status"><span class="dot" id="dot"></span><span id="status">connecting</span></span>
</header>

<div id="scroller">
  <main id="log"><div class="empty" id="empty">No prompts yet. Send one below, or call <code>ask_claude</code> from your MCP client.</div></main>
</div>

<div class="dock">
  <div class="log" id="loglines" aria-label="Server log" aria-live="polite"></div>
  <form id="form">
    <div class="composer">
      <textarea id="prompt" placeholder="Send one prompt through the ask_claude tool"></textarea>
      <button id="send" type="submit">Send</button>
    </div>
    <div class="hint">Enter to send, Shift+Enter for a new line. Each prompt is independent; Claude doesn't see earlier ones.</div>
  </form>
</div>

<script>
const TOKEN = "__TOKEN__";
const scroller = document.getElementById('scroller');
const log = document.getElementById('log');
const empty = document.getElementById('empty');
const form = document.getElementById('form');
const input = document.getElementById('prompt');
const sendBtn = document.getElementById('send');
const logLines = document.getElementById('loglines');
let lastId = 0, lastLogId = 0, polling = false;

async function api(path, opts = {}) {
  opts.headers = Object.assign({ 'X-Debug-Token': TOKEN }, opts.headers || {});
  const r = await fetch(path, opts);
  if (!r.ok) { const e = new Error('HTTP ' + r.status); e.status = r.status; throw e; }
  return r.json();
}
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function pretty(raw) {
  if (!raw) return '(none)';
  try { return JSON.stringify(JSON.parse(raw), null, 2); } catch { return raw; }
}
function nearBottom() { return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 120; }
function toBottom() { scroller.scrollTop = scroller.scrollHeight; }

// Server log: always jump to the newest line when one arrives.
function addLogs(list) {
  let added = false;
  for (const l of list) {
    if (l.id <= lastLogId) continue;
    const row = el('div', 'logline ' + (l.level || 'info'));
    const t = new Date(l.time);
    row.append(el('span', 't', isNaN(t) ? '' : t.toLocaleTimeString()), document.createTextNode(l.text));
    row.title = l.text;
    logLines.append(row);
    lastLogId = l.id;
    added = true;
  }
  while (logLines.childElementCount > 500) logLines.firstElementChild.remove();
  if (added) logLines.scrollTop = logLines.scrollHeight;
}

function renderEntry(e) {
  const art = el('article', 'entry');
  const meta = el('div', 'meta');
  meta.append(el('span', null, '#' + e.id));
  const t = new Date(e.time);
  meta.append(el('span', null, isNaN(t) ? e.time : t.toLocaleString()));
  meta.append(el('span', 'src ' + (e.source === 'web' ? 'web' : 'mcp'), e.source === 'web' ? 'from this page' : 'from MCP client'));
  if (e.tool) meta.append(el('span', 'tool', e.tool));
  if (e.model) meta.append(el('span', null, e.model));
  if (e.duration_ms != null) meta.append(el('span', null, (e.duration_ms / 1000).toFixed(1) + ' s'));
  if (e.input_tokens != null) meta.append(el('span', null, e.input_tokens + ' in / ' + e.output_tokens + ' out tokens'));
  if (e.system_chars) meta.append(el('span', null, 'system ' + e.system_chars.toLocaleString() + ' chars'));
  if (e.cache_read_tokens != null || e.cache_write_tokens != null)
    meta.append(el('span', null, 'cache ' + (e.cache_read_tokens || 0) + ' read / ' + (e.cache_write_tokens || 0) + ' written'));
  art.append(meta, el('div', 'bubble prompt', e.prompt || '(empty)'));
  if (e.error) {
    art.append(el('div', 'bubble error', e.error));
  } else {
    let text = e.response || '';
    if (e.stop_reason === 'max_tokens') text += '\n\n[cut off at the max_tokens limit]';
    art.append(el('div', 'bubble reply', text));
  }
  const d = el('details');
  d.append(el('summary', null, 'Raw JSON-RPC'));
  d.append(el('div', 'label', 'Request'), el('pre', null, pretty(e.rpc_request)));
  d.append(el('div', 'label', 'Response'), el('pre', null, pretty(e.rpc_response)));
  art.append(d);
  return art;
}
function addEntries(list) {
  const stick = nearBottom();
  let added = false;
  for (const e of list) {
    if (e.id <= lastId) continue;
    log.append(renderEntry(e));
    lastId = e.id;
    added = true;
  }
  empty.style.display = lastId ? 'none' : '';
  if (stick && added) toBottom();
}
function setStatus(ok, model, text) {
  document.getElementById('dot').className = 'dot ' + (ok ? 'ok' : 'bad');
  document.getElementById('status').textContent = text || (ok ? 'server running' : 'server not reachable');
  if (model) document.getElementById('model').textContent = 'model: ' + model;
}
async function poll() {
  if (polling) return;
  polling = true;
  try {
    const d = await api('/api/history?since=' + lastId + '&logSince=' + lastLogId);
    setStatus(true, d.model);
    document.getElementById('sys').textContent = d.systemChars
      ? 'system: ' + d.systemChars.toLocaleString() + ' chars' + (d.systemFiles ? ', ' + d.systemFiles + ' file' + (d.systemFiles > 1 ? 's' : '') : '')
      : 'no system context';
    addLogs(d.logs || []);
    addEntries(d.entries || []);
  } catch (err) {
    // 403 = a newer server instance is running with a new token; it opened its own window.
    setStatus(false, null, err.status === 403 ? 'server restarted - use the new window' : null);
  }
  finally { polling = false; }
}

form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const prompt = input.value;
  if (!prompt.trim()) return;
  sendBtn.disabled = true;
  input.value = '';
  const pending = el('article', 'entry');
  pending.append(el('div', 'meta', 'sending...'), el('div', 'bubble prompt', prompt),
                 el('div', 'bubble reply waiting', 'Waiting for Claude...'));
  log.append(pending); empty.style.display = 'none'; toBottom();
  try {
    await api('/api/ask', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify({ prompt }) });
    pending.remove();
    await poll();
    toBottom();
  } catch (err) {
    const w = pending.querySelector('.waiting');
    w.className = 'bubble error';
    w.textContent = 'Could not reach the server: ' + err.message;
    if (!input.value) input.value = prompt;   // give the prompt back so it isn't lost
  } finally {
    sendBtn.disabled = false;
    input.focus();
  }
});
input.addEventListener('keydown', (ev) => {
  // Enter sends; Shift+Enter falls through to the default (new line).
  // isComposing skips Enter presses that confirm IME input.
  if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing) {
    ev.preventDefault();
    if (!sendBtn.disabled) form.requestSubmit();
  }
});

poll().then(toBottom);
setInterval(poll, 1000);
input.focus();
</script>
</body>
</html>
'@

$script:UiToken = [guid]::NewGuid().ToString('N')
$script:UiHtml  = $script:UiHtml.Replace('__TOKEN__', $script:UiToken)
$script:WebCallCount = 0

function Start-DebugUi([int]$Port) {
    for ($p = $Port; $p -lt $Port + 10; $p++) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://localhost:$p/")
        try {
            $l.Start()
            $script:UiUrl = "http://localhost:$p/"
            return $l
        } catch { $l.Close() }
    }
    return $null
}

# --- Debug window (one at a time, across all api-cache server instances) ---
# Edge "app" mode gives a chromeless window, close to a webview. Each server
# instance uses its own private profile (--user-data-dir), so its window is a
# separate Edge process that can be found and closed without touching your
# normal Edge windows. Start-Process uses ShellExecute, so children never
# inherit our stdout.
$script:WebviewProfile    = $null
$script:LastWebviewLaunch = $null
$script:WatchdogStarted   = $false

function Get-WebviewBase {
    $b = $env:LOCALAPPDATA
    if (-not $b) { $b = [System.IO.Path]::GetTempPath() }
    return (Join-Path $b 'api-cache-mcp')
}

# True if a process command line belongs to the given profile directory.
function Test-ProfileMatch([string]$CommandLine, [string]$ProfileDir) {
    if (-not $CommandLine) { return $false }
    return ($CommandLine.IndexOf($ProfileDir + '"', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($ProfileDir + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Every Edge process started for any api-cache debug window.
function Get-WebviewProcesses {
    $marker = Join-Path (Get-WebviewBase) 'webview-'
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
    } catch {}
}

function Stop-Processes($Procs) {
    foreach ($p in @($Procs)) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
}

function Stop-OwnWebview {
    if (-not $script:WebviewProfile) { return }
    Stop-Processes @(Get-WebviewProcesses | Where-Object { Test-ProfileMatch $_.CommandLine $script:WebviewProfile })
}

function Start-WebviewWatchdog {
    # A hidden process that waits for this server to exit (any way: client
    # disconnect, Ctrl+C, console closed, crash) and then closes our window.
    if ($script:WatchdogStarted) { return }
    try {
        $dir = $script:WebviewProfile.Replace("'", "''")
        $cmd = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; " +
               "Get-CimInstance Win32_Process -Filter `"Name = 'msedge.exe'`" | " +
               "Where-Object { `$_.CommandLine -and (`$_.CommandLine.Contains('$dir`"') -or `$_.CommandLine.Contains('$dir\')) } | " +
               "ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }"
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
        $script:WatchdogStarted = $true
    } catch { Write-Log "could not start the window watchdog: $($_.Exception.Message)" 'warn' }
}

# Idempotent: focuses our window if it is open, otherwise closes any other
# api-cache window and opens ours. Never leaves two windows.
function Open-Webview {
    if (-not $script:UiUrl) { return @{ Status = 'unavailable'; Message = 'The debug page is not running (no free port).' } }
    if (-not $script:WebviewProfile) { $script:WebviewProfile = Join-Path (Get-WebviewBase) "webview-$(([uri]$script:UiUrl).Port)" }

    $all    = @(Get-WebviewProcesses)
    $own    = @($all | Where-Object { Test-ProfileMatch $_.CommandLine $script:WebviewProfile })
    $others = @($all | Where-Object { -not (Test-ProfileMatch $_.CommandLine $script:WebviewProfile) })
    $note = ''
    if ($others.Count) {
        Stop-Processes $others
        $note = ' Closed the window of another api-cache server first.'
    }

    if ($own.Count) {
        foreach ($p in $own) {
            try {
                $gp = Get-Process -Id $p.ProcessId -ErrorAction Stop
                if ($gp.MainWindowHandle -ne [IntPtr]::Zero) {
                    try { $null = (New-Object -ComObject WScript.Shell).AppActivate([int]$gp.Id) } catch {}
                    return @{ Status = 'already_open'; Message = "The debug window is already open; brought it to the front.$note" }
                }
            } catch {}
        }
        if ($script:LastWebviewLaunch -and ([DateTime]::UtcNow - $script:LastWebviewLaunch).TotalSeconds -lt 15) {
            return @{ Status = 'starting'; Message = "The debug window is still starting.$note" }
        }
        Stop-Processes $own   # left running in the background without a window
    }

    try {
        Start-Process -FilePath 'msedge.exe' -ArgumentList @(
            "--app=$($script:UiUrl)", "--user-data-dir=`"$($script:WebviewProfile)`"",
            '--no-first-run', '--no-default-browser-check', '--hide-crash-restore-bubble',
            '--window-size=640,860')
    } catch {
        try { Start-Process $script:UiUrl } catch { return @{ Status = 'failed'; Message = "Could not open a browser: $($_.Exception.Message)" } }
        return @{ Status = 'opened_in_browser'; Message = "Edge was not found, so the page opened in the default browser (that tab can not be tracked or closed automatically).$note" }
    }
    $script:LastWebviewLaunch = [DateTime]::UtcNow
    Start-WebviewWatchdog
    return @{ Status = 'opened'; Message = "Opened the debug window.$note" }
}

function Send-Http($Res, [int]$Code, [string]$ContentType, [string]$Body) {
    $bytes = $script:Utf8.GetBytes($Body)
    $Res.StatusCode = $Code
    $Res.ContentType = $ContentType
    $Res.AddHeader('Cache-Control', 'no-store')
    $Res.ContentLength64 = $bytes.Length
    $Res.OutputStream.Write($bytes, 0, $bytes.Length)
    $Res.OutputStream.Close()
}

function Send-JsonHttp($Res, [int]$Code, $Object) {
    Send-Http $Res $Code 'application/json; charset=utf-8' (ConvertTo-JsonLine $Object)
}

function Invoke-HttpRequest($Ctx) {
    $req = $Ctx.Request
    $res = $Ctx.Response
    try {
        if (-not $req.IsLocal) { Send-Http $res 403 'text/plain' 'Forbidden'; return }
        $path = $req.Url.AbsolutePath

        if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
            Send-Http $res 200 'text/html; charset=utf-8' $script:UiHtml
            return
        }

        if ($path.StartsWith('/api/')) {
            # A per-launch token stops other web pages in your browser from calling the API.
            if ($req.Headers['X-Debug-Token'] -ne $script:UiToken) { Send-Http $res 403 'text/plain' 'Bad token'; return }

            if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/history') {
                $since = 0
                [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
                $items = @($script:History | Where-Object { [int]$_.id -gt $since })
                $logSince = 0
                [void][int]::TryParse([string]$req.QueryString['logSince'], [ref]$logSince)
                $logs = @($script:Logs | Where-Object { [int]$_.id -gt $logSince })
                $cur = Get-Settings
                $sysChars = 0
                if ($cur.SystemPrompt) { $sysChars = $cur.SystemPrompt.Length }
                Send-JsonHttp $res 200 @{ model = $cur.Model; systemChars = $sysChars; systemFiles = $cur.SystemFiles; entries = $items; logs = $logs }
                return
            }

            if ($req.HttpMethod -eq 'POST' -and $path -eq '/api/ask') {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $script:Utf8)
                $raw = $reader.ReadToEnd()
                $reader.Dispose()
                $prompt = [string](ConvertFrom-Json -InputObject $raw).prompt

                # Build a real tools/call message so the page exercises the same MCP path.
                $script:WebCallCount++
                $rpc = @{
                    jsonrpc = '2.0'
                    id      = "web-$($script:WebCallCount)"
                    method  = 'tools/call'
                    params  = @{ name = 'ask_claude'; arguments = @{ prompt = $prompt } }
                }
                $null = Invoke-RpcLine (ConvertTo-JsonLine $rpc) 'web'
                Send-JsonHttp $res 200 $script:PendingEntry
                return
            }
        }

        Send-Http $res 404 'text/plain' 'Not found'
    }
    catch {
        Write-Log "debug page request failed: $($_.Exception.Message)" 'error'
        try { Send-JsonHttp $res 500 @{ error = $_.Exception.Message } } catch {}
    }
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
Import-History
$startup = Get-Settings
$keyState = 'missing'
if ($startup.ApiKey) { $keyState = 'found' }
$keyLevel = 'info'
if (-not $startup.ApiKey) { $keyLevel = 'warn' }
Write-Log "started (PowerShell $($PSVersionTable.PSVersion)), model $($startup.Model), API key $keyState, prompt caching on ($($startup.CacheTtl) TTL), $($script:History.Count) history entries" $keyLevel

$script:Listener = Start-DebugUi $startup.UiPort
if ($script:Listener) {
    Write-Log "debug page at $($script:UiUrl)"
    if ($startup.UiOpen) {
        $w = Open-Webview
        $lvl = 'info'; if ($w.Status -notin @('opened', 'already_open', 'starting')) { $lvl = 'warn' }
        Write-Log $w.Message $lvl
    }
} else {
    # No page to show logs on, so this one goes to the terminal.
    [Console]::Error.WriteLine("[api-cache-mcp] debug page disabled: ports $($startup.UiPort)-$($startup.UiPort + 9) are all busy")
}

# ---------------------------------------------------------------------------
# Main loop: wait on stdin and the HTTP listener at the same time, one thread.
# A Claude call blocks both briefly, which is fine for a debugging tool.
# ---------------------------------------------------------------------------
$readTask = $script:In.ReadLineAsync()
$ctxTask  = $null
if ($script:Listener) { $ctxTask = $script:Listener.GetContextAsync() }

try {
    while ($true) {
        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        $tasks.Add($readTask)
        if ($ctxTask) { $tasks.Add($ctxTask) }
        [void][System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 1000)

        if ($readTask.IsCompleted) {
            if ($readTask.IsFaulted) { Write-Log 'stdin read failed' 'error'; break }
            $line = $readTask.Result
            if ($null -eq $line) { break }   # client closed stdin
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $json = Invoke-RpcLine $line 'mcp'
                if ($json) { $script:Out.WriteLine($json) }
            }
            $readTask = $script:In.ReadLineAsync()
        }

        if ($ctxTask -and $ctxTask.IsCompleted) {
            if ($ctxTask.IsFaulted) { Write-Log 'debug page listener error' 'error' }
            else { Invoke-HttpRequest $ctxTask.Result }
            $ctxTask = $script:Listener.GetContextAsync()
        }
    }
}
finally {
    if ($script:Listener) { try { $script:Listener.Stop(); $script:Listener.Close() } catch {} }
    # Fast path for a normal exit; the watchdog covers everything else.
    Stop-OwnWebview
}
