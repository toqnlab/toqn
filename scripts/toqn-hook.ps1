# Toqn Hook v4 (Claude Code + Cursor + Copilot)
# Usage: <command> | pwsh toqn-hook.ps1 <source>
# Sources: claude-code, cursor, copilot
#
# Env vars:
#   TOQN_API_KEY       - required, get from toqn.dev/settings
#   TOQN_URL           - optional, defaults to https://toqn.dev
#   TOQN_DEBUG         - set to 1 to log raw input, parsed stats, payload, and server response
#   TOQN_AUTO_UPDATE   - set to 1 to enable self-updating when server signals new version

param([string]$Source)

$TOQN_HOOK_VERSION = "4"

# --- Preamble ---
$ApiKey = $env:TOQN_API_KEY

if (-not $ApiKey) {
  $configFiles = @(
    "$HOME/.bashrc",
    "$HOME/.bash_profile",
    "$HOME/.zshrc",
    "$HOME/.profile",
    "$HOME/Documents/PowerShell/Microsoft.PowerShell_profile.ps1",
    "$HOME/.config/powershell/Microsoft.PowerShell_profile.ps1"
  )
  foreach ($f in $configFiles) {
    if (Test-Path $f) {
      $match = Select-String -Path $f -Pattern 'TOQN_API_KEY="([^"]*)"' -AllMatches | Select-Object -Last 1
      if ($match) {
        $ApiKey = $match.Matches[0].Groups[1].Value
        if ($ApiKey) { break }
      }
      # Also try single-quoted and bare assignment (PowerShell $env:TOQN_API_KEY = '...')
      $match = Select-String -Path $f -Pattern "TOQN_API_KEY='([^']*)'" -AllMatches | Select-Object -Last 1
      if ($match) {
        $ApiKey = $match.Matches[0].Groups[1].Value
        if ($ApiKey) { break }
      }
      # PowerShell style: $env:TOQN_API_KEY = "..."
      $match = Select-String -Path $f -Pattern '\$env:TOQN_API_KEY\s*=\s*"([^"]*)"' -AllMatches | Select-Object -Last 1
      if ($match) {
        $ApiKey = $match.Matches[0].Groups[1].Value
        if ($ApiKey) { break }
      }
    }
  }
}

if (-not $ApiKey) { exit 0 }

$ToqnUrl = if ($env:TOQN_URL) { $env:TOQN_URL } else { "https://toqn.dev" }

if (-not $Source) {
  [Console]::Error.WriteLine("usage: toqn-hook.ps1 <source>")
  exit 1
}

# Read stdin — $input is reserved in PowerShell
$StdinData = @($input) | Out-String
$StdinData = $StdinData.Trim()

# --- Debug ---
$Debug_ = if ($env:TOQN_DEBUG -eq "1") { $true } else { $false }
$DebugDir = if ($IsWindows -or $env:OS -match "Windows") {
  Join-Path $env:TEMP "toqn-debug"
} else {
  "/tmp/toqn-debug"
}

$LogFile = $null
if ($Debug_) {
  if (-not (Test-Path $DebugDir)) { New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null }
  $LogFile = Join-Path $DebugDir "$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

function Write-DebugLog($msg) {
  if ($Debug_ -and $LogFile) {
    "[$((Get-Date).ToString('HH:mm:ss'))] $msg" | Out-File -Append -FilePath $LogFile -Encoding utf8
  }
}

function Write-DebugJson($label, $data) {
  if ($Debug_ -and $LogFile) {
    "[$((Get-Date).ToString('HH:mm:ss'))] ${label}:" | Out-File -Append -FilePath $LogFile -Encoding utf8
    $data | Out-File -Append -FilePath $LogFile -Encoding utf8
  }
}

Write-DebugJson "stdin" $StdinData
Write-DebugLog "source=$Source"

# --- Common POST ---
function Send-Payload($Payload) {
  $headers = @{
    "Authorization"   = "Bearer $ApiKey"
    "X-Toqn-Source" = $Source
    "X-Toqn-Hook"   = $TOQN_HOOK_VERSION
    "Content-Type"    = "application/json"
  }

  try {
    $response = Invoke-WebRequest -Uri "$ToqnUrl/api/ingest/v2" `
      -Method POST `
      -Headers $headers `
      -Body $Payload `
      -TimeoutSec 10 `
      -UseBasicParsing `
      -ErrorAction Stop

    if ($Debug_) {
      Write-DebugJson "response headers" ($response.Headers | ConvertTo-Json -Depth 2)
      Write-DebugJson "response body" $response.Content
      Write-DebugLog "debug log: $LogFile"
      [Console]::Error.WriteLine("toqn: debug log at $LogFile")
    }

    # Self-update check
    $updateUrl = $null
    if ($response.Headers.ContainsKey("X-Toqn-Update")) {
      $updateUrl = $response.Headers["X-Toqn-Update"]
      if ($updateUrl -is [array]) { $updateUrl = $updateUrl[0] }
    }

    if ($updateUrl -and $env:TOQN_AUTO_UPDATE -eq "1") {
      $toqnDir = Join-Path $HOME ".toqn"
      $tmpFile = Join-Path $toqnDir "hook.ps1.tmp"
      $targetFile = Join-Path $toqnDir "hook.ps1"
      try {
        if (-not (Test-Path $toqnDir)) { New-Item -ItemType Directory -Path $toqnDir -Force | Out-Null }
        Invoke-WebRequest -Uri $updateUrl -OutFile $tmpFile -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        # Syntax check: try parsing the script
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tmpFile, [ref]$null, [ref]$errors)
        if ($errors.Count -eq 0) {
          Move-Item -Path $tmpFile -Destination $targetFile -Force
          Write-DebugLog "self-updated from $updateUrl"
        } else {
          Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
          Write-DebugLog "self-update failed syntax check"
        }
      } catch {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        Write-DebugLog "self-update download failed: $_"
      }
    }
  } catch {
    if ($Debug_) {
      Write-DebugLog "POST failed: $_"
      Write-DebugLog "debug log: $LogFile"
      [Console]::Error.WriteLine("toqn: debug log at $LogFile")
    }
  }
}

