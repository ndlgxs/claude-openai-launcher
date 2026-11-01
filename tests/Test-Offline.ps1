#Requires -Version 7.0
[CmdletBinding()]
param([switch] $KeepArtifacts)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Offline integration checks require Windows and PowerShell 7.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptsRoot = Join-Path $repoRoot 'scripts'
$pwshPath = Join-Path $PSHOME 'pwsh.exe'
$originalDataDirectory = [Environment]::GetEnvironmentVariable('CLAUDE_OPENAI_DATA_DIR', 'Process')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$tempName = 'claude-openai-offline-tests-' + [guid]::NewGuid().ToString('N')
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempParent $tempName))
$null = [IO.Directory]::CreateDirectory($testRoot)
$assertionCount = 0
$completed = $false

function Assert-Offline {
    param([bool] $Condition, [string] $Name)
    if (-not $Condition) { throw ('FAILED: ' + $Name) }
    $script:assertionCount++
    Write-Host ('PASS: ' + $Name)
}

function Invoke-OfflineScript {
    param([string] $Name, [string[]] $ScriptArguments = @(), [switch] $ExpectFailure)
    $scriptPath = Join-Path $scriptsRoot $Name
    $captured = @(& $pwshPath -NoLogo -NoProfile -File $scriptPath @ScriptArguments 2>&1)
    $scriptExitCode = $LASTEXITCODE
    $capturedText = ($captured | ForEach-Object { [string] $_ }) -join [Environment]::NewLine
    if ($ExpectFailure) {
        Assert-Offline ($scriptExitCode -ne 0) ($Name + ' rejects invalid input')
    }
    elseif ($scriptExitCode -ne 0) {
        throw ("{0} failed during an offline check (exit {1}):`n{2}" -f $Name, $scriptExitCode, $capturedText)
    }
    return $capturedText
}

