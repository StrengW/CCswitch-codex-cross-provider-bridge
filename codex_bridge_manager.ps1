[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('auto', 'start', 'repair', 'status', 'doctor', 'stop')]
    [string]$Command = 'auto',

    [string]$BridgeScript,
    [string]$CodexConfig,
    [string]$ListenAddress = '127.0.0.1',

    [ValidateRange(1, 65535)]
    [int]$BridgePort = 15722,

    [string]$UpstreamUrl = 'http://127.0.0.1:15721',
    [string]$ProviderId = 'custom',
    [string]$ProviderName = 'CC Switch Bridge',
    [string]$OfficialProviderId = 'cc-switch-official',
    # When supplied for the official route, this is written to config.toml and
    # passed to the bridge so old third-party sessions are replayed with the
    # selected official model instead of their stale session model.
    [string]$Model,

    # Foreground is retained as a compatibility alias. Foreground mode is now
    # the default; use -Background only when a detached process is desired.
    [switch]$Foreground,
    [switch]$Background,
    [switch]$FixedPort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Foreground -and $Background) {
    throw 'Foreground and Background cannot be used together.'
}
$RunForeground = -not $Background

# Windows PowerShell 5.1 can expose an empty $PSScriptRoot while evaluating
# default expressions inside param(...). Resolve path defaults only after
# parameter binding has completed.
$ManagerScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($BridgeScript)) {
    $BridgeScript = Join-Path $ManagerScriptDirectory 'codex_provider_bridge.py'
}

if ([string]::IsNullOrWhiteSpace($CodexConfig)) {
    $UserProfileDirectory = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($UserProfileDirectory)) {
        $UserProfileDirectory = $env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($UserProfileDirectory)) {
        throw 'Cannot locate the Windows user profile. Pass -CodexConfig explicitly.'
    }
    $CodexConfig = Join-Path (Join-Path $UserProfileDirectory '.codex') 'config.toml'
}

# Normalize paths before passing them to System.IO. This matters when the
# script is launched from a different working directory or when a caller
# supplies a relative -CodexConfig/-BridgeScript path. System.IO.File.Replace
# requires filesystem paths, not provider-relative or empty path fragments.
try {
    $CodexConfig = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($CodexConfig))
    $BridgeScript = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($BridgeScript))
} catch {
    throw "Invalid CodexConfig or BridgeScript path. Pass normal filesystem paths explicitly. Details: $($_.Exception.Message)"
}

if ($ListenAddress -notin @('127.0.0.1', 'localhost')) {
    throw 'For safety, ListenAddress must be 127.0.0.1 or localhost.'
}
if ($ProviderId -notmatch '^[A-Za-z0-9_-]+$') {
    throw 'ProviderId may contain only letters, digits, underscores, and hyphens.'
}

try {
    $UpstreamUri = [Uri]$UpstreamUrl
} catch {
    throw "Invalid UpstreamUrl: $UpstreamUrl"
}
if ($UpstreamUri.Scheme -ne 'http' -or -not $UpstreamUri.IsLoopback) {
    throw 'For safety, UpstreamUrl must be a local http:// URL.'
}

$StateDirectory = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'CodexProviderBridge'
} else {
    Join-Path $env:TEMP 'CodexProviderBridge'
}
$StateFile = Join-Path $StateDirectory 'bridge-state.json'
$StdoutLog = Join-Path $StateDirectory 'bridge-stdout.log'
$StderrLog = Join-Path $StateDirectory 'bridge-stderr.log'

function Test-TcpEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 600
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-PortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            $Port
        )
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Find-AvailablePort {
    param(
        [Parameter(Mandatory = $true)][int]$StartPort,
        [int]$Attempts = 200
    )

    for ($candidate = $StartPort; $candidate -lt ($StartPort + $Attempts); $candidate++) {
        if ($candidate -gt 65535) {
            break
        }
        if (Test-PortAvailable -Port $candidate) {
            return $candidate
        }
    }
    throw "No free local TCP port found from $StartPort to $($StartPort + $Attempts - 1)."
}

function Read-BridgeState {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "Ignoring unreadable state file: $StateFile"
        return $null
    }
}

