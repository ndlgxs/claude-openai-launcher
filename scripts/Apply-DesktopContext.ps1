#Requires -Version 7.0
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Apply this account's model windows to the machine-wide Claude Code policy.
.DESCRIPTION
Run in an already elevated PowerShell 7 session. This script never requests
elevation, starts applications, installs software, edits permissions, changes
ACLs, or changes execution policy. -WhatIf previews without writing.

By default, limits come from Get-LauncherPaths().ProfilesPath. A legacy install
can supply ModelProfiles.json with -LegacyInstallRoot. Explicit -Context,
-Output and -Compact must be supplied together and replace profile discovery.

The three env values affect every applicable Claude Code session on this
machine, including Desktop, not only this launcher's models. Native Claude
model recognition and provider-side limits still apply. The local route entries
receive only autoCompactWindow; existing permissions and other settings stay.

The result names a private backup manifest. Restore only this script's unchanged
result with -RestoreBackup <absolute manifest.json>. A later policy edit or a
changed backup hash causes restore to refuse the write.

https://code.claude.com/docs/en/settings-reference#parentsettingsbehavior
https://code.claude.com/docs/en/model-config#which-ids-claude_code_max_context_tokens-applies-to
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $LegacyInstallRoot,
    [ValidateRange(1, 2147483647)] [Nullable[long]] $Context,
    [ValidateRange(1, 2147483647)] [Nullable[long]] $Output,
    [ValidateRange(1, 2147483647)] [Nullable[long]] $Compact,
    [string] $RestoreBackup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This script supports Windows only.' }
. (Join-Path $PSScriptRoot 'Common.ps1')
$paths = Get-LauncherPaths
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
if ([string]::IsNullOrWhiteSpace($programFilesRoot)) { throw 'The system Program Files directory is unavailable.' }
$scriptIdentity = 'ClaudeDesktopContextPolicy-v1'
$managedPath = [IO.Path]::GetFullPath((Join-Path $programFilesRoot 'ClaudeCode\managed-settings.json'))
$managedDirectory = [IO.Path]::GetDirectoryName($managedPath)
$backupRoot = [IO.Path]::GetFullPath((Join-Path $paths.DataRoot 'desktop-backups'))
$utf8 = [Text.UTF8Encoding]::new($false)

function Get-ContextBytesHash {
    param([byte[]] $Bytes)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function Assert-ContextPlainPath {
    param([string] $Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw ('Refusing a path through a symbolic link or junction: ' + $candidate)
            }
        }
        if ($candidate -eq [IO.Path]::GetPathRoot($candidate)) { break }
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
}

function Get-ContextPositiveInteger {
    param([object] $Value, [string] $Field)
    $parsed = 0L
    if ($null -eq $Value -or
        -not [long]::TryParse([string] $Value, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref] $parsed) -or
        $parsed -lt 1 -or $parsed -gt 2147483647) {
        throw ('Model profiles contain an invalid ' + $Field + '. Refresh account metadata before applying context.')
    }
    return $parsed
}

function Get-ContextProfileLimits {
    param([string] $ProfilesPath)
    if (-not (Test-Path -LiteralPath $ProfilesPath -PathType Leaf)) {
        throw 'ModelProfiles.json is missing. Run setup.cmd and login.cmd, or supply all three explicit limits.'
    }
    try { $document = Get-Content -LiteralPath $ProfilesPath -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw 'ModelProfiles.json is invalid JSON. Refresh account metadata; file contents were not printed.' }
    if ($document -isnot [Collections.IDictionary] -or
        $document['profiles'] -isnot [Collections.IDictionary] -or $document['profiles'].Count -eq 0) {
        throw 'ModelProfiles.json has no usable model profiles. Run login.cmd or Update-Models.ps1.'
    }
    $shared = $null
    foreach ($profile in $document['profiles'].Values) {
        if ($profile -isnot [Collections.IDictionary]) { throw 'A model profile is not a JSON object.' }
        $limits = [ordered]@{
            Context = Get-ContextPositiveInteger $profile['contextWindow'] 'contextWindow'
            Output = Get-ContextPositiveInteger $profile['maxOutputTokens'] 'maxOutputTokens'
            Compact = Get-ContextPositiveInteger $profile['autoCompactWindow'] 'autoCompactWindow'
        }
        if ($null -eq $shared) { $shared = $limits }
        elseif ($shared.Context -ne $limits.Context -or $shared.Output -ne $limits.Output -or
            $shared.Compact -ne $limits.Compact) {
            throw 'Model profiles have different active windows. Refresh them to a common safe window before applying machine policy.'
        }
    }
    foreach ($mapping in @(
        @{ Header = 'activeContextWindow'; Limit = 'Context' },
        @{ Header = 'commonOutputBudget'; Limit = 'Output' },
        @{ Header = 'autoCompactWindow'; Limit = 'Compact' }
    )) {
        if ($document.Contains($mapping.Header) -and
            (Get-ContextPositiveInteger $document[$mapping.Header] $mapping.Header) -ne $shared[$mapping.Limit]) {
            throw 'The model profile summary and per-model windows disagree. Refresh account metadata first.'
        }
    }
    return [pscustomobject] $shared
}

