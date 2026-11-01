#Requires -Version 7.0
# Dot-sourcing this file only defines helpers. It does not write files or start apps.
. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-DesktopValue {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Read-DesktopJson {
    param([Parameter(Mandatory)] [string] $Path, [switch] $AsHashtable)
    try { Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable:$AsHashtable -ErrorAction Stop }
    catch { throw ("Could not read Desktop JSON at '{0}'. Restore its private backup or configure the profile again." -f $Path) }
}

function Get-DesktopKeyFingerprint {
    param([Parameter(Mandatory)] [string] $Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { throw 'A local gateway key is required.' }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Key))).ToLowerInvariant()
}

function Test-DesktopProtectedKey {
    param([object] $Value)
    if ($Value -isnot [string]) { return $false }
    # Claude Desktop 4.4212 config-library keys use this versioned marker and
    # Base64 ciphertext. Its Windows backend is user_dpapi, with a purpose-bound
    # {configLibrary:{key,value}} envelope. Do not decrypt the App's credential.
    $candidate = $Value.TrimStart()
    return $candidate -cmatch '^__sealed__:v1:(?:[A-Za-z0-9+/]{4})+(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'
}

function Test-DesktopGatewayCredential {
    param([object] $SavedValue, [Parameter(Mandatory)] [string] $RuntimeKey, [object] $State)
    $fingerprint = [string](Get-DesktopValue $State 'proxyKeyFingerprintSha256')
    $fingerprintMatches = $false
    if ($fingerprint) {
        if ($fingerprint -notmatch '^[0-9a-fA-F]{64}$') { return $false }
        $fingerprintMatches = [string]::Equals($fingerprint, (Get-DesktopKeyFingerprint -Key $RuntimeKey), [StringComparison]::OrdinalIgnoreCase)
        # A changed runtime key always requires configuration again, including
        # when somebody manually changes the saved plaintext key to match it.
        if (-not $fingerprintMatches) { return $false }
    }
    if ($SavedValue -is [string] -and [string]::Equals($SavedValue, $RuntimeKey, [StringComparison]::Ordinal)) { return $true }
    return ($fingerprintMatches -and (Test-DesktopProtectedKey -Value $SavedValue))
}

function Get-DesktopLauncherPaths {
    [CmdletBinding()]
    param([string] $LegacyInstallRoot, [string] $StateRoot, [string] $DesktopHome)
    $base = Get-LauncherPaths
    $dataRoot = if ([string]::IsNullOrWhiteSpace($LegacyInstallRoot)) { $base.DataRoot } else {
        [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($LegacyInstallRoot))
    }
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Join-Path $dataRoot 'desktop' }
    if ([string]::IsNullOrWhiteSpace($DesktopHome)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable; pass -DesktopHome.' }
        $DesktopHome = Join-Path $env:LOCALAPPDATA 'Claude-3p'
    }
    $state = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
    $desktopHomePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DesktopHome))
    [pscustomobject]@{
        RepoRoot = $base.RepoRoot; ScriptsRoot = $base.ScriptsRoot; DataRoot = $dataRoot
        BinRoot = Join-Path $dataRoot 'bin'; BinaryPath = Join-Path $dataRoot 'bin\cli-proxy-api.exe'
        RuntimePath = Join-Path $dataRoot 'runtime.json'
        ConfigPath = Join-Path $dataRoot $(if ([string]::IsNullOrWhiteSpace($LegacyInstallRoot)) { 'proxy.config.yaml' } else { 'config.yaml' })
        ProfilesPath = Join-Path $dataRoot 'ModelProfiles.json'; SessionSettingsPath = Join-Path $dataRoot 'Claude.settings.json'
        AuthRoot = Join-Path $dataRoot 'auth'; LogsRoot = Join-Path $dataRoot 'logs'; PidPath = Join-Path $dataRoot 'proxy.pid'
        ProxyVersion = $base.ProxyVersion; StateRoot = $state; InstallationPath = Join-Path $state 'installation.json'
        BackupRoot = Join-Path $state 'backups'; DesktopHome = $desktopHomePath; LibraryRoot = Join-Path $desktopHomePath 'configLibrary'
        MetaPath = Join-Path $desktopHomePath 'configLibrary\_meta.json'; IsLegacy = -not [string]::IsNullOrWhiteSpace($LegacyInstallRoot)
    }
}

