#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ApiKey = if ($args[0]) { $args[0] } else { $null }

if (-not $ApiKey) {
    # Try device authorization flow
    $ToqnBase = if ($env:TOQN_URL) { $env:TOQN_URL } else { "https://toqn.dev" }
    try {
        $DeviceResp = Invoke-RestMethod -Uri "$ToqnBase/api/auth/device" -Method POST -ErrorAction Stop
        if ($DeviceResp.device_code) {
            Write-Host ""
            Write-Host "  toqn — hook installer" -ForegroundColor White
            Write-Host ""
            Write-Host "  Code: $($DeviceResp.user_code)" -ForegroundColor DarkGray
            Write-Host "  URL: $($DeviceResp.verification_url)" -ForegroundColor DarkGray
            Write-Host ""
            Read-Host "  Press Enter to open the browser"

            Start-Process $DeviceResp.verification_url

            Write-Host "  Waiting for authorization... " -NoNewline -ForegroundColor DarkGray
            $Attempts = 0
            $MaxAttempts = 120
            while ($Attempts -lt $MaxAttempts) {
                Start-Sleep -Seconds $DeviceResp.interval
                try {
                    $TokenResp = Invoke-RestMethod -Uri "$ToqnBase/api/auth/device/token" -Method POST `
                        -ContentType "application/json" `
                        -Body (ConvertTo-Json @{ device_code = $DeviceResp.device_code }) -ErrorAction Stop
                    if ($TokenResp.status -eq "authorized") {
                        $ApiKey = $TokenResp.api_key
                        Write-Host "done" -ForegroundColor Green
                        break
                    } elseif ($TokenResp.status -eq "expired") {
                        Write-Host "expired" -ForegroundColor Red
                        break
                    }
                } catch {}
                $Attempts++
            }
        }
    } catch {}

    # Fallback: interactive prompt
    if (-not $ApiKey) {
        Write-Host ""
        Write-Host "  toqn — LLM token tracker" -ForegroundColor White
        Write-Host "  Get your API key at: https://toqn.dev/settings" -ForegroundColor DarkGray
        Write-Host ""
        $ApiKey = Read-Host "  Enter your API key"
    }

    if (-not $ApiKey) {
        Write-Host "  Error: API key is required." -ForegroundColor Red
        Write-Host '  Usage: irm toqn.dev/install/win | iex' -ForegroundColor DarkGray
        exit 1
    }
}

Write-Host ""
Write-Host "Installing toqn hook..." -ForegroundColor Cyan
Write-Host ""

$HookDir = Join-Path $HOME ".toqn"
$HookScript = Join-Path $HookDir "hook.ps1"

# 2. Create hook directory
if (-not (Test-Path $HookDir)) {
    New-Item -ItemType Directory -Path $HookDir -Force | Out-Null
}

# 3. Download hook script
Write-Host "Downloading hook script..."
Invoke-WebRequest -Uri "https://toqn.dev/scripts/toqn-hook.ps1" -OutFile $HookScript -UseBasicParsing

# 4. Add API key and auto-update to PowerShell profile
$ProfileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}

$ProfileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $ProfileContent) { $ProfileContent = "" }

if ($ProfileContent -match 'TOQN_API_KEY') {
    $ProfileContent = $ProfileContent -replace '\$env:TOQN_API_KEY\s*=\s*"[^"]*"', ('$env:TOQN_API_KEY = "' + $ApiKey + '"')
    Set-Content -Path $PROFILE -Value $ProfileContent -NoNewline
    Write-Host "Updated API key in $PROFILE"
} else {
    Add-Content -Path $PROFILE -Value "`n`$env:TOQN_API_KEY = `"$ApiKey`""
    Write-Host "Added API key to $PROFILE"
}

# 5. Ask about auto-update
$Answer = Read-Host -Prompt "Auto-update hook script? [Y/n]"
if ($Answer -match '^[nN]') {
    $AutoUpdate = "0"
} else {
    $AutoUpdate = "1"
}

# Re-read profile in case it was just modified
$ProfileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $ProfileContent) { $ProfileContent = "" }

if ($ProfileContent -match 'TOQN_AUTO_UPDATE') {
    $ProfileContent = $ProfileContent -replace '\$env:TOQN_AUTO_UPDATE\s*=\s*"[^"]*"', ('$env:TOQN_AUTO_UPDATE = "' + $AutoUpdate + '"')
    Set-Content -Path $PROFILE -Value $ProfileContent -NoNewline
} else {
    Add-Content -Path $PROFILE -Value "`n`$env:TOQN_AUTO_UPDATE = `"$AutoUpdate`""
}