# --- Extractors ---
function Extract-ClaudeCode {
  $envelope = $StdinData | ConvertFrom-Json

  $transcriptPath = $envelope.transcript_path
  if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { exit 0 }

  $sessionId = if ($envelope.session_id) { $envelope.session_id } else { "" }
  $cwd = if ($envelope.cwd) { $envelope.cwd } else { "" }
  $project = if ($cwd) { Split-Path $cwd -Leaf } else { "unknown" }

  # Parse JSONL transcript
  $lines = Get-Content -Path $transcriptPath -Encoding utf8
  $assistantEntries = @()
  foreach ($line in $lines) {
    $line = $line.Trim()
    if (-not $line) { continue }
    try {
      $entry = $line | ConvertFrom-Json
      if ($entry.type -eq "assistant") {
        $assistantEntries += $entry
      }
    } catch { continue }
  }

  if ($assistantEntries.Count -eq 0) { exit 0 }

  # Extract model from last entry
  $model = "unknown"
  foreach ($entry in $assistantEntries) {
    if ($entry.message -and $entry.message.model) {
      $model = $entry.message.model
    }
  }

  # Build turns array
  $turns = @()
  foreach ($entry in $assistantEntries) {
    $usage = $null
    if ($entry.message -and $entry.message.usage) { $usage = $entry.message.usage }
    $turns += @{
      input        = if ($usage -and $usage.input_tokens) { $usage.input_tokens } else { 0 }
      output       = if ($usage -and $usage.output_tokens) { $usage.output_tokens } else { 0 }
      cache_create = if ($usage -and $usage.cache_creation_input_tokens) { $usage.cache_creation_input_tokens } else { 0 }
      cache_read   = if ($usage -and $usage.cache_read_input_tokens) { $usage.cache_read_input_tokens } else { 0 }
    }
  }

  $payload = @{
    model      = $model
    turns      = $turns
    session_id = $sessionId
    project    = $project
  } | ConvertTo-Json -Depth 4 -Compress

  Write-DebugJson "payload" $payload
  Send-Payload $payload
}

function Extract-Cursor {
  $envelope = $StdinData | ConvertFrom-Json

  $model = if ($envelope.model) { $envelope.model } else { "unknown" }
  $cwd = if ($envelope.workspace_roots -and $envelope.workspace_roots.Count -gt 0) { $envelope.workspace_roots[0] } else { "" }
  $project = if ($cwd) { Split-Path $cwd -Leaf } else { "unknown" }
  $conversationId = if ($envelope.conversation_id) { $envelope.conversation_id } else { "" }

  $transcriptPath = $envelope.transcript_path
  $numTurns = 0
  $estInput = 0
  $estOutput = 0

  if ($transcriptPath -and (Test-Path $transcriptPath)) {
    $lines = Get-Content -Path $transcriptPath -Encoding utf8
    foreach ($line in $lines) {
      $line = $line.Trim()
      if (-not $line) { continue }
      try {
        $entry = $line | ConvertFrom-Json
        if ($entry.role -eq "assistant") {
          $numTurns++
          if ($entry.content) {
            $estOutput += [Math]::Ceiling($entry.content.Length / 4)
          }
        } elseif ($entry.role -eq "user") {
          if ($entry.content) {
            $estInput += [Math]::Ceiling($entry.content.Length / 4)
          }
        }
      } catch { continue }
    }
  }

  $payload = @{
    model                   = $model
    project                 = $project
    conversation_id         = $conversationId
    num_turns               = $numTurns
    estimated_input_tokens  = $estInput
    estimated_output_tokens = $estOutput
  } | ConvertTo-Json -Depth 4 -Compress

  Write-DebugJson "payload" $payload
  Send-Payload $payload
}