function Get-DesktopModelLimits {
    param([Parameter(Mandatory)] [object] $Profiles)
    $profileMap = Get-DesktopValue $Profiles 'profiles'
    $supported = @('gpt-6.1-sol', 'gpt-6-astra', 'gpt-6.1-terra', 'gpt-6-luna')
    $limits = $null
    foreach ($model in $supported) {
        $profile = Get-DesktopValue $profileMap $model
        if ($null -eq $profile) { continue }
        $values = @{}
        foreach ($field in @('contextWindow', 'maxOutputTokens', 'autoCompactWindow')) {
            $value = Get-DesktopValue $profile $field
            $number = 0L
            if ($null -eq $value -or $value -is [bool] -or -not [long]::TryParse([string]$value, [ref]$number) -or $number -le 0) {
                throw ("Model '{0}' has no valid '{1}'. Run update-models.cmd after signing in." -f $model, $field)
            }
            $values[$field] = $number
        }
        if ($values.autoCompactWindow -lt 100000 -or $values.autoCompactWindow + $values.maxOutputTokens -ge $values.contextWindow) {
            throw 'Model profiles leave insufficient context headroom.'
        }
        $accountMax = Get-DesktopValue $profile 'accountMaxContextWindow'
        if ($null -ne $accountMax -and $values.contextWindow -gt [long]$accountMax) { throw 'A model profile exceeds its account context maximum.' }
        if ($null -eq $limits) { $limits = $values }
        else {
            foreach ($field in $values.Keys) {
                if ($limits[$field] -ne $values[$field]) { throw 'Desktop model profiles must share context, output, and compaction limits so model switching stays safe.' }
            }
        }
    }
    if ($null -eq $limits) { throw 'No supported OpenAI model profiles were found. Run update-models.cmd.' }
    [pscustomobject]$limits
}

function New-DesktopProfileConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Profiles, [Parameter(Mandatory)] [object] $Runtime)
    $limits = Get-DesktopModelLimits -Profiles $Profiles
    $port = [int](Get-DesktopValue $Runtime 'port')
    $key = [string](Get-DesktopValue $Runtime 'proxyKey')
    if ($port -lt 1 -or $port -gt 65535 -or [string]::IsNullOrWhiteSpace($key)) { throw 'The private proxy runtime is incomplete; run setup.cmd.' }
    $labels = [ordered]@{ 'gpt-6.1-sol' = 'GPT-6.1 Sol'; 'gpt-6-astra' = 'GPT-6 Astra'; 'gpt-6.1-terra' = 'GPT-6.1 Terra'; 'gpt-6-luna' = 'GPT-6 Luna' }
    $routeNames = @{ 'gpt-6.1-sol' = 'local-claude-sol'; 'gpt-6-astra' = 'local-claude-astra'; 'gpt-6.1-terra' = 'local-claude-terra'; 'gpt-6-luna' = 'local-claude-luna' }
    $allowed = @('low', 'medium', 'high', 'xhigh', 'max')
    $profileMap = Get-DesktopValue $Profiles 'profiles'
    $models = [Collections.Generic.List[object]]::new()
    $routes = [Collections.Generic.List[object]]::new()
    $firstEffort = $null
    foreach ($modelId in $labels.Keys) {
        $profile = Get-DesktopValue $profileMap $modelId
        if ($null -eq $profile) { continue }
        $advertised = @(Get-DesktopValue $profile 'reasoningLevels')
        $efforts = @($allowed | Where-Object { $advertised -contains $_ })
        if (-not $efforts.Count) { throw ("No supported reasoning effort was advertised for '{0}'." -f $modelId) }
        $default = [string](Get-DesktopValue $profile 'defaultReasoningEffort')
        if ($efforts -notcontains $default) { $default = $efforts[0] }
        $orderedEfforts = @($default) + @($efforts | Where-Object { $_ -ne $default })
        if ($null -eq $firstEffort) { $firstEffort = $default }
        $route = $routeNames[$modelId]
        $routes.Add([ordered]@{ id = $modelId; route = $route; label = $labels[$modelId] })
        foreach ($effort in $orderedEfforts) {
            $models.Add([ordered]@{ name = ('{0}({1})' -f $route, $effort); labelOverride = ('{0} - {1}' -f $labels[$modelId], $effort); maxEffort = $effort })
        }
    }
    [pscustomobject]@{
        Configuration = [ordered]@{
            inferenceProvider = 'gateway'; inferenceGatewayBaseUrl = ('http://127.0.0.1:{0}' -f $port)
            inferenceGatewayApiKey = $key; inferenceGatewayAuthScheme = 'bearer'
            modelDiscoveryEnabled = $false; defaultModelEffort = $firstEffort; inferenceModels = $models.ToArray()
        }
        Limits = $limits; Routes = $routes.ToArray(); Options = $models.ToArray(); DefaultEffort = $firstEffort
    }
}

