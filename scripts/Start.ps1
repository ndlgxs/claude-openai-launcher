#Requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('m')]
    [string] $Model,
    [string] $Project,
    [switch] $ParseOnly,
    # Bind -p explicitly so it is not mistaken for a PowerShell common parameter.
    [Alias('p')]
    [switch] $Print,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ClaudeArguments
)

$ErrorActionPreference = 'Stop'
$originalLocation = Get-Location
$exitCode = 1

function Get-VerifiedProxyProcess {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return $null }
    $candidate = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace($candidate.ExecutablePath)) { return $null }
    $actualPath = [System.IO.Path]::GetFullPath([string] $candidate.ExecutablePath)
    $expectedPath = [System.IO.Path]::GetFullPath($proxyBinary)
    if ([string]::Equals($actualPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $candidate
    }
    return $null
}

function Show-LoginHint {
    Write-Host 'No available OpenAI model was found. Complete the browser login first:'
    Write-Host ("  & '{0}'" -f $loginPath)
}

function Get-ClaudeLaunchOptions {
    param([string] $ExplicitModel, [string[]] $Arguments, [switch] $PrintRequested)
    $forwarded = New-Object 'System.Collections.Generic.List[string]'
    $argumentModel = ''
    $isPrintMode = $PrintRequested.IsPresent
    if ($PrintRequested) { $forwarded.Add('-p') }
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string] $Arguments[$index]
        if ($argument -eq '--') {
            for (; $index -lt $Arguments.Count; $index++) { $forwarded.Add([string] $Arguments[$index]) }
            break
        }
        if ($argument -eq '--model' -or $argument -eq '-m') {
            if ($index + 1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace($Arguments[$index + 1]) -or $Arguments[$index + 1].StartsWith('-')) {
                throw ("{0} requires a model ID or alias." -f $argument)
            }
            $index++
            $argumentModel = [string] $Arguments[$index]
            continue
        }
        if ($argument -match '^(?:--model|-m)=(.*)$') {
            if ([string]::IsNullOrWhiteSpace($Matches[1])) { throw '--model requires a model ID or alias.' }
            $argumentModel = $Matches[1]
            continue
        }
        if ($argument -eq '-p' -or $argument -eq '--print' -or $argument -match '^(?:--print|-p)=') {
            $isPrintMode = $true
        }
        $forwarded.Add($argument)
    }
    # An explicit launcher -Model takes precedence. Remove every native selector
    # so Claude receives one --model argument, followed by the remaining options.
    $requestedModel = if ([string]::IsNullOrWhiteSpace($ExplicitModel)) { $argumentModel } else { $ExplicitModel }
    [pscustomobject]@{
        RequestedModel = $requestedModel
        Arguments = $forwarded.ToArray()
        IsPrintMode = $isPrintMode
    }
}

function Get-OpenAITextModels {
    param([string[]] $ModelIds)
    $textModels = @($ModelIds | Where-Object {
        $_ -match '^gpt-' -and $_ -notmatch '(?i)image|auto[-_]review'
    } | Sort-Object -Unique)
    $preferredOrder = @('gpt-6.1-sol', 'gpt-6-astra', 'gpt-6.1-terra', 'gpt-6-luna', 'gpt-6-sol')
    foreach ($modelId in $preferredOrder) {
        if ($textModels -contains $modelId) { $modelId }
    }
    $textModels | Where-Object { $preferredOrder -notcontains $_ }
}

function Resolve-OpenAIModelName {
    param([string] $RequestedModel, [string[]] $AvailableModels)
    $modelName = $RequestedModel.Trim()
    if ($modelName -notmatch '^(?<base>[A-Za-z0-9._/-]+)(?:\((?<effort>minimal|low|medium|high|xhigh|max|auto|none|[0-9]*)\))?$') {
        throw 'Use a GPT model ID or astra/sol/terra/luna, optionally followed by (high), (xhigh), or another supported reasoning level.'
    }
    $baseModel = $Matches['base']
    $effort = $Matches['effort']
    $aliases = @{
        astra = 'gpt-6-astra'
        sol = 'gpt-6.1-sol'
        terra = 'gpt-6.1-terra'
        luna = 'gpt-6-luna'
    }
    if ($aliases.ContainsKey($baseModel)) { $baseModel = $aliases[$baseModel] }
    $canonicalModel = $AvailableModels | Where-Object { $_ -eq $baseModel } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($canonicalModel)) {
        throw ("Model '{0}' is not in this proxy's available text model list." -f $baseModel)
    }
    if (-not [string]::IsNullOrEmpty($effort)) {
        return ('{0}({1})' -f $canonicalModel, $effort.ToLowerInvariant())
    }
    return $canonicalModel
}

