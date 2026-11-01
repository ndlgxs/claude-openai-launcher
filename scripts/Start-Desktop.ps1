#Requires -Version 7.0
[CmdletBinding()]
param([string] $LegacyInstallRoot, [string] $StateRoot, [string] $DesktopHome, [string] $DesktopPath, [switch] $CheckOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Desktop.ps1')
if (-not $IsWindows) { throw 'Claude Desktop launch is supported on Windows only.' }
$paths = Get-DesktopLauncherPaths -LegacyInstallRoot $LegacyInstallRoot -StateRoot $StateRoot -DesktopHome $DesktopHome
$runtime = Read-LauncherRuntime -Paths $paths -Required
$profiles = Get-Content -LiteralPath $paths.ProfilesPath -Raw | ConvertFrom-Json
$built = New-DesktopProfileConfiguration -Profiles $profiles -Runtime $runtime
Test-DesktopProxyBinary -Paths $paths -Runtime $runtime
$application = Resolve-ClaudeDesktopApplication -DesktopPath $DesktopPath
if (-not $application) { throw 'An installed official Claude Desktop AppPackage was not found. Install Claude Desktop yourself, or pass -DesktopPath to its existing executable.' }
if (-not (Test-Path -LiteralPath $paths.InstallationPath -PathType Leaf)) { throw 'Desktop profile is not configured. Run configure-desktop.cmd first.' }
$state = Read-DesktopJson -Path $paths.InstallationPath
$id = [guid]::Empty
if (-not [guid]::TryParse([string](Get-DesktopValue $state 'id'), [ref]$id)) { throw 'The private Desktop installation state is invalid. Run configure-desktop.cmd again.' }
$profilePath = Join-Path $paths.LibraryRoot ($id.ToString() + '.json')
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf) -or -not (Test-Path -LiteralPath $paths.MetaPath -PathType Leaf)) { throw 'The Desktop profile is missing. Run configure-desktop.cmd again.' }
$savedProfile = Read-DesktopJson -Path $profilePath
$meta = Read-DesktopJson -Path $paths.MetaPath
if (-not (Test-DesktopSavedConfiguration -Profile $savedProfile -Meta $meta -State $state -Built $built)) { throw 'The applied Desktop profile is stale, its credential storage is unrecognized, or it selects another profile. Run configure-desktop.cmd again.' }
$proxyStatus = Get-DesktopProxyStatus -Paths $paths -Runtime $runtime -ExpectedRoutes @($built.Routes | ForEach-Object { $_.route })
$machineReady = Test-DesktopMachineContext -Limits $built.Limits
if ($CheckOnly) {
    [pscustomobject]@{ CheckOnly = $true; ProxyReady = $proxyStatus.Ready; EndpointAuthenticated = $proxyStatus.EndpointAuthenticated; MissingRoutes = $proxyStatus.MissingRoutes; DesktopPath = $application; ProfileConfigured = $true; ModelOptions = $built.Options.Count; ContextWindow = $built.Limits.contextWindow; OutputBudget = $built.Limits.maxOutputTokens; AutoCompactWindow = $built.Limits.autoCompactWindow; MachineContextConfigured = $machineReady } | ConvertTo-Json -Compress
    return
}
if (-not $proxyStatus.Ready) {
    if ($proxyStatus.PortOccupied -or $proxyStatus.MatchingProcessIds.Count) { throw 'The proxy endpoint could not be verified against this installed binary and key. No process was replaced or stopped.' }
    if (-not (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf)) { throw 'The proxy configuration is missing. Run setup.cmd.' }
    $null = [IO.Directory]::CreateDirectory($paths.LogsRoot)
    $suffix = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $proxy = Start-Process -FilePath $paths.BinaryPath -ArgumentList @('--config', ('"{0}"' -f $paths.ConfigPath), '--local-model') -WorkingDirectory $paths.DataRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $paths.LogsRoot ('desktop-proxy-' + $suffix + '.out.log')) -RedirectStandardError (Join-Path $paths.LogsRoot ('desktop-proxy-' + $suffix + '.err.log')) -PassThru
    [IO.File]::WriteAllText($paths.PidPath, [string]$proxy.Id)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $proxyStatus = Get-DesktopProxyStatus -Paths $paths -Runtime $runtime -ExpectedRoutes @($built.Routes | ForEach-Object { $_.route })
    } while (-not $proxyStatus.Ready -and [DateTime]::UtcNow -lt $deadline -and -not $proxy.HasExited)
    if (-not $proxyStatus.Ready) { throw 'The local proxy did not become ready. Inspect its private logs; no existing process was stopped.' }
}
$running = @(Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and [string]::Equals([IO.Path]::GetFullPath($_.ExecutablePath), $application, [StringComparison]::OrdinalIgnoreCase) })
if ($running.Count) {
    Write-Host 'Claude App 已在运行；若刚更新配置，请完全退出后重开。'
}
else {
    $environment = @{ CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string]$built.Limits.contextWindow; CLAUDE_CODE_MAX_OUTPUT_TOKENS = [string]$built.Limits.maxOutputTokens; CLAUDE_CODE_AUTO_COMPACT_WINDOW = [string]$built.Limits.autoCompactWindow }
    $previous = @{}
    try {
        foreach ($name in $environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process'); [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
        # Electron's stdout/stderr must not inherit the menu's terminal. On
        # Windows Start-Process redirects directly to file handles, so logging
        # remains independent of this short-lived launcher process.
        $null = [IO.Directory]::CreateDirectory($paths.LogsRoot)
        $appLogSuffix = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $null = Start-Process -FilePath $application -WorkingDirectory $paths.DataRoot -WindowStyle Normal -RedirectStandardOutput (Join-Path $paths.LogsRoot ('app-' + $appLogSuffix + '.out.log')) -RedirectStandardError (Join-Path $paths.LogsRoot ('app-' + $appLogSuffix + '.err.log')) -PassThru
    }
    finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') } }
    Write-Host 'Claude App 已打开。'
}
if (-not $machineReady) { Write-Host '要持久应用 App 上下文，请以管理员身份运行 apply-desktop-context.cmd。' }
