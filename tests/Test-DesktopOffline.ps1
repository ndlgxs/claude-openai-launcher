#Requires -Version 7.0
# Pure builder + isolated file tests. No proxy binary, network, App, or inference is used.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'scripts\Desktop.ps1')
$checks = 0
function Assert-Desktop([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw ('Desktop offline assertion failed: ' + $Message) }
    $script:checks++
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $tempBase ('claude-openai-desktop-test-' + [guid]::NewGuid().ToString('N'))
$savedDataDirectory = $env:CLAUDE_OPENAI_DATA_DIR
try {
    $data = Join-Path $scratch 'data'
    $desktopHomePath = Join-Path $scratch 'desktop-home'
    $stateRoot = Join-Path $scratch 'private-state'
    $machine = Join-Path $scratch 'machine\managed-settings.json'
    $env:CLAUDE_OPENAI_DATA_DIR = $data
    $profiles = [ordered]@{ profiles = [ordered]@{} }
    $defaults = [ordered]@{ 'gpt-6.1-sol' = 'low'; 'gpt-6-astra' = 'medium'; 'gpt-6.1-terra' = 'high'; 'gpt-6-luna' = 'max' }
    foreach ($model in $defaults.Keys) {
        $profiles.profiles[$model] = [ordered]@{ contextWindow = 800000; maxOutputTokens = 128000; autoCompactWindow = 628000; accountMaxContextWindow = 900000; reasoningLevels = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra'); defaultReasoningEffort = $defaults[$model] }
    }
    $runtime = [ordered]@{ proxyKey = 'offline-fixture-key-never-used'; port = 38491 }
    $built = New-DesktopProfileConfiguration -Profiles $profiles -Runtime $runtime
    Assert-Desktop ($built.Options.Count -eq 20) 'four models have exactly five effort options'
    Assert-Desktop ($built.Configuration.modelDiscoveryEnabled -eq $false) 'discovery is disabled'
    Assert-Desktop ($built.Configuration.defaultModelEffort -eq 'low') 'default effort matches the first option'
    Assert-Desktop ($built.Configuration.inferenceGatewayBaseUrl -eq 'http://127.0.0.1:38491') 'gateway uses the private runtime port'
    foreach ($route in $built.Routes) {
        $options = @($built.Options | Where-Object { $_.name.StartsWith($route.route + '(') })
        Assert-Desktop ($options.Count -eq 5) ('five explicit levels for ' + $route.id)
        Assert-Desktop ($options[0].maxEffort -eq $defaults[$route.id]) ('service default first for ' + $route.id)
        foreach ($level in @('low', 'medium', 'high', 'xhigh', 'max')) {
            $option = @($options | Where-Object { $_.name -eq ($route.route + '(' + $level + ')') })
            Assert-Desktop ($option.Count -eq 1 -and $option[0].maxEffort -eq $level -and $option[0].labelOverride -match [regex]::Escape($route.label)) ('exact suffix and actual GPT label: ' + $route.id + '/' + $level)
        }
    }
    $encoded = $built.Configuration | ConvertTo-Json -Depth 20
    Assert-Desktop ($encoded -notmatch 'behavesAs|supports1m|ultra') 'no Claude capability impersonation or harness-only effort'
    $paths = Get-DesktopLauncherPaths -StateRoot $stateRoot -DesktopHome $desktopHomePath
    Assert-Desktop ($paths.DataRoot -eq [IO.Path]::GetFullPath($data)) 'portable data override'
    Assert-Desktop ($paths.ConfigPath -eq (Join-Path $data 'proxy.config.yaml')) 'normal config filename'
    $legacy = Get-DesktopLauncherPaths -LegacyInstallRoot (Join-Path $scratch 'legacy') -StateRoot $stateRoot -DesktopHome $desktopHomePath
    Assert-Desktop ($legacy.ConfigPath -eq (Join-Path $scratch 'legacy\config.yaml')) 'legacy config filename'
    Write-LauncherJson -Path $paths.RuntimePath -Value $runtime
    Write-LauncherJson -Path $paths.ProfilesPath -Value $profiles
    $configure = Join-Path $repoRoot 'scripts\Configure-Desktop.ps1'
    $arguments = @{ StateRoot = $stateRoot; DesktopHome = $desktopHomePath; MachineSettingsPath = $machine }
    $previewText = & $configure @arguments -Preview
    $preview = $previewText | ConvertFrom-Json
    Assert-Desktop ($preview.Preview -and $preview.ModelOptions -eq 20) 'preview returns a safe summary'
    Assert-Desktop ($previewText -notmatch [regex]::Escape($runtime.proxyKey)) 'preview never prints the key'
    Assert-Desktop (-not (Test-Path -LiteralPath $desktopHomePath) -and -not (Test-Path -LiteralPath $stateRoot)) 'preview writes no directories or files'
    $firstText = & $configure @arguments
    Assert-Desktop (($firstText | Out-String) -notmatch [regex]::Escape($runtime.proxyKey)) 'configuration output never prints the key'
    $first = Read-DesktopJson -Path $paths.InstallationPath
    $profile = Read-DesktopJson -Path $first.profilePath
    $firstMeta = Read-DesktopJson -Path $paths.MetaPath
    Assert-Desktop ($profile.inferenceModels.Count -eq 20 -and $profile.inferenceGatewayApiKey -ceq $runtime.proxyKey) 'the official local profile stores the local client key and all options'
    Assert-Desktop ($first.contextApplied -eq $false) 'missing isolated machine configuration is detected'
    Assert-Desktop ($first.proxyKeyFingerprintSha256 -match '^[0-9a-f]{64}$') 'private state records the local runtime key fingerprint'
    Assert-Desktop (($firstText | Out-String) -notmatch [regex]::Escape($first.proxyKeyFingerprintSha256)) 'configuration output never prints the private fingerprint'
    Assert-Desktop (Test-DesktopSavedConfiguration -Profile $profile -Meta $firstMeta -State $first -Built $built) 'plaintext profile validates before the App protects it'
    # Simulate the App's ordinary at-rest rewrite, without calling DPAPI or
    # decrypting anything. This opaque fixture is deliberately not a credential.
    $profile.inferenceGatewayApiKey = '__sealed__:v1:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('opaque-app-ciphertext-fixture-never-decrypted'))
    Write-LauncherJson -Path $first.profilePath -Value $profile
    $roundTrip = Read-DesktopJson -Path $first.profilePath
    Assert-Desktop (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $firstMeta -State $first -Built $built) 'normal App-protected key roundtrip remains valid with the private fingerprint'
    $rotatedRuntime = @{ proxyKey = 'rotated-offline-fixture-key'; port = $runtime.port }
    $rotatedBuilt = New-DesktopProfileConfiguration -Profiles $profiles -Runtime $rotatedRuntime
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $firstMeta -State $first -Built $rotatedBuilt)) 'runtime key rotation requires reconfiguration even for an App-protected profile'
    $rotatedPlain = $rotatedBuilt.Configuration
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $rotatedPlain -Meta $firstMeta -State $first -Built $rotatedBuilt)) 'manually replacing plaintext cannot bypass an old private fingerprint'
    $legacyState = @{ id = $first.id }
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $firstMeta -State $legacyState -Built $built)) 'an opaque protected key without a fingerprint requires reconfiguration'
    Assert-Desktop (Test-DesktopSavedConfiguration -Profile $built.Configuration -Meta $firstMeta -State $legacyState -Built $built) 'legacy plaintext is compared directly without pretending to validate ciphertext'
    foreach ($badProtected in @('__sealed__:v1:not base64!', '__sealed__:v1:', '__sealed__:v2:YWJjZA==', '__encrypted__:YWJjZA==')) {
        Assert-Desktop (-not (Test-DesktopGatewayCredential -SavedValue $badProtected -RuntimeKey $runtime.proxyKey -State $first)) 'unknown or malformed protected format is rejected'
    }
    $wrongMeta = @{ appliedId = [guid]::NewGuid().ToString() }
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $wrongMeta -State $first -Built $built)) 'protected-key handling still binds the applied profile ID'
    $originalUrl = $roundTrip.inferenceGatewayBaseUrl
    $roundTrip.inferenceGatewayBaseUrl = 'http://127.0.0.1:38492'
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $firstMeta -State $first -Built $built)) 'protected-key handling still checks the exact gateway URL'
    $roundTrip.inferenceGatewayBaseUrl = $originalUrl
    $originalEffort = $roundTrip.inferenceModels[0].maxEffort
    $roundTrip.inferenceModels[0].maxEffort = 'ultra'
    Assert-Desktop (-not (Test-DesktopSavedConfiguration -Profile $roundTrip -Meta $firstMeta -State $first -Built $built)) 'protected-key handling still checks exact model efforts'
    $roundTrip.inferenceModels[0].maxEffort = $originalEffort
    $otherId = [guid]::NewGuid().ToString()
    $meta = Read-DesktopJson -Path $paths.MetaPath -AsHashtable
    $meta['entries'] += @{ id = $otherId; name = 'Another user profile' }
    $meta['customProperty'] = 'preserve-me'
    Write-LauncherJson -Path $paths.MetaPath -Value $meta
    Write-LauncherJson -Path $machine -Value @{ parentSettingsBehavior = 'merge'; env = @{ CLAUDE_CODE_MAX_CONTEXT_TOKENS = '800000'; CLAUDE_CODE_MAX_OUTPUT_TOKENS = '128000'; CLAUDE_CODE_AUTO_COMPACT_WINDOW = '628000' } }
    Assert-Desktop (Test-DesktopMachineContext -Limits $built.Limits -MachineSettingsPath $machine) 'actual machine fields match, independently of saved state'
    $null = & $configure @arguments
    $second = Read-DesktopJson -Path $paths.InstallationPath
    $meta = Read-DesktopJson -Path $paths.MetaPath -AsHashtable
    Assert-Desktop ($second.id -eq $first.id) 'reconfiguration reuses the private installation ID'
    Assert-Desktop ($meta['appliedId'] -eq $first.id) 'official metadata applies this profile'
    Assert-Desktop (@($meta['entries'] | Where-Object { $_['id'] -eq $otherId }).Count -eq 1 -and $meta['customProperty'] -eq 'preserve-me') 'unrelated profiles and metadata survive'
    Assert-Desktop ($second.contextApplied -eq $true) 'machine readiness is recomputed rather than trusting the old flag'
    Assert-Desktop ((Test-Path -LiteralPath (Join-Path $second.backupPath 'profile.json')) -and (Test-Path -LiteralPath (Join-Path $second.backupPath 'meta.json')) -and (Test-Path -LiteralPath (Join-Path $second.backupPath 'installation.json'))) 'private backups preserve all replaced files'
    $profiles.profiles['gpt-6-luna'].contextWindow = 700000
    $rejected = $false
    try { $null = New-DesktopProfileConfiguration -Profiles $profiles -Runtime $runtime } catch { $rejected = $true }
    Assert-Desktop $rejected 'unsafe model-switching context mismatch is rejected'
    $null = [IO.Directory]::CreateDirectory($paths.BinRoot)
    [IO.File]::WriteAllText($paths.BinaryPath, 'An inert fixture; never executed.')
    $runtime['proxyBinarySha256'] = (Get-FileHash -LiteralPath $paths.BinaryPath -Algorithm SHA256).Hash
    Test-DesktopProxyBinary -Paths $paths -Runtime $runtime
    Assert-Desktop $true 'recorded binary hash is accepted without executing the file'
    [IO.File]::AppendAllText($paths.BinaryPath, 'changed')
    $rejected = $false
    try { Test-DesktopProxyBinary -Paths $paths -Runtime $runtime } catch { $rejected = $true }
    Assert-Desktop $rejected 'changed binary hash is refused'
    $runtime.Remove('proxyBinarySha256')
    $rejected = $false
    try { Test-DesktopProxyBinary -Paths $paths -Runtime $runtime } catch { $rejected = $true }
    Assert-Desktop $rejected 'normal installations require a recorded binary hash'
    $legacySameRoot = Get-DesktopLauncherPaths -LegacyInstallRoot $data -StateRoot $stateRoot -DesktopHome $desktopHomePath
    Test-DesktopProxyBinary -Paths $legacySameRoot -Runtime $runtime
    Assert-Desktop $true 'explicit legacy installation can use exact-path binary validation'
    Write-Host ("Desktop offline tests passed: {0} assertions; no proxy, App, or network used." -f $checks)
}
finally {
    $env:CLAUDE_OPENAI_DATA_DIR = $savedDataDirectory
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $expectedPrefix = $tempBase.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar + 'claude-openai-desktop-test-'
    if (-not $resolvedScratch.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to clean an unexpected desktop-test path.' }
    if (Test-Path -LiteralPath $resolvedScratch) { Remove-Item -LiteralPath $resolvedScratch -Recurse -Force }
}