function Get-ManagedBridgeProcess {
    param($State)

    if ($null -eq $State -or $null -eq $State.pid) {
        return $null
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($State.pid)" -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $null
    }
    $expectedPath = [string]$State.bridge_script
    if ([string]::IsNullOrWhiteSpace($process.CommandLine) -or
        $process.CommandLine.IndexOf($expectedPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $null
    }
    return $process
}

function Resolve-PythonCommand {
    # Launch the real interpreter, not py.exe. The Windows launcher may create
    # a child python.exe process, which makes the saved PID point at the wrong
    # process and can leave the listener alive after `stop`.
    $candidates = @()
    foreach ($name in @('python.exe', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command -and $candidates -notcontains $command.Source) {
            $candidates += $command.Source
        }
    }
    $py = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($null -ne $py) {
        try {
            $launchedPath = (& $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($launchedPath)) {
                $launchedPath = [IO.Path]::GetFullPath($launchedPath.Trim())
                if ($candidates -notcontains $launchedPath) {
                    # Prefer the interpreter selected by the Python launcher
                    # over Windows Store aliases named python.exe.
                    $candidates = @($launchedPath) + @($candidates)
                }
            }
        } catch { }
    }
    foreach ($candidate in $candidates) {
        try {
            & $candidate -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 2)' 2>$null
            if ($LASTEXITCODE -eq 0) {
                $versionText = (& $candidate -c 'import platform; print(platform.python_version())' 2>$null | Select-Object -First 1)
                return [pscustomobject]@{
                    FilePath = $candidate
                    PrefixArguments = @()
                    Version = $versionText
                }
            }
        } catch { }
    }
    if ($candidates.Count -gt 0) {
        throw 'Python was found, but Python 3.10 or newer is required.'
    }
    throw 'Python was not found. Install Python 3.10+ and ensure py.exe or python.exe is on PATH.'
}

function Escape-TomlString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-TopLevelTomlString {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*"((?:\\.|[^"\\])*)"\s*(?:#.*)?$'
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        if ($line -match '^\s*\[') {
            break
        }
        if ($line -match $pattern) {
            return $Matches[1].Replace('\"', '"').Replace('\\', '\')
        }
    }
    return $null
}

function Get-ProviderTomlString {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $escapedId = [regex]::Escape($Id)
    $sectionPattern = '^\s*\[model_providers\.(?:' + $escapedId + '|"' + $escapedId + '")\]\s*$'
    $valuePattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(?:"((?:\\.|[^"\\])*)"|(true|false))\s*(?:#.*)?$'
    $insideSection = $false
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        if ($line -match '^\s*\[') {
            $insideSection = ($line -match $sectionPattern)
            continue
        }
        if ($insideSection -and $line -match $valuePattern) {
            if ($null -ne $Matches[1]) {
                return $Matches[1].Replace('\"', '"').Replace('\\', '\')
            }
            return $Matches[2]
        }
    }
    return $null
}

function Get-ProviderBaseUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Id
    )
    return Get-ProviderTomlString -Text $Text -Id $Id -Key 'base_url'
}

function Get-AutomaticModelOverride {
    # In auto mode, reuse an already-configured official-looking model so the
    # common workflow does not require repeating -Model on every invocation.
    # Third-party names are intentionally excluded; use -Model explicitly for
    # a non-standard official model name.
    if ($Command -ne 'auto' -or -not (Test-Path -LiteralPath $CodexConfig -PathType Leaf)) {
        return $null
    }
    $text = [IO.File]::ReadAllText($CodexConfig)
    $configuredModel = Get-TopLevelTomlString -Text $text -Key 'model'
    if (-not [string]::IsNullOrWhiteSpace($configuredModel) -and
        $configuredModel -match '(?i)^(gpt-|o[0-9]|codex)') {
        return $configuredModel
    }
    return $null
}