function Select-OpenAIModel {
    param([string] $RequestedModel, [string[]] $AvailableModels, [string] $PreferredModel, [switch] $Interactive)
    if ($AvailableModels.Count -eq 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($RequestedModel)) {
        return Resolve-OpenAIModelName -RequestedModel $RequestedModel -AvailableModels $AvailableModels
    }
    $defaultModel = if ($AvailableModels -contains $PreferredModel) { $PreferredModel } else { $AvailableModels[0] }
    if (-not $Interactive) { return $defaultModel }
    Write-Host 'Available OpenAI text models:'
    $defaultNumber = 1
    for ($index = 0; $index -lt $AvailableModels.Count; $index++) {
        $marker = ''
        if ($AvailableModels[$index] -eq $defaultModel) {
            $defaultNumber = $index + 1
            $marker = ' (default)'
        }
        Write-Host ('  {0}. {1}{2}' -f ($index + 1), $AvailableModels[$index], $marker)
    }
    while ($true) {
        $choice = Read-Host ("Choose number, astra/sol/terra/luna, or full model ID [{0}]" -f $defaultNumber)
        if ([string]::IsNullOrWhiteSpace($choice)) { return $defaultModel }
        $choiceNumber = 0
        if ([int]::TryParse($choice.Trim(), [ref] $choiceNumber) -and $choiceNumber -ge 1 -and $choiceNumber -le $AvailableModels.Count) {
            return $AvailableModels[$choiceNumber - 1]
        }
        try {
            return Resolve-OpenAIModelName -RequestedModel $choice -AvailableModels $AvailableModels
        }
        catch {
            Write-Host ([string] $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

try {
    $launchOptions = Get-ClaudeLaunchOptions -ExplicitModel $Model -Arguments $ClaudeArguments -PrintRequested:$Print
    $ClaudeArguments = $launchOptions.Arguments
    # PowerShell binds --verbose to its own common parameter before our parser.
    # Forward that switch so Claude's stream-json mode receives it too.
    if ($PSBoundParameters.ContainsKey('Verbose') -and $PSBoundParameters['Verbose']) {
        $ClaudeArguments = @($ClaudeArguments) + '--verbose'
    }
    if (-not $launchOptions.IsPrintMode -and [string]::IsNullOrWhiteSpace($Project) -and @($ClaudeArguments).Count -gt 0 -and
        (Test-Path -LiteralPath $ClaudeArguments[0] -PathType Container)) {
        $Project = $ClaudeArguments[0]
        $ClaudeArguments = @($ClaudeArguments | Select-Object -Skip 1)
    }
    if ([string]::IsNullOrWhiteSpace($Project)) { $Project = $originalLocation.Path }
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        throw 'The requested project directory does not exist.'
    }
    $projectItem = Get-Item -LiteralPath $Project
    if ($projectItem.PSProvider.Name -ne 'FileSystem') { throw 'Project must be a filesystem directory.' }
    $Project = $projectItem.FullName
    if ($ParseOnly) {
        [pscustomobject]@{
            RequestedModel = $launchOptions.RequestedModel
            Arguments = @($ClaudeArguments)
            IsPrintMode = $launchOptions.IsPrintMode
            IsInteractive = -not $launchOptions.IsPrintMode
            Project = $Project
        } | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    if (-not $IsWindows) { throw 'This launcher supports Windows and PowerShell 7.' }
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $paths = Get-LauncherPaths
    $installRoot = $paths.DataRoot
    $proxyBinary = $paths.BinaryPath
    $configPath = $paths.ConfigPath
    $runtimePath = $paths.RuntimePath
    $profilesPath = $paths.ProfilesPath
    $sessionSettingsPath = $paths.SessionSettingsPath
    $pidPath = $paths.PidPath
    $logDirectory = $paths.LogsRoot
    $loginPath = Join-Path $paths.ScriptsRoot 'Login.ps1'
    $runtime = Read-LauncherRuntime -Paths $paths -Required
    foreach ($requiredFile in @($proxyBinary, $configPath, $runtimePath, $profilesPath, $sessionSettingsPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw ('A required installation or model profile is missing. Run setup.cmd, then login.cmd. Missing file: {0}' -f $requiredFile)
        }
    }
    $expectedBinaryHash = [string] $runtime.proxyBinarySha256
    if ([string]::IsNullOrWhiteSpace($expectedBinaryHash) -or
        (Get-FileHash -LiteralPath $proxyBinary -Algorithm SHA256).Hash -ine $expectedBinaryHash) {
        throw 'The proxy executable no longer matches the verified installation. Rerun setup.cmd before starting it.'
    }
    $profileDocument = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
    $modelProfiles = $profileDocument.profiles
    $configuredModelIds = @($modelProfiles.PSObject.Properties.Name)
    # Context/output environment values apply to the entire Claude process.
    # Only offer this verified set, whose active limits match, so /model cannot
    # silently keep the previous model's incompatible window.
    $configuredLimits = @($modelProfiles.PSObject.Properties | ForEach-Object {
        '{0}/{1}/{2}' -f $_.Value.contextWindow, $_.Value.maxOutputTokens, $_.Value.autoCompactWindow
    } | Sort-Object -Unique)
    if ($configuredLimits.Count -ne 1) {
        throw 'Configured models have different active limits. Create separate launch profiles before enabling cross-model switching.'
    }
    $proxyKey = [string] $runtime.proxyKey
    $port = [int] $runtime.port
    $claudePath = Resolve-ClaudeExecutable -Runtime $runtime -Paths $paths
    if ($runtime.claudePath -ne $claudePath) {
        $runtime.claudePath = $claudePath
        Write-LauncherRuntime -Runtime $runtime -Paths $paths
    }
    $preferredModel = [string] $runtime.preferredModel
    if ([string]::IsNullOrWhiteSpace($proxyKey) -or $port -lt 1 -or $port -gt 65535) {
        throw 'The local runtime configuration is incomplete.'
    }
    if ([string]::IsNullOrWhiteSpace($claudePath) -or -not (Test-Path -LiteralPath $claudePath -PathType Leaf)) {
        throw 'The configured Claude Code executable is unavailable. Its path may have changed after a Claude update.'
    }

    $proxyProcess = $null
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $savedProcessId = 0
        if ([int]::TryParse((Get-Content -LiteralPath $pidPath -Raw).Trim(), [ref] $savedProcessId)) {
            $proxyProcess = Get-VerifiedProxyProcess -ProcessId $savedProcessId
        }
    }
    if ($null -eq $proxyProcess) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            $ownerIds = @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)
            if ($ownerIds.Count -ne 1) {
                throw ("Port {0} is occupied by another process. The proxy was not started." -f $port)
            }
            $proxyProcess = Get-VerifiedProxyProcess -ProcessId ([int] $ownerIds[0])
            if ($null -eq $proxyProcess) {
                throw ("Port {0} is occupied by another process. The proxy was not started." -f $port)
            }
        }
    }
    if ($null -eq $proxyProcess) {
        $null = New-Item -ItemType Directory -Path $logDirectory -Force
        $logSuffix = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $stdoutPath = Join-Path $logDirectory ("proxy-{0}.out.log" -f $logSuffix)
        $stderrPath = Join-Path $logDirectory ("proxy-{0}.err.log" -f $logSuffix)
        $proxyProcess = Start-Process -FilePath $proxyBinary `
            -ArgumentList @('--config', ('"{0}"' -f $configPath), '--local-model') `
            -WorkingDirectory $installRoot -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    }
    $verifiedProcessId = if ($proxyProcess -is [System.Diagnostics.Process]) { $proxyProcess.Id } else { $proxyProcess.ProcessId }
    Set-Content -LiteralPath $pidPath -Value $verifiedProcessId -Encoding Ascii

    Add-Type -AssemblyName System.Net.Http
    $httpHandler = [System.Net.Http.HttpClientHandler]::new()
    $httpHandler.UseProxy = $false
    $httpClient = [System.Net.Http.HttpClient]::new($httpHandler)
    $httpClient.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $proxyKey)
    $models = $null
    $waitTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($waitTimer.ElapsedMilliseconds -lt 15000 -and $null -eq $models) {
            $remainingMilliseconds = 15000 - [int] $waitTimer.ElapsedMilliseconds
            if ($remainingMilliseconds -le 0) { break }
            $cancelRequest = [System.Threading.CancellationTokenSource]::new()
            $cancelRequest.CancelAfter([Math]::Min(1000, $remainingMilliseconds))
            $response = $null
            try {
                $requestTask = $httpClient.GetAsync(("http://127.0.0.1:{0}/v1/models" -f $port), $cancelRequest.Token)
                $response = $requestTask.GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode) {
                    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $models = $json | ConvertFrom-Json
                }
            }
            catch {
                # The proxy may still be starting; never print credential-bearing requests.
            }
            finally {
                if ($null -ne $response) { $response.Dispose() }
                $cancelRequest.Dispose()
            }
            $remainingMilliseconds = 15000 - [int] $waitTimer.ElapsedMilliseconds
            if ($null -eq $models -and $remainingMilliseconds -gt 0) {
                Start-Sleep -Milliseconds ([Math]::Min(150, $remainingMilliseconds))
            }
        }
    }
    finally {
        $waitTimer.Stop()
        $httpClient.Dispose()
        $httpHandler.Dispose()
    }
    if ($null -eq $models) {
        Show-LoginHint
        throw ("The local proxy did not return a model list within 15 seconds. Check logs in {0}" -f $logDirectory)
    }
    $modelIds = @($models.data | ForEach-Object { [string] $_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $textModels = @(Get-OpenAITextModels -ModelIds $modelIds | Where-Object { $configuredModelIds -contains $_ })
    $interactiveSelection = $false
    if (-not $launchOptions.IsPrintMode -and [Environment]::UserInteractive) {
        try { $interactiveSelection = -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected }
        catch { $interactiveSelection = $false }
    }
    $selectedModel = Select-OpenAIModel -RequestedModel $launchOptions.RequestedModel `
        -AvailableModels $textModels -PreferredModel $preferredModel -Interactive:$interactiveSelection
    if ([string]::IsNullOrWhiteSpace($selectedModel)) {
        Show-LoginHint
        throw 'The proxy has no available GPT model for this login.'
    }
    $profileModelId = $selectedModel -replace '\([^)]*\)$', ''
    $selectedProfile = $modelProfiles.PSObject.Properties[$profileModelId].Value
    if ($null -eq $selectedProfile -or [int]$selectedProfile.contextWindow -le 0) {
        throw 'The selected model has no verified context profile.'
    }
    if ($selectedModel -match '\(([^)]*)\)$' -and $selectedProfile.reasoningLevels -notcontains $Matches[1]) {
        throw ('This model profile does not advertise reasoning level: {0}' -f $Matches[1])
    }

    # Change only this launcher process and its child; restore inherited values afterwards.
    $childEnvironment = @{
        ANTHROPIC_BASE_URL = ("http://127.0.0.1:{0}" -f $port)
        ANTHROPIC_AUTH_TOKEN = $proxyKey
        ANTHROPIC_API_KEY = $null
        CLAUDE_CODE_OAUTH_TOKEN = $null
        ANTHROPIC_MODEL = $selectedModel
        ANTHROPIC_CUSTOM_MODEL_OPTION = $selectedModel
        ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = [string] $selectedProfile.displayName
        ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION = 'OpenAI through the local proxy; verified account context profile'
        ANTHROPIC_DEFAULT_SONNET_MODEL = $selectedModel
        ANTHROPIC_DEFAULT_OPUS_MODEL = $selectedModel
        ANTHROPIC_DEFAULT_HAIKU_MODEL = $selectedModel
        ANTHROPIC_DEFAULT_FABLE_MODEL = $selectedModel
        CLAUDE_CODE_SUBAGENT_MODEL = $selectedModel
        CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '0'
        CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string] $selectedProfile.contextWindow
        CLAUDE_CODE_MAX_OUTPUT_TOKENS = [string] $selectedProfile.maxOutputTokens
        CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string] $selectedProfile.autoCompactWindow
        DISABLE_AUTO_COMPACT = $null
        CLAUDE_CODE_DISABLE_1M_CONTEXT = $null
        CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT = $null
        DISABLE_COMPACT = $null
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = $null
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
        DISABLE_TELEMETRY = '1'
        DISABLE_ERROR_REPORTING = '1'
        DISABLE_AUTOUPDATER = '1'
    }
    $originalEnvironment = @{}
    try {
        foreach ($name in $childEnvironment.Keys) {
            $originalEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            [System.Environment]::SetEnvironmentVariable($name, $childEnvironment[$name], 'Process')
        }
        Write-Host ("Starting Claude Code with {0} through the local OpenAI proxy." -f $selectedModel)
        Write-Host ('Context: {0} tokens; auto-compact: {1}; output budget: {2}.' -f $selectedProfile.contextWindow, $selectedProfile.autoCompactWindow, $selectedProfile.maxOutputTokens)
        Set-Location -LiteralPath $Project
        & $claudePath --settings $sessionSettingsPath --model $selectedModel @ClaudeArguments
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int] $LASTEXITCODE }
    }
    finally {
        foreach ($name in $originalEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
        }
    }
}
catch {
    Write-Host ([string] $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
}
finally {
    Set-Location -LiteralPath $originalLocation.Path
}
exit $exitCode