function Extract-Copilot {
  $envelope = $StdinData | ConvertFrom-Json

  $transcriptPath = $envelope.transcript_path
  $sessionId = if ($envelope.sessionId) { $envelope.sessionId } else { "" }
  $cwd = if ($envelope.cwd) { $envelope.cwd } else { "" }
  $project = if ($cwd) { Split-Path $cwd -Leaf } else { "unknown" }

  $model = "unknown"
  $numTurns = 0
  $estInput = 0
  $estOutput = 0
  $tools = @{}
  $gitCommits = 0
  $gitPushes = 0
  $toolErrors = 0
  $filesChanged = @{}

  if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
      $transcript = Get-Content -Path $transcriptPath -Raw -Encoding utf8 | ConvertFrom-Json

      # Handle both array format and object-with-messages format
      $allMsgs = if ($transcript -is [array]) { $transcript } elseif ($transcript.messages) { $transcript.messages } elseif ($transcript.turns) { $transcript.turns } else { @() }

      # Track offset to avoid inflating usage on repeated Stop events
      $offsetDir = if ($IsWindows -or $env:OS -match "Windows") {
        Join-Path $env:TEMP "toqn-copilot-offsets"
      } else { "/tmp/toqn-copilot-offsets" }
      if (-not (Test-Path $offsetDir)) { New-Item -ItemType Directory -Path $offsetDir -Force | Out-Null }
      $offsetKey = if ($sessionId) { $sessionId -replace '[^a-zA-Z0-9_-]', '' } else { "default" }
      $offsetFile = Join-Path $offsetDir $offsetKey
      $prevOffset = 0
      if (Test-Path $offsetFile) { $prevOffset = [int](Get-Content $offsetFile -ErrorAction SilentlyContinue) }

      # Slice to only new messages since last Stop
      $msgs = if ($prevOffset -lt $allMsgs.Count) { $allMsgs[$prevOffset..($allMsgs.Count - 1)] } else { @() }

      # Save current total for next invocation
      $allMsgs.Count | Out-File -FilePath $offsetFile -Encoding utf8 -NoNewline -ErrorAction SilentlyContinue

      # Always read model from full transcript (last seen)
      foreach ($m in $allMsgs) { if ($m.model) { $model = $m.model } }

      foreach ($msg in $msgs) {
        if ($msg.role -eq "assistant") {
          $numTurns++
          $content = $msg.content
          if ($content -is [string]) {
            $estOutput += [Math]::Ceiling($content.Length / 4)
          } elseif ($content -is [array]) {
            foreach ($part in $content) {
              $text = if ($part.text) { $part.text } else { "" }
              $estOutput += [Math]::Ceiling($text.Length / 4)
            }
          }
          if ($msg.tool_calls) {
            foreach ($tc in $msg.tool_calls) {
              $toolName = if ($tc.function -and $tc.function.name) { $tc.function.name } elseif ($tc.type) { $tc.type } else { "unknown" }
              if ($tools.ContainsKey($toolName)) { $tools[$toolName]++ } else { $tools[$toolName] = 1 }
              if ($toolName -eq "runTerminalCommand" -and $tc.function -and $tc.function.arguments) {
                if ($tc.function.arguments -match "git commit") { $gitCommits++ }
                if ($tc.function.arguments -match "git push") { $gitPushes++ }
              }
              if ($toolName -match "editFiles|createFile" -and $tc.function -and $tc.function.arguments) {
                try {
                  $args_ = $tc.function.arguments | ConvertFrom-Json
                  $filePath = if ($args_.file) { $args_.file } elseif ($args_.path) { $args_.path } else { "" }
                  if ($filePath) {
                    $ext = [System.IO.Path]::GetExtension($filePath).TrimStart('.')
                    if ($ext) {
                      if ($filesChanged.ContainsKey($ext)) { $filesChanged[$ext]++ } else { $filesChanged[$ext] = 1 }
                    }
                  }
                } catch {}
              }
            }
          }
        } elseif ($msg.role -eq "user") {
          $content = $msg.content
          if ($content -is [string]) {
            $estInput += [Math]::Ceiling($content.Length / 4)
          } elseif ($content -is [array]) {
            foreach ($part in $content) {
              $text = if ($part.text) { $part.text } else { "" }
              $estInput += [Math]::Ceiling($text.Length / 4)
            }
          }
        } elseif ($msg.role -eq "tool") {
          $content = if ($msg.content) { $msg.content } else { "" }
          if ($content -match "error|Error|ERROR") { $toolErrors++ }
        }
      }
    } catch {
      Write-DebugLog "transcript parse failed: $_"
    }
  }

  $payload = @{
    model                   = $model
    project                 = $project
    session_id              = $sessionId
    num_turns               = $numTurns
    estimated_input_tokens  = $estInput
    estimated_output_tokens = $estOutput
    tools                   = $tools
    git_commits             = $gitCommits
    git_pushes              = $gitPushes
    tool_errors             = $toolErrors
    files_changed           = $filesChanged
  } | ConvertTo-Json -Depth 4 -Compress

  Write-DebugJson "payload" $payload
  Send-Payload $payload
}

# --- Dispatch ---
switch ($Source) {
  "claude-code" { Extract-ClaudeCode }
  "copilot"     { Extract-Copilot }
  "cursor"      { Extract-Cursor }
  default {
    [Console]::Error.WriteLine("toqn: unknown source '$Source'")
    exit 0
  }
}

exit 0