function Test-CodexConfigNeedsBridge {
    if (-not (Test-Path -LiteralPath $CodexConfig -PathType Leaf)) {
        return $false
    }

    $text = [IO.File]::ReadAllText($CodexConfig)
    $activeProvider = Get-TopLevelTomlString -Text $text -Key 'model_provider'
    if ($activeProvider -eq $OfficialProviderId) {
        return $true
    }
    if ($activeProvider -ne $ProviderId) {
        return $false
    }

    $baseUrl = Get-ProviderBaseUrl -Text $text -Id $ProviderId
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return $false
    }
    try {
        $uri = [Uri]$baseUrl
    } catch {
        return $false
    }
    if ($uri.Scheme -ne 'http' -or -not $uri.IsLoopback) {
        return $false
    }

    $state = Read-BridgeState
    $knownPorts = @($BridgePort)
    if ($null -ne $state -and $null -ne $state.port) {
        $knownPorts += [int]$state.port
    }
    if ($uri.AbsolutePath.TrimEnd('/') -ne '/v1') {
        return $false
    }
    if ($uri.Port -in $knownPorts) {
        return $true
    }

    # Stop removes the runtime state file, but leaves the Codex bridge profile
    # in place. Recognize that profile by its manager-written provider marker so
    # a later `auto` can start it again even when the previous port was 15723+
    # rather than the default 15722.
    $providerName = Get-ProviderTomlString -Text $text -Id $ProviderId -Key 'name'
    $supportsWebsockets = Get-ProviderTomlString -Text $text -Id $ProviderId -Key 'supports_websockets'
    $bridgeMarker = ($providerName -eq $ProviderName) -or
        ($providerName -match '(?i)bridge') -or
        ($supportsWebsockets -eq 'false')
    return ($bridgeMarker -and $uri.Port -ne $UpstreamUri.Port)
}

function Get-FirstSectionIndex {
    param([Parameter(Mandatory = $true)]$Lines)
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            return $index
        }
    }
    return $Lines.Count
}

function Set-TopLevelTomlKey {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $sectionStart = Get-FirstSectionIndex -Lines $Lines
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($index = 0; $index -lt $sectionStart; $index++) {
        if ($Lines[$index] -match $keyPattern) {
            $Lines[$index] = "$Key = $Value"
            return
        }
    }
    $Lines.Insert($sectionStart, "$Key = $Value") | Out-Null
}

function Find-TomlSection {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$HeaderPattern
    )

    $start = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $HeaderPattern) {
            $start = $index
            break
        }
    }
    if ($start -lt 0) {
        return $null
    }

    $end = $Lines.Count
    for ($index = $start + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $end = $index
            break
        }
    }
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Set-SectionTomlKey {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$HeaderPattern,
        [Parameter(Mandatory = $true)][string]$NewHeader,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $section = Find-TomlSection -Lines $Lines -HeaderPattern $HeaderPattern
    if ($null -eq $section) {
        if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
            $Lines.Add('') | Out-Null
        }
        $Lines.Add($NewHeader) | Out-Null
        $Lines.Add("$Key = $Value") | Out-Null
        return
    }

    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($index = $section.Start + 1; $index -lt $section.End; $index++) {
        if ($Lines[$index] -match $keyPattern) {
            $Lines[$index] = "$Key = $Value"
            return
        }
    }
    $Lines.Insert($section.End, "$Key = $Value") | Out-Null
}