function Get-ContextRouteIds {
    $levels = @('low', 'medium', 'high', 'xhigh', 'max')
    foreach ($base in @('local-claude-sol', 'local-claude-astra', 'local-claude-terra', 'local-claude-luna')) {
        $base
        foreach ($level in $levels) { '{0}({1})' -f $base, $level }
    }
}

function Merge-ContextSettings {
    param([Collections.IDictionary] $Settings, [long] $Context, [long] $Output, [long] $Compact)
    $Settings['parentSettingsBehavior'] = 'merge'
    foreach ($section in @('env', 'modelSettings')) {
        if (-not $Settings.Contains($section) -or $null -eq $Settings[$section]) {
            $Settings[$section] = [ordered]@{}
        }
        elseif ($Settings[$section] -isnot [Collections.IDictionary]) {
            throw ("Existing '{0}' must be a JSON object. No policy was changed." -f $section)
        }
    }
    $Settings['env']['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] = [string] $Context
    $Settings['env']['CLAUDE_CODE_MAX_OUTPUT_TOKENS'] = [string] $Output
    $Settings['env']['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] = [string] $Compact
    foreach ($model in Get-ContextRouteIds) {
        if (-not $Settings['modelSettings'].Contains($model) -or $null -eq $Settings['modelSettings'][$model]) {
            $Settings['modelSettings'][$model] = [ordered]@{}
        }
        elseif ($Settings['modelSettings'][$model] -isnot [Collections.IDictionary]) {
            throw ("Existing modelSettings entry '{0}' must be a JSON object. No policy was changed." -f $model)
        }
        $Settings['modelSettings'][$model]['autoCompactWindow'] = $Compact
    }
    return $Settings
}

Assert-ContextPlainPath $managedDirectory
Assert-ContextPlainPath $managedPath
Assert-ContextPlainPath $backupRoot
$explicitLimitCount = @('Context', 'Output', 'Compact' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count
if ($explicitLimitCount -notin @(0, 3)) { throw 'Supply Context, Output and Compact together, or omit all three to use account profiles.' }

if (-not [string]::IsNullOrWhiteSpace($RestoreBackup)) {
    if ($explicitLimitCount -ne 0 -or $PSBoundParameters.ContainsKey('LegacyInstallRoot')) {
        throw 'RestoreBackup cannot be combined with profile or window overrides.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($RestoreBackup)) { throw 'RestoreBackup must be an absolute manifest.json path.' }
    $manifestPath = [IO.Path]::GetFullPath($RestoreBackup)
    $backupPrefix = $backupRoot.TrimEnd([char[]] @('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if (-not $manifestPath.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($manifestPath) -cne 'manifest.json') {
        throw 'Restore accepts only a manifest inside this script private backup directory.'
    }
    $backupDirectory = [IO.Path]::GetDirectoryName($manifestPath)
    Assert-ContextPlainPath $backupDirectory
    Assert-ContextPlainPath $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest -isnot [Collections.IDictionary] -or $manifest['schemaVersion'] -ne 1 -or
        $manifest['scriptId'] -cne $scriptIdentity -or $manifest['targetPath'] -cne $managedPath -or
        $manifest['originalExists'] -isnot [bool] -or $manifest['writtenSha256'] -notmatch '^[a-f0-9]{64}$') {
        throw 'The backup manifest is not a supported record from this script.'
    }
    if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash -ine $manifest['writtenSha256']) {
        throw 'The current managed policy differs from this script result. Refusing to overwrite later administrator changes.'
    }
    $beforeBytes = $null
    if ($manifest['originalExists']) {
        $beforePath = Join-Path $backupDirectory 'managed-settings.before.json'
        Assert-ContextPlainPath $beforePath
        $beforeBytes = [IO.File]::ReadAllBytes($beforePath)
        if ($manifest['originalSha256'] -notmatch '^[a-f0-9]{64}$' -or
            (Get-ContextBytesHash $beforeBytes) -cne $manifest['originalSha256']) {
            throw 'The original backup hash does not match its manifest.'
        }
        $beforeDocument = $utf8.GetString($beforeBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable
        if ($beforeDocument -isnot [Collections.IDictionary]) { throw 'The original backup is not a JSON object.' }
    }
    if ($PSCmdlet.ShouldProcess($managedPath, 'Restore this script verified original managed policy')) {
        # Confirmation can wait while another administrator edits the policy.
        Assert-ContextPlainPath $managedPath
        if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash -ine $manifest['writtenSha256']) {
            throw 'The managed policy changed before restore. Refusing to overwrite later administrator changes.'
        }
        if ($manifest['originalExists']) { [IO.File]::WriteAllBytes($managedPath, $beforeBytes) }
        else { Remove-Item -LiteralPath $managedPath -Force }
        [pscustomobject]@{ Action = 'Restored'; Target = $managedPath; Manifest = $manifestPath; RestartClaude = $true }
    }
    return
}

$profilesPath = $null
if ($explicitLimitCount -eq 0) {
    $profilesPath = if ([string]::IsNullOrWhiteSpace($LegacyInstallRoot)) { $paths.ProfilesPath }
    else { Join-Path ([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($LegacyInstallRoot))) 'ModelProfiles.json' }
    $limits = Get-ContextProfileLimits -ProfilesPath $profilesPath
    $Context = $limits.Context
    $Output = $limits.Output
    $Compact = $limits.Compact
}
if ($Compact -lt 100000 -or $Compact -gt 1000000) { throw 'Compact must be between 100000 and 1000000 tokens for modelSettings.' }
if ([long] $Compact + [long] $Output + 44000L -gt [long] $Context) { throw 'Compact + Output + 44000 must not exceed Context.' }
$originalExists = Test-Path -LiteralPath $managedPath -PathType Leaf
$originalBytes = if ($originalExists) { [IO.File]::ReadAllBytes($managedPath) } else { [byte[]]@() }
$settings = if ($originalExists) {
    $utf8.GetString($originalBytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable
}
else { [ordered]@{} }
if ($settings -isnot [Collections.IDictionary]) { throw 'The existing managed settings must be a JSON object. Nothing was changed.' }
$settings = Merge-ContextSettings -Settings $settings -Context $Context -Output $Output -Compact $Compact
$newText = ($settings | ConvertTo-Json -Depth 100 -WarningAction Stop) + [Environment]::NewLine
$roundTrip = $newText | ConvertFrom-Json -AsHashtable
if ($roundTrip -isnot [Collections.IDictionary]) { throw 'Merged policy JSON validation failed.' }
$newBytes = $utf8.GetBytes($newText)
$writtenHash = Get-ContextBytesHash $newBytes
$summary = [ordered]@{
    Target = $managedPath
    Scope = 'Machine-wide Claude Code, all users and supported local host applications'
    ProfilesPath = $profilesPath
    ContextForUnknownCustomIds = [long] $Context
    OutputBudget = [long] $Output
    AutoCompactWindow = [long] $Compact
    ParentSettingsBehavior = 'merge'
    ModelSettingsIds = @(Get-ContextRouteIds)
    BackupRoot = $backupRoot
    ExistingManagedPolicy = [bool] $originalExists
}
if (-not $PSCmdlet.ShouldProcess($managedPath, 'Back up and merge machine-wide Claude Code context settings')) {
    [pscustomobject] $summary
    return
}
$backupName = 'desktop-context-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
$backupDirectory = Join-Path $backupRoot $backupName
$null = [IO.Directory]::CreateDirectory($backupDirectory)
if ($originalExists) { [IO.File]::WriteAllBytes((Join-Path $backupDirectory 'managed-settings.before.json'), $originalBytes) }
$manifest = [ordered]@{
    schemaVersion = 1
    scriptId = $scriptIdentity
    targetPath = $managedPath
    createdAtUtc = [DateTime]::UtcNow.ToString('o')
    originalExists = [bool] $originalExists
    originalSha256 = if ($originalExists) { Get-ContextBytesHash $originalBytes } else { $null }
    writtenSha256 = $writtenHash
    context = [long] $Context
    output = [long] $Output
    compact = [long] $Compact
}
$manifestPath = Join-Path $backupDirectory 'manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine, $utf8)
# Refuse to overwrite a concurrent administrator change after preparing backup.
if ($originalExists) {
    if (-not (Test-Path -LiteralPath $managedPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash -ine $manifest.originalSha256) {
        throw ('The managed policy changed during preparation. Nothing was applied. Backup: ' + $manifestPath)
    }
}
elseif (Test-Path -LiteralPath $managedPath) { throw 'A managed policy appeared during preparation. Nothing was applied.' }
$null = [IO.Directory]::CreateDirectory($managedDirectory)
# An existing target is overwritten in place to retain its filesystem ACL.
[IO.File]::WriteAllBytes($managedPath, $newBytes)
if ((Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash -ine $writtenHash) {
    throw ('The written policy hash is unexpected. Retained backup: ' + $manifestPath)
}
$summary['Action'] = 'Applied'
$summary['Manifest'] = $manifestPath
$summary['RestartClaude'] = $true
[pscustomobject] $summary