# Set env vars for current session
$env:TOQN_API_KEY = $ApiKey
$env:TOQN_AUTO_UPDATE = $AutoUpdate

$Configured = @()

# 6. Configure Claude Code
$ClaudeDir = Join-Path $HOME ".claude"
if (Test-Path $ClaudeDir) {
    $SettingsFile = Join-Path $ClaudeDir "settings.json"
    $HookCommand = "powershell -File `"$HookScript`" claude-code"

    if (Test-Path $SettingsFile) {
        $Settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

        $AlreadyConfigured = $false
        if ($Settings.hooks -and $Settings.hooks.Stop) {
            foreach ($entry in $Settings.hooks.Stop) {
                foreach ($h in $entry.hooks) {
                    if ($h.command -and $h.command -like "*hook.ps1*claude-code*") {
                        $AlreadyConfigured = $true
                    }
                }
            }
        }

        if ($AlreadyConfigured) {
            Write-Host "Hook already configured in $SettingsFile"
        } else {
            if (-not $Settings.hooks) {
                $Settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            if (-not $Settings.hooks.Stop) {
                $Settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue @() -Force
            }

            $NewHook = [PSCustomObject]@{
                matcher = ""
                hooks = @(
                    [PSCustomObject]@{
                        type = "command"
                        command = $HookCommand
                        async = $true
                    }
                )
            }

            $Settings.hooks.Stop = @($Settings.hooks.Stop) + @($NewHook)
            $Settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile -Encoding UTF8
            Write-Host "Updated $SettingsFile"
        }
    } else {
        $Settings = [PSCustomObject]@{
            hooks = [PSCustomObject]@{
                Stop = @(
                    [PSCustomObject]@{
                        matcher = ""
                        hooks = @(
                            [PSCustomObject]@{
                                type = "command"
                                command = $HookCommand
                                async = $true
                            }
                        )
                    }
                )
            }
        }
        $Settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile -Encoding UTF8
        Write-Host "Created $SettingsFile"
    }

    $Configured += "Claude Code"
}

# 7. Configure Cursor
$CursorDir = Join-Path $HOME ".cursor"
if (Test-Path $CursorDir) {
    $CursorHooksFile = Join-Path $CursorDir "hooks.json"

    if (Test-Path $CursorHooksFile) {
        $CursorHooks = Get-Content $CursorHooksFile -Raw | ConvertFrom-Json

        $AlreadyConfigured = $false
        if ($CursorHooks.hooks -and $CursorHooks.hooks.stop) {
            foreach ($entry in $CursorHooks.hooks.stop) {
                if ($entry.command -like "*hook.ps1*cursor*") {
                    $AlreadyConfigured = $true
                }
            }
        }

        if ($AlreadyConfigured) {
            Write-Host "Hook already configured in $CursorHooksFile"
        } else {
            if (-not $CursorHooks.hooks) {
                $CursorHooks | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            if (-not $CursorHooks.hooks.stop) {
                $CursorHooks.hooks | Add-Member -NotePropertyName "stop" -NotePropertyValue @() -Force
            }

            $NewHook = [PSCustomObject]@{
                command = "powershell -File $HookScript cursor"
            }

            $CursorHooks.hooks.stop = @($CursorHooks.hooks.stop) + @($NewHook)
            $CursorHooks | ConvertTo-Json -Depth 10 | Set-Content $CursorHooksFile -Encoding UTF8
            Write-Host "Updated $CursorHooksFile"
        }
    } else {
        $CursorHooks = [PSCustomObject]@{
            version = 1
            hooks = [PSCustomObject]@{
                stop = @(
                    [PSCustomObject]@{
                        command = "powershell -File $HookScript cursor"
                    }
                )
            }
        }
        $CursorHooks | ConvertTo-Json -Depth 10 | Set-Content $CursorHooksFile -Encoding UTF8
        Write-Host "Created $CursorHooksFile"
    }
    $Configured += "Cursor"
}

# 8. Summary
Write-Host ""
if ($Configured.Count -gt 0) {
    $List = $Configured -join ", "
    Write-Host "Done! toqn hook installed for: $List" -ForegroundColor Green
} else {
    Write-Host "Done! Hook script installed at $HookScript" -ForegroundColor Green
    Write-Host "Note: Neither ~/.claude nor ~/.cursor directories found."
    Write-Host "The hook will be configured automatically when you install Claude Code or Cursor."
}
Write-Host "Run a completion in your AI tool to verify it's working."
Write-Host ""