function Update-CodexConfig {
    param([Parameter(Mandatory = $true)][int]$Port)

    $configDirectory = Split-Path -Parent $CodexConfig
    if (-not (Test-Path -LiteralPath $configDirectory)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }

    $exists = Test-Path -LiteralPath $CodexConfig
    $original = if ($exists) {
        [IO.File]::ReadAllText($CodexConfig)
    } else {
        ''
    }
    $newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $splitLines = if ($original.Length -eq 0) { @() } else { [regex]::Split($original, '\r?\n') }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $splitLines) {
        $lines.Add([string]$line) | Out-Null
    }

    Set-TopLevelTomlKey -Lines $lines -Key 'model_provider' -Value (Escape-TomlString $ProviderId)
    Set-TopLevelTomlKey -Lines $lines -Key 'disable_response_storage' -Value 'true'
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        Set-TopLevelTomlKey -Lines $lines -Key 'model' -Value (Escape-TomlString $Model)
    }

    $escapedProvider = [regex]::Escape($ProviderId)
    $providerPattern = '^\s*\[model_providers\.(?:' + $escapedProvider + '|"' + $escapedProvider + '")\]\s*$'
    $providerHeader = "[model_providers.$ProviderId]"
    $bridgeBaseUrl = "http://$ListenAddress`:$Port/v1"

    Set-SectionTomlKey -Lines $lines -HeaderPattern $providerPattern -NewHeader $providerHeader -Key 'name' -Value (Escape-TomlString $ProviderName)
    Set-SectionTomlKey -Lines $lines -HeaderPattern $providerPattern -NewHeader $providerHeader -Key 'base_url' -Value (Escape-TomlString $bridgeBaseUrl)
    Set-SectionTomlKey -Lines $lines -HeaderPattern $providerPattern -NewHeader $providerHeader -Key 'wire_api' -Value '"responses"'
    Set-SectionTomlKey -Lines $lines -HeaderPattern $providerPattern -NewHeader $providerHeader -Key 'requires_openai_auth' -Value 'true'
    Set-SectionTomlKey -Lines $lines -HeaderPattern $providerPattern -NewHeader $providerHeader -Key 'supports_websockets' -Value 'false'

    $featuresPattern = '^\s*\[features\]\s*$'
    Set-SectionTomlKey -Lines $lines -HeaderPattern $featuresPattern -NewHeader '[features]' -Key 'enable_request_compression' -Value 'false'

    $updated = [string]::Join($newline, $lines.ToArray())
    if ($updated -ceq $original) {
        Write-Host "Codex config is already correct: $CodexConfig"
        return $null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backup = $null
    if ($exists) {
        $backup = [IO.Path]::GetFullPath("$CodexConfig.bridge-backup-$timestamp")
    }

    $temporary = [IO.Path]::GetFullPath(
        (Join-Path $configDirectory ("config.toml.bridge-tmp-" + [Guid]::NewGuid().ToString('N')))
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temporary, $updated, $utf8NoBom)
        if ($exists) {
            try {
                # Give File.Replace a real, fully resolved backup path. Passing
                # $null here is accepted by some .NET versions but has caused
                # the Windows PowerShell 5.1 "path is not of a legal form"
                # error in this workflow.
                [IO.File]::Replace($temporary, $CodexConfig, $backup, $true)
            } catch {
                # Keep the already-written temporary file and fall back to a
                # safe copy only when the atomic replace itself is unavailable.
                # The original config is copied to the timestamped backup
                # before it is overwritten.
                $replaceError = $_.Exception
                if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
                    throw $replaceError
                }
                Copy-Item -LiteralPath $CodexConfig -Destination $backup -Force
                [IO.File]::Copy($temporary, $CodexConfig, $true)
                Remove-Item -LiteralPath $temporary -Force
                Write-Warning "Atomic config replacement was unavailable; used a backup-protected copy instead. Details: $($replaceError.Message)"
            }
        } else {
            [IO.File]::Move($temporary, $CodexConfig)
        }
    } catch {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        throw
    }

    Write-Host "Updated Codex config: $CodexConfig"
    if ($null -ne $backup) {
        Write-Host "Backup created: $backup"
    }
    return $backup
}

