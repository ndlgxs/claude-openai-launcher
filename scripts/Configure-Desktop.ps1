#Requires -Version 7.0
[CmdletBinding()]
param([string] $LegacyInstallRoot, [string] $StateRoot, [string] $DesktopHome, [switch] $Preview,
    # Read-only override for isolated tests or a non-default managed-settings location.
    [string] $MachineSettingsPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Desktop.ps1')
$paths = Get-DesktopLauncherPaths -LegacyInstallRoot $LegacyInstallRoot -StateRoot $StateRoot -DesktopHome $DesktopHome
$runtime = Read-LauncherRuntime -Paths $paths -Required
if (-not (Test-Path -LiteralPath $paths.ProfilesPath -PathType Leaf)) { throw 'Model profiles are missing. Complete login and run update-models.cmd first.' }
$profiles = Get-Content -LiteralPath $paths.ProfilesPath -Raw | ConvertFrom-Json
$built = New-DesktopProfileConfiguration -Profiles $profiles -Runtime $runtime
$oldState = if (Test-Path -LiteralPath $paths.InstallationPath -PathType Leaf) { Read-DesktopJson -Path $paths.InstallationPath } else { $null }
$profileGuid = [guid]::Empty
$savedId = [string](Get-DesktopValue $oldState 'id')
if (-not [guid]::TryParse($savedId, [ref]$profileGuid)) { $profileGuid = [guid]::NewGuid() }
$id = $profileGuid.ToString()
$profilePath = Join-Path $paths.LibraryRoot ($id + '.json')
$meta = if (Test-Path -LiteralPath $paths.MetaPath -PathType Leaf) { Read-DesktopJson -Path $paths.MetaPath -AsHashtable } else { [ordered]@{} }
$entries = @($meta['entries'] | Where-Object { $null -ne $_ -and $_['id'] -ne $id })
$meta['entries'] = @($entries) + @([ordered]@{ id = $id; name = 'OpenAI local gateway' })
$meta['appliedId'] = $id
$machineReady = Test-DesktopMachineContext -Limits $built.Limits -MachineSettingsPath $MachineSettingsPath
$summary = [ordered]@{ Preview = [bool]$Preview; ProfileId = $id; ModelOptions = $built.Options.Count; ContextWindow = $built.Limits.contextWindow; OutputBudget = $built.Limits.maxOutputTokens; AutoCompactWindow = $built.Limits.autoCompactWindow; MachineContextConfigured = $machineReady; ProfilePath = $profilePath; MetaPath = $paths.MetaPath; StatePath = $paths.InstallationPath }
if ($Preview) { $summary | ConvertTo-Json -Compress; return }

Protect-LauncherDataDirectory -Paths ([pscustomobject]@{ DataRoot = $paths.StateRoot })
$backupPath = Join-Path $paths.BackupRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($backupPath)
foreach ($backup in @(@($profilePath, 'profile.json'), @($paths.MetaPath, 'meta.json'), @($paths.InstallationPath, 'installation.json'))) {
    if (Test-Path -LiteralPath $backup[0] -PathType Leaf) { Copy-Item -LiteralPath $backup[0] -Destination (Join-Path $backupPath $backup[1]) }
}
Write-LauncherJson -Path $profilePath -Value $built.Configuration
Write-LauncherJson -Path $paths.MetaPath -Value $meta
$state = [ordered]@{ id = $id; profilePath = $profilePath; metaPath = $paths.MetaPath; backupPath = $backupPath; configuredAt = [DateTimeOffset]::UtcNow.ToString('o'); contextWindow = $built.Limits.contextWindow; outputBudget = $built.Limits.maxOutputTokens; autoCompactWindow = $built.Limits.autoCompactWindow; contextApplied = $machineReady; models = $built.Routes; proxyKeyFingerprintSha256 = Get-DesktopKeyFingerprint -Key $built.Configuration.inferenceGatewayApiKey }
Write-LauncherJson -Path $paths.InstallationPath -Value $state
$summary | ConvertTo-Json -Compress
Write-Host 'Desktop profile saved. If Claude Desktop is already open, exit and reopen it to load the updated model picker.'
if (-not $machineReady) { Write-Host 'The machine-level Code context configuration is not applied. Use Apply-DesktopContext.ps1 as documented for limits that persist across all App launches.' }