function Read-TestJson {
    param([string] $Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

try {
    foreach ($source in Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -File) {
        $parseTokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$parseTokens, [ref]$parseErrors)
        Assert-Offline ($parseErrors.Count -eq 0) ('PowerShell syntax: ' + $source.Name)
    }

    . (Join-Path $scriptsRoot 'Common.ps1')
    $emptyDataRoot = Join-Path $testRoot 'machine without prior setup\private data with spaces'
    $env:CLAUDE_OPENAI_DATA_DIR = $emptyDataRoot
    $paths = Get-LauncherPaths
    Assert-Offline ($paths.RepoRoot -eq $repoRoot) 'repository path is derived from script location'
    Assert-Offline ($paths.DataRoot -eq $emptyDataRoot) 'custom data directory supports spaces and a new machine'
    Assert-Offline (-not (Test-Path -LiteralPath $paths.DataRoot)) 'resolving paths does not create account state'

    $projectPath = Join-Path $testRoot 'project with spaces'
    $null = [IO.Directory]::CreateDirectory($projectPath)
    $parsed = Invoke-OfflineScript 'Start.ps1' @('-ParseOnly', '-Project', $projectPath, '-Model', 'astra', '-p', 'Reply OK', '--output-format', 'json') | ConvertFrom-Json
    Assert-Offline ($parsed.RequestedModel -eq 'astra') 'launcher preserves an explicit model alias'
    Assert-Offline ($parsed.Project -eq $projectPath) 'launcher preserves an explicit project path with spaces'
    Assert-Offline ([bool] $parsed.IsPrintMode -and -not [bool] $parsed.IsInteractive) 'print mode does not request an interactive menu'
    Assert-Offline (@($parsed.Arguments) -contains 'Reply OK') 'launcher forwards the prompt'
    Assert-Offline (@($parsed.Arguments) -contains '--output-format') 'launcher preserves unknown native options'
    Assert-Offline (-not (Test-Path -LiteralPath $paths.DataRoot)) 'parse-only mode does not load credentials or create runtime data'

    $dragged = Invoke-OfflineScript 'Start.ps1' @('-ParseOnly', $projectPath, '--model=gpt-6-luna(high)', '--resume', 'session-fixture') | ConvertFrom-Json
    Assert-Offline ($dragged.Project -eq $projectPath) 'launcher detects a dragged project folder'
    Assert-Offline ($dragged.RequestedModel -eq 'gpt-6-luna(high)') 'native model selection retains its reasoning suffix'
    Assert-Offline (@($dragged.Arguments) -notcontains $projectPath) 'dragged project is removed from Claude arguments'
    Assert-Offline (@($dragged.Arguments) -contains '--resume' -and @($dragged.Arguments) -contains 'session-fixture') 'remaining native arguments retain their values'
    $directoryPrompt = Invoke-OfflineScript 'Start.ps1' @('-ParseOnly', '-p', $projectPath) | ConvertFrom-Json
    Assert-Offline (@($directoryPrompt.Arguments) -contains $projectPath) 'an existing directory passed as a print prompt is not consumed as a project'
    Assert-Offline ($directoryPrompt.Project -eq (Get-Location).Path) 'a print prompt keeps the caller working directory as its project'

    Initialize-LauncherDataDirectory -Paths $paths
    foreach ($directory in @($paths.DataRoot, $paths.BinRoot, $paths.AuthRoot, $paths.LogsRoot)) {
        Assert-Offline (Test-Path -LiteralPath $directory -PathType Container) 'fresh private data directories are initialized'
    }
    Assert-Offline ($null -eq (Read-LauncherRuntime -Paths $paths)) 'fresh installation does not require prior runtime state'

    $fixtureBinaryRoot = Join-Path $testRoot 'inert fixture binaries'
    $null = [IO.Directory]::CreateDirectory($fixtureBinaryRoot)
    $fakeProxy = Join-Path $fixtureBinaryRoot 'cli-proxy-api.exe'
    $fakeClaude = Join-Path $fixtureBinaryRoot 'claude.exe'
    [IO.File]::WriteAllText($fakeProxy, 'INERT OFFLINE FIXTURE: never execute this file.')
    [IO.File]::WriteAllText($fakeClaude, 'INERT CLAUDE PATH FIXTURE: never execute this file.')
    $architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        'X64' { 'amd64' }
        'Arm64' { 'aarch64' }
        default { throw 'Offline package fixture supports Windows x64 or ARM64.' }
    }
    $archiveName = 'CLIProxyAPI_8.0.48_windows_' + $architecture + '.zip'
    $archivePath = Join-Path $testRoot $archiveName
    Compress-Archive -LiteralPath $fakeProxy -DestinationPath $archivePath
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumsPath = Join-Path $testRoot 'checksums.txt'
    [IO.File]::WriteAllText($checksumsPath, ($archiveHash + '  ' + $archiveName + [Environment]::NewLine))
    $null = Invoke-OfflineScript 'Setup.ps1' @('-ClaudePath', $fakeClaude, '-ProxyArchivePath', $archivePath, '-ChecksumsPath', $checksumsPath)
    Assert-Offline (Test-Path -LiteralPath $paths.BinaryPath -PathType Leaf) 'setup installs a hash-verified local archive without executing it'
    $runtimeBefore = Read-TestJson $paths.RuntimePath
    Assert-Offline ($runtimeBefore.proxyVersion -eq '8.0.48') 'setup records the fixed proxy version'
    Assert-Offline ($runtimeBefore.claudePath -eq $fakeClaude) 'setup accepts an explicit executable path with spaces'
    Assert-Offline (-not [string]::IsNullOrWhiteSpace([string] $runtimeBefore.proxyKey)) 'setup generates a local access key'
    $null = Invoke-OfflineScript 'Setup.ps1' @('-ClaudePath', $fakeClaude, '-SkipDownload')
    $runtimeAfter = Read-TestJson $paths.RuntimePath
    Assert-Offline ($runtimeAfter.proxyKey -eq $runtimeBefore.proxyKey) 'repeated setup preserves the local key'
    Assert-Offline (@(Get-ChildItem -LiteralPath $paths.AuthRoot -File).Count -eq 0) 'offline setup creates no account login'

    $env:CLAUDE_OPENAI_DATA_DIR = Join-Path $testRoot 'empty skip download installation'
    $null = Invoke-OfflineScript 'Setup.ps1' @('-ClaudePath', $fakeClaude, '-SkipDownload') -ExpectFailure
    $env:CLAUDE_OPENAI_DATA_DIR = $emptyDataRoot
    [IO.File]::AppendAllText($paths.BinaryPath, 'TAMPERED')
    $null = Invoke-OfflineScript 'Setup.ps1' @('-ClaudePath', $fakeClaude, '-SkipDownload') -ExpectFailure

    $accountAPath = Join-Path $PSScriptRoot 'fixtures\catalog-account-a.json'
    $accountBPath = Join-Path $PSScriptRoot 'fixtures\catalog-account-b.json'
    $env:CLAUDE_OPENAI_DATA_DIR = Join-Path $testRoot 'account A data'
    $null = Invoke-OfflineScript 'Update-Models.ps1' @('-CatalogPath', $accountAPath)
    $accountAPaths = Get-LauncherPaths
    $accountA = Read-TestJson $accountAPaths.ProfilesPath
    Assert-Offline ($accountA.activeContextWindow -eq 800000) 'account A uses the minimum current account model limit'
    Assert-Offline ($accountA.commonOutputBudget -eq 128000) 'published output capability determines the local common output budget'
    Assert-Offline ($accountA.autoCompactWindow -eq 628000) 'account A leaves output and safety space before compaction'
    Assert-Offline (@($accountA.profiles.PSObject.Properties).Count -eq 4) 'account A generates all four supported profiles'
    foreach ($profile in $accountA.profiles.PSObject.Properties.Value) {
        Assert-Offline ($profile.contextWindow -eq 800000 -and $profile.maxOutputTokens -eq 128000) 'switchable model profiles share safe active limits'
    }
    Copy-Item -LiteralPath $accountAPaths.ProfilesPath -Destination $paths.ProfilesPath
    Copy-Item -LiteralPath $accountAPaths.SessionSettingsPath -Destination $paths.SessionSettingsPath
    $env:CLAUDE_OPENAI_DATA_DIR = $emptyDataRoot
    $tamperedStartError = Invoke-OfflineScript 'Start.ps1' @('-Project', $projectPath, '-Model', 'sol', '-p', 'This must never run') -ExpectFailure
    Assert-Offline ($tamperedStartError -match 'no longer matches the verified installation') 'launcher rejects a tampered proxy before starting any executable'

    $env:CLAUDE_OPENAI_DATA_DIR = Join-Path $testRoot 'account B different limits'
    $null = Invoke-OfflineScript 'Update-Models.ps1' @('-MetadataPath', $accountBPath)
    $accountBPaths = Get-LauncherPaths
    $accountB = Read-TestJson $accountBPaths.ProfilesPath
    Assert-Offline ($accountB.activeContextWindow -eq 400000) 'a different account produces its own lower common window'
    Assert-Offline ($accountB.autoCompactWindow -eq 228000) 'compaction adapts to the second account'
    Assert-Offline ($accountB.activeContextWindow -ne 872000) 'the launcher does not hard-code a previous account window'
    Assert-Offline (@(Get-ChildItem -LiteralPath $accountBPaths.AuthRoot -File -ErrorAction SilentlyContinue).Count -eq 0) 'catalog import needs no stored token or network login'
    $settings = Read-TestJson $accountBPaths.SessionSettingsPath
    Assert-Offline ($null -ne $settings.modelPicker) 'model refresh creates explicit Claude picker metadata'

    $invalidCatalog = Get-Content -LiteralPath $accountBPath -Raw | ConvertFrom-Json -AsHashtable
    $null = $invalidCatalog.models[2].Remove('max_context_window')
    $invalidPath = Join-Path $testRoot 'missing context metadata.json'
    [IO.File]::WriteAllText($invalidPath, ($invalidCatalog | ConvertTo-Json -Depth 20))
    $profilesBefore = Get-Content -LiteralPath $accountBPaths.ProfilesPath -Raw
    $null = Invoke-OfflineScript 'Update-Models.ps1' @('-CatalogPath', $invalidPath) -ExpectFailure
    Assert-Offline ((Get-Content -LiteralPath $accountBPaths.ProfilesPath -Raw) -eq $profilesBefore) 'missing metadata is rejected without overwriting valid profiles'
    $emptyCatalogError = Invoke-OfflineScript 'Update-Models.ps1' @('-CatalogPath', '') -ExpectFailure
    Assert-Offline ($emptyCatalogError -notmatch 'No independent proxy login|No enabled independent proxy credential') 'an empty explicit catalog path does not fall back to account login'

    $completed = $true
    Write-Host ("Offline checks passed: {0} assertions. No login, model request, or proxy launch was performed." -f $assertionCount)
}
finally {
    [Environment]::SetEnvironmentVariable('CLAUDE_OPENAI_DATA_DIR', $originalDataDirectory, 'Process')
    if ($completed -and -not $KeepArtifacts) {
        # Delete only the exact random directory created by this invocation.
        $cleanupPath = [IO.Path]::GetFullPath($testRoot)
        $cleanupParent = [IO.Path]::GetDirectoryName($cleanupPath).TrimEnd('\')
        if ($cleanupParent -ne $tempParent -or [IO.Path]::GetFileName($cleanupPath) -ne $tempName -or
            -not $tempName.StartsWith('claude-openai-offline-tests-')) {
            throw 'Refusing to clean an unexpected test directory.'
        }
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }
    else { Write-Host ('Offline test artifacts retained at: ' + $testRoot) }
}

# Expected failing child processes leave LASTEXITCODE nonzero. Reaching here
# means every assertion and cleanup completed, so report success explicitly.
exit 0

