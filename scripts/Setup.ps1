#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $ClaudePath,
    [ValidateRange(1, 65535)] [int] $Port = 8317,
    [string] $ProxyArchivePath,
    [string] $ChecksumsPath,
    [switch] $SkipDownload
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    if (-not $IsWindows) { throw 'This launcher supports Windows. Run it from PowerShell 7 on Windows.' }
    if ($SkipDownload -and (-not [string]::IsNullOrWhiteSpace($ProxyArchivePath) -or -not [string]::IsNullOrWhiteSpace($ChecksumsPath))) {
        throw 'Use either SkipDownload or the offline archive/checksum paths.'
    }
    $paths = Get-LauncherPaths
    Initialize-LauncherDataDirectory -Paths $paths
    $previous = Read-LauncherRuntime -Paths $paths
    $runtime = [ordered] @{}
    if ($null -ne $previous) {
        foreach ($property in $previous.PSObject.Properties) { $runtime[$property.Name] = $property.Value }
    }
    $installedHash = if (Test-Path -LiteralPath $paths.BinaryPath -PathType Leaf) { (Get-FileHash -LiteralPath $paths.BinaryPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    $recordedHash = [string] $runtime['proxyBinarySha256']
    $existingVerified = $installedHash -ne '' -and $recordedHash -ne '' -and $installedHash -eq $recordedHash -and $runtime['proxyVersion'] -eq $paths.ProxyVersion
    if ($SkipDownload -and -not $existingVerified) {
        throw 'No verified existing proxy installation was found. Run setup.cmd normally, or provide ProxyArchivePath and ChecksumsPath.'
    }
    if (-not $SkipDownload -and (-not $existingVerified -or -not [string]::IsNullOrWhiteSpace($ProxyArchivePath))) {
        $architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
            'X64' { 'amd64' }
            'Arm64' { 'aarch64' }
            default { throw 'Only Windows x64 and ARM64 are supported.' }
        }
        $assetName = 'CLIProxyAPI_{0}_windows_{1}.zip' -f $paths.ProxyVersion, $architecture
        $releaseBase = 'https://github.com/router-for-me/CLIProxyAPI/releases/download/v' + $paths.ProxyVersion
        $downloadRoot = Join-Path $paths.DataRoot 'downloads'
        $null = [System.IO.Directory]::CreateDirectory($downloadRoot)
        if ([string]::IsNullOrWhiteSpace($ProxyArchivePath)) {
            $ProxyArchivePath = Join-Path $downloadRoot $assetName
            Write-Host ('Downloading CLIProxyAPI {0} for Windows {1}.' -f $paths.ProxyVersion, $architecture)
            Invoke-WebRequest -Uri ($releaseBase + '/' + $assetName) -OutFile $ProxyArchivePath
        }
        else { $ProxyArchivePath = [System.IO.Path]::GetFullPath($ProxyArchivePath) }
        if ([string]::IsNullOrWhiteSpace($ChecksumsPath)) {
            $ChecksumsPath = Join-Path $downloadRoot ('checksums-' + $paths.ProxyVersion + '.txt')
            Invoke-WebRequest -Uri ($releaseBase + '/checksums.txt') -OutFile $ChecksumsPath
        }
        else { $ChecksumsPath = [System.IO.Path]::GetFullPath($ChecksumsPath) }
        foreach ($inputFile in @($ProxyArchivePath, $ChecksumsPath)) {
            if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw ('Required installation file does not exist: ' + $inputFile) }
        }
        $expectedHash = ''
        foreach ($line in Get-Content -LiteralPath $ChecksumsPath) {
            if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -ceq $assetName) {
                $expectedHash = $Matches[1].ToLowerInvariant()
                break
            }
        }
        if ($expectedHash -eq '') { throw ('The checksum manifest has no SHA-256 entry for ' + $assetName) }
        $actualHash = (Get-FileHash -LiteralPath $ProxyArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { throw 'Proxy archive SHA-256 verification failed. The archive was not installed.' }
        $stageRoot = Join-Path $paths.DataRoot ('.install-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $ProxyArchivePath -DestinationPath $stageRoot -Force
            $executables = @(Get-ChildItem -LiteralPath $stageRoot -Filter 'cli-proxy-api.exe' -File -Recurse)
            if ($executables.Count -ne 1) { throw 'The verified archive does not contain exactly one cli-proxy-api.exe.' }
            Copy-Item -LiteralPath $executables[0].FullName -Destination $paths.BinaryPath -Force
        }
        finally {
            $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
            $resolvedData = [System.IO.Path]::GetFullPath($paths.DataRoot).TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
            if (-not $resolvedStage.StartsWith($resolvedData, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing to clean an installation directory outside the launcher data directory.'
            }
            if (Test-Path -LiteralPath $resolvedStage -PathType Container) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
        }
        $runtime['proxyArchiveSha256'] = $actualHash
        $runtime['proxyBinarySha256'] = (Get-FileHash -LiteralPath $paths.BinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $runtime['proxyVersion'] = $paths.ProxyVersion
    }
    if ([string]::IsNullOrWhiteSpace([string] $runtime['proxyKey'])) {
        $random = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($random)
        $runtime['proxyKey'] = 'local-' + [Convert]::ToBase64String($random).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    if ($PSBoundParameters.ContainsKey('Port') -or -not $runtime.Contains('port')) { $runtime['port'] = $Port }
    if ([int] $runtime['port'] -lt 1 -or [int] $runtime['port'] -gt 65535) { throw 'The saved proxy port is invalid. Rerun setup.cmd -Port 8317.' }
    if ([string]::IsNullOrWhiteSpace([string] $runtime['preferredModel'])) { $runtime['preferredModel'] = 'gpt-6.1-sol' }
    $resolvedClaude = Resolve-ClaudeExecutable -ClaudePath $ClaudePath -Runtime $previous -Paths $paths
    $runtime['claudePath'] = if ($null -eq $resolvedClaude) { '' } else { $resolvedClaude }
    $runtime['updatedAt'] = [DateTime]::UtcNow.ToString('o')
    $authYaml = $paths.AuthRoot.Replace("'", "''")
    $keyYaml = ([string] $runtime['proxyKey']).Replace("'", "''")
    $config = @"
config-version: 8
server:
  host: '127.0.0.1'
  port: $($runtime['port'])
access:
  api-keys:
    - '$keyYaml'
oauth:
  auth-dir: '$authYaml'
management:
  allow-remote: false
  secret-key: ''
  disable-control-panel: true
observability:
  logs:
    debug: false
    request-log: false
plugins:
  enabled: false
"@
    [System.IO.File]::WriteAllText($paths.ConfigPath, $config + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-LauncherRuntime -Runtime $runtime -Paths $paths
    Write-Host ('Setup complete. Private data directory: ' + $paths.DataRoot)
    if ([string]::IsNullOrWhiteSpace($resolvedClaude)) {
        Write-Host 'Claude Code CLI was not found. Install it using the official instructions, then rerun setup.cmd or pass -ClaudePath.' -ForegroundColor Yellow
        Write-Host 'https://code.claude.com/docs/en/setup'
    }
    else { Write-Host ('Claude Code CLI: ' + $resolvedClaude) }
    Write-Host 'Next: run login.cmd to authorize your own ChatGPT account in the browser.'
    exit 0
}
catch {
    Write-Host ([string] $_.Exception.Message) -ForegroundColor Red
    exit 1
}