function Start-Bridge {
    if (-not (Test-Path -LiteralPath $BridgeScript -PathType Leaf)) {
        throw "Bridge script not found: $BridgeScript"
    }
    $resolvedBridgeScript = (Resolve-Path -LiteralPath $BridgeScript).Path

    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $automaticModel = Get-AutomaticModelOverride
        if (-not [string]::IsNullOrWhiteSpace($automaticModel)) {
            $Model = $automaticModel
            Write-Host "Using configured official model for replay: $Model"
        }
    }

    $existingState = Read-BridgeState
    $existingProcess = Get-ManagedBridgeProcess -State $existingState
    $existingModel = ''
    if ($null -ne $existingState -and
        $null -ne $existingState.PSObject.Properties['model_override']) {
        $existingModel = [string]$existingState.model_override
    }
    $requestedModel = if ([string]::IsNullOrWhiteSpace($Model)) {
        $existingModel
    } else {
        $Model.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($requestedModel)) {
        $Model = $requestedModel
    }

    if ($null -ne $existingProcess -and
        (Test-TcpEndpoint -Address $ListenAddress -Port ([int]$existingState.port))) {
        if ($RunForeground) {
            Write-Host 'Restarting the existing managed bridge in foreground mode.'
            Stop-Bridge -NoConfigWarning
            $existingState = $null
            $existingProcess = $null
        } elseif ($existingModel -ne $requestedModel) {
            Write-Host "Bridge model override changed ($existingModel -> $requestedModel); restarting it."
            Stop-Bridge -NoConfigWarning
            $existingState = $null
            $existingProcess = $null
        } else {
            Write-Host "Bridge is already running on http://$ListenAddress`:$($existingState.port)"
            Update-CodexConfig -Port ([int]$existingState.port) | Out-Null
            return
        }
    }

    if ($null -ne $existingState -and $null -eq $existingProcess) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }

    $selectedPort = $BridgePort
    if (-not (Test-PortAvailable -Port $selectedPort)) {
        if ($FixedPort) {
            throw "Port $selectedPort is already in use. Stop that process or choose another -BridgePort."
        }
        $selectedPort = Find-AvailablePort -StartPort ($BridgePort + 1)
        Write-Warning "Port $BridgePort is occupied; using $selectedPort instead."
    }

    $python = Resolve-PythonCommand
    $quotedScript = '"' + $resolvedBridgeScript.Replace('"', '\"') + '"'
    $arguments = @($python.PrefixArguments) + @(
        '-u',
        $quotedScript,
        '--listen',
        "$ListenAddress`:$selectedPort",
        '--upstream',
        $UpstreamUrl
    )
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $arguments += @('--model-override', $Model)
    }

    $startParameters = @{
        FilePath = $python.FilePath
        ArgumentList = $arguments
        WorkingDirectory = (Split-Path -Parent $resolvedBridgeScript)
        PassThru = $true
    }
    if ($RunForeground) {
        $startParameters['NoNewWindow'] = $true
    } else {
        $startParameters['RedirectStandardOutput'] = $StdoutLog
        $startParameters['RedirectStandardError'] = $StderrLog
        $startParameters['WindowStyle'] = 'Hidden'
    }
    $process = Start-Process @startParameters

    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($process.HasExited) {
            break
        }
        if (Test-TcpEndpoint -Address $ListenAddress -Port $selectedPort -TimeoutMs 150) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        $errorTail = if (Test-Path -LiteralPath $StderrLog) {
            (Get-Content -LiteralPath $StderrLog -Tail 8 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        } else {
            ''
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw "Bridge failed to start.$([Environment]::NewLine)$errorTail"
    }

    $state = [ordered]@{
        pid = $process.Id
        port = $selectedPort
        listen_address = $ListenAddress
        upstream_url = $UpstreamUrl
        bridge_script = $resolvedBridgeScript
        model_override = $Model
        started_at = (Get-Date).ToString('o')
        stdout_log = $StdoutLog
        stderr_log = $StderrLog
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8

    Update-CodexConfig -Port $selectedPort | Out-Null
    if (-not (Test-TcpEndpoint -Address $UpstreamUri.Host -Port $UpstreamUri.Port)) {
        Write-Warning "Bridge is running, but CC Switch is not reachable at $UpstreamUrl. Start its route service before sending requests."
    }
    Write-Host "Bridge started: http://$ListenAddress`:$selectedPort"
    Write-Host "Forwarding to: $UpstreamUrl"
    if ($RunForeground) {
        Write-Host 'Foreground mode is active. Press Ctrl+C, close this window, or terminate the VS Code task to stop the bridge.'
        Write-Host 'Reload Codex separately if it has not read the updated config yet.'
        try {
            $process.WaitForExit()
        } finally {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            $currentState = Read-BridgeState
            if ($null -ne $currentState -and [int]$currentState.pid -eq $process.Id) {
                Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
            }
        }
        return
    }
    Write-Host 'Reload the VS Code window or restart Codex so it reads the updated config.'
}

function Repair-BridgeConfig {
    $state = Read-BridgeState
    $process = Get-ManagedBridgeProcess -State $state
    if ([string]::IsNullOrWhiteSpace($Model) -and
        $null -ne $state -and
        $null -ne $state.PSObject.Properties['model_override'] -and
        -not [string]::IsNullOrWhiteSpace([string]$state.model_override)) {
        $Model = [string]$state.model_override
    }
    $port = $BridgePort
    if ($null -ne $process -and
        $null -ne $state.port -and
        (Test-TcpEndpoint -Address $ListenAddress -Port ([int]$state.port))) {
        $port = [int]$state.port
    } elseif (-not (Test-TcpEndpoint -Address $ListenAddress -Port $port)) {
        Write-Warning "No managed bridge is currently listening on port $port. The config will be repaired, but requests will fail until the bridge starts."
    }
    Update-CodexConfig -Port $port | Out-Null
    Write-Host "Repair complete. Codex provider '$ProviderId' points to http://$ListenAddress`:$port/v1"
}

function Show-BridgeStatus {
    $state = Read-BridgeState
    $process = Get-ManagedBridgeProcess -State $state
    $port = if ($null -ne $state -and $null -ne $state.port) { [int]$state.port } else { $BridgePort }
    $bridgeListening = Test-TcpEndpoint -Address $ListenAddress -Port $port
    $upstreamListening = Test-TcpEndpoint -Address $UpstreamUri.Host -Port $UpstreamUri.Port

    [pscustomobject]@{
        ManagedProcess = ($null -ne $process)
        ProcessId = if ($null -ne $process) { $process.ProcessId } else { $null }
        BridgeUrl = "http://$ListenAddress`:$port"
        BridgeListening = $bridgeListening
        UpstreamUrl = $UpstreamUrl
        ModelOverride = if ($null -ne $state -and
            $null -ne $state.PSObject.Properties['model_override']) {
            [string]$state.model_override
        } else {
            $null
        }
        UpstreamListening = $upstreamListening
        CodexConfig = $CodexConfig
        StateFile = $StateFile
    } | Format-List
}

function Show-BridgeDoctor {
    Write-Host 'Codex Cross-Provider Bridge portability check'
    Write-Host "ManagerScript: $($MyInvocation.ScriptName)"
    Write-Host "BridgeScript: $BridgeScript"
    Write-Host "BridgeScriptExists: $(Test-Path -LiteralPath $BridgeScript -PathType Leaf)"
    try {
        $python = Resolve-PythonCommand
        Write-Host "Python: $($python.FilePath)"
        Write-Host "PythonVersion: $($python.Version)"
    } catch {
        Write-Host "Python: ERROR - $($_.Exception.Message)"
    }
    Write-Host "CodexConfig: $CodexConfig"
    Write-Host "CodexConfigExists: $(Test-Path -LiteralPath $CodexConfig -PathType Leaf)"
    $configMode = if (Test-CodexConfigNeedsBridge) { 'official-or-bridge' } else { 'third-party-or-other' }
    Write-Host "DetectedConfigMode: $configMode"
    Write-Host "PreferredBridgePortAvailable: $(Test-PortAvailable -Port $BridgePort)"
    Write-Host "UpstreamUrl: $UpstreamUrl"
    Write-Host "UpstreamListening: $(Test-TcpEndpoint -Address $UpstreamUri.Host -Port $UpstreamUri.Port)"
    Show-BridgeStatus
}

function Stop-Bridge {
    param([switch]$NoConfigWarning)

    $state = Read-BridgeState
    $process = Get-ManagedBridgeProcess -State $state
    if ($null -eq $process) {
        Write-Host 'No bridge process managed by this script is running.'
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        return
    }

    Stop-Process -Id $process.ProcessId -Force
    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped bridge process $($process.ProcessId)."
    if (-not $NoConfigWarning) {
        Write-Warning 'Codex config still points to the bridge. Run start before sending another request.'
    }
}

function Invoke-AutomaticBridge {
    if (Test-CodexConfigNeedsBridge) {
        Write-Host 'Official/bridge Codex configuration detected; ensuring the bridge is running.'
        Start-Bridge
        return
    }

    Write-Host 'Third-party or non-bridge Codex configuration detected; the bridge will stay stopped.'
    $state = Read-BridgeState
    $process = Get-ManagedBridgeProcess -State $state
    if ($null -ne $process) {
        Stop-Bridge -NoConfigWarning
    } elseif (Test-Path -LiteralPath $StateFile) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
}

switch ($Command.ToLowerInvariant()) {
    'auto'   { Invoke-AutomaticBridge }
    'start'  { Start-Bridge }
    'repair' { Repair-BridgeConfig }
    'status' { Show-BridgeStatus }
    'doctor' { Show-BridgeDoctor }
    'stop'   { Stop-Bridge }
}