function Test-DesktopSavedConfiguration {
    param([object] $Profile, [object] $Meta, [object] $State, [object] $Built)
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string](Get-DesktopValue $State 'id'), [ref]$id)) { return $false }
    if (-not [string]::Equals([string](Get-DesktopValue $Meta 'appliedId'), $id.ToString(), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($field in @('inferenceProvider', 'inferenceGatewayBaseUrl', 'inferenceGatewayAuthScheme')) {
        if (-not [string]::Equals([string](Get-DesktopValue $Profile $field), [string]$Built.Configuration[$field], [StringComparison]::Ordinal)) { return $false }
    }
    if ((Get-DesktopValue $Profile 'modelDiscoveryEnabled') -ne $false) { return $false }
    $savedOptions = @(Get-DesktopValue $Profile 'inferenceModels')
    if ($savedOptions.Count -ne $Built.Options.Count) { return $false }
    foreach ($expected in $Built.Options) {
        $matches = @($savedOptions | Where-Object { [string]::Equals([string](Get-DesktopValue $_ 'name'), [string]$expected.name, [StringComparison]::Ordinal) })
        if ($matches.Count -ne 1 -or (Get-DesktopValue $matches[0] 'maxEffort') -cne $expected.maxEffort) { return $false }
    }
    Test-DesktopGatewayCredential -SavedValue (Get-DesktopValue $Profile 'inferenceGatewayApiKey') -RuntimeKey $Built.Configuration.inferenceGatewayApiKey -State $State
}

function Test-DesktopMachineContext {
    param([Parameter(Mandatory)] [object] $Limits, [string] $MachineSettingsPath)
    if ([string]::IsNullOrWhiteSpace($MachineSettingsPath)) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) { return $false }
        $MachineSettingsPath = Join-Path $env:ProgramFiles 'ClaudeCode\managed-settings.json'
    }
    if (-not (Test-Path -LiteralPath $MachineSettingsPath -PathType Leaf)) { return $false }
    try {
        $settings = Get-Content -LiteralPath $MachineSettingsPath -Raw | ConvertFrom-Json -AsHashtable
        $environment = $settings['env']
        return ($settings['parentSettingsBehavior'] -eq 'merge' -and
            [string]$environment['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] -eq [string]$Limits.contextWindow -and
            [string]$environment['CLAUDE_CODE_MAX_OUTPUT_TOKENS'] -eq [string]$Limits.maxOutputTokens -and
            [string]$environment['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] -eq [string]$Limits.autoCompactWindow)
    }
    catch { return $false }
}

function Resolve-ClaudeDesktopApplication {
    param([string] $DesktopPath)
    if (-not [string]::IsNullOrWhiteSpace($DesktopPath)) {
        $candidate = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($DesktopPath))
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or [IO.Path]::GetExtension($candidate) -ine '.exe' -or $candidate -match '(?i)[\\/]claude-code[\\/]') {
            throw 'DesktopPath must name an installed Claude Desktop executable, not the embedded Claude Code CLI.'
        }
        return $candidate
    }
    if (-not $IsWindows -or -not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return $null }
    foreach ($package in @(Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)) {
        if ($package.PackageFamilyName -ne 'Claude_pzs8sxrjxfjjc') { continue }
        $candidate = Join-Path $package.InstallLocation 'app\Claude.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-DesktopProxyBinary {
    param([object] $Paths, [object] $Runtime)
    if (-not (Test-Path -LiteralPath $Paths.BinaryPath -PathType Leaf)) { throw 'The local proxy binary is missing. Run setup.cmd.' }
    $recordedHash = [string](Get-DesktopValue $Runtime 'proxyBinarySha256')
    if ($recordedHash) {
        $actualHash = (Get-FileHash -LiteralPath $Paths.BinaryPath -Algorithm SHA256).Hash
        if (-not [string]::Equals($recordedHash, $actualHash, [StringComparison]::OrdinalIgnoreCase)) { throw 'The proxy binary does not match its verified installation hash. Rerun setup.cmd.' }
    }
    elseif (-not $Paths.IsLegacy) { throw 'The proxy installation has no recorded binary hash. Run setup.cmd; only an explicit legacy installation can use path validation.' }
}

function Get-DesktopProxyStatus {
    param([object] $Paths, [object] $Runtime, [string[]] $ExpectedRoutes = @())
    $port = [int](Get-DesktopValue $Runtime 'port')
    $key = [string](Get-DesktopValue $Runtime 'proxyKey')
    if ($port -lt 1 -or $port -gt 65535 -or [string]::IsNullOrWhiteSpace($key)) { throw 'The private proxy runtime is incomplete.' }
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='cli-proxy-api.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [string]::Equals([IO.Path]::GetFullPath($_.ExecutablePath), [IO.Path]::GetFullPath($Paths.BinaryPath), [StringComparison]::OrdinalIgnoreCase)
    })
    $listeners = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) { $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) }
    $endpointReady = $false; $authenticated = $false; $ids = @(); $missing = @()
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.UseProxy = $false; $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(2)
    try {
        $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $key)
        $json = $client.GetStringAsync(('http://127.0.0.1:{0}/v1/models' -f $port)).GetAwaiter().GetResult() | ConvertFrom-Json
        $authenticated = $true
        $ids = @($json.data | ForEach-Object { [string]$_.id })
        $missing = @($ExpectedRoutes | Where-Object { $ids -notcontains $_ })
        $endpointReady = $missing.Count -eq 0
    }
    catch { }
    finally { $client.Dispose(); $handler.Dispose() }
    $matchingIds = @($processes | ForEach-Object { [int]$_.ProcessId })
    $verifiedIds = @()
    if ($listeners.Count) { $verifiedIds = @($listeners | Where-Object { $matchingIds -contains [int]$_.OwningProcess } | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique) }
    else { $verifiedIds = @($matchingIds) }
    $loopbackOnly = @($listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }).Count -eq 0
    [pscustomobject]@{
        Ready = ($endpointReady -and $verifiedIds.Count -eq 1 -and $loopbackOnly)
        EndpointAuthenticated = $authenticated; MissingRoutes = $missing
        MatchingProcessIds = $matchingIds; VerifiedProcessIds = $verifiedIds
        PortOccupied = ($listeners.Count -gt 0 -or $authenticated); LoopbackOnly = $loopbackOnly
    }
}
