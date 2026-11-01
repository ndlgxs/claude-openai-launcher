#Requires -Version 7.0
# Definitions only: loading the console backend never starts a process or sends
# an HTTP request. Public context/status objects contain no runtime key.
. (Join-Path $PSScriptRoot 'Desktop.ps1')

function Update-ConsoleContextState {
    param([Parameter(Mandatory)] [object] $Context)
    $contextId = [string](Get-DesktopValue $Context 'ContextId')
    $registry = Get-Variable -Name ConsoleContextState -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $registry -or -not $registry.Value.ContainsKey($contextId)) { throw 'The console context has expired. Call Get-ConsoleContext again.' }
    $entry = $script:ConsoleContextState[$contextId]
    $entry.Runtime = $null; $entry.RuntimeReady = $false; $entry.Endpoint = $null
    $entry.Models = @(); $entry.ExpectedRoutes = @(); $entry.ModelIssue = $null
    $entry.RuntimeIssue = 'Launcher setup is incomplete. Run setup.cmd, then login.cmd and update-models.cmd.'
    try {
        $entry.Runtime = Read-LauncherRuntime -Paths $entry.Paths
        if ($null -ne $entry.Runtime) {
            $port = 0
            $key = [string](Get-DesktopValue $entry.Runtime 'proxyKey')
            if ([int]::TryParse([string](Get-DesktopValue $entry.Runtime 'port'), [ref]$port) -and $port -ge 1 -and $port -le 65535 -and -not [string]::IsNullOrWhiteSpace($key)) {
                $entry.RuntimeReady = $true
                $entry.Endpoint = 'http://127.0.0.1:{0}' -f $port
                $entry.RuntimeIssue = $null
            }
            else { $entry.RuntimeIssue = 'The private runtime is incomplete or invalid. Run setup.cmd; no credential contents were printed.' }
        }
    }
    catch { $entry.RuntimeIssue = 'The private runtime could not be read. Repair it or run setup.cmd; no credential contents were printed.' }
    if (Test-Path -LiteralPath $entry.Paths.ProfilesPath -PathType Leaf) {
        try {
            $profiles = Read-DesktopJson -Path $entry.Paths.ProfilesPath
            # Model summaries do not need the real credential, including before
            # setup. The pure builder validates common account context limits.
            $built = New-DesktopProfileConfiguration -Profiles $profiles -Runtime @{ port = 1; proxyKey = 'unused-console-summary' }
            $entry.ExpectedRoutes = @($built.Routes | ForEach-Object { $_.route })
            $entry.Models = @($built.Routes | ForEach-Object {
                $model = $_
                $profile = Get-DesktopValue (Get-DesktopValue $profiles 'profiles') $model.id
                [pscustomobject]@{
                    id = $model.id; label = $model.label
                    reasoningLevels = @('low', 'medium', 'high', 'xhigh', 'max' | Where-Object { @(Get-DesktopValue $profile 'reasoningLevels') -contains $_ })
                    defaultEffort = [string](Get-DesktopValue $profile 'defaultReasoningEffort')
                    contextWindow = $built.Limits.contextWindow; maxOutputTokens = $built.Limits.maxOutputTokens
                    autoCompactWindow = $built.Limits.autoCompactWindow
                }
            })
        }
        catch { $entry.ModelIssue = 'Model profiles are invalid or use inconsistent limits. Sign in with login.cmd and run update-models.cmd.' }
    }
    else { $entry.ModelIssue = 'Model profiles are missing. Complete login.cmd and run update-models.cmd.' }
    $entry.Configured = ($entry.RuntimeReady -and $entry.Models.Count -gt 0 -and -not $entry.ModelIssue -and (Test-Path -LiteralPath $entry.Paths.BinaryPath -PathType Leaf) -and (Test-Path -LiteralPath $entry.Paths.ConfigPath -PathType Leaf))
}

function Get-ConsoleContext {
    [CmdletBinding()]
    param([string] $LegacyInstallRoot, [string] $StateRoot, [string] $DesktopHome)
    $paths = Get-DesktopLauncherPaths -LegacyInstallRoot $LegacyInstallRoot -StateRoot $StateRoot -DesktopHome $DesktopHome
    if ($null -eq (Get-Variable -Name ConsoleContextState -Scope Script -ErrorAction SilentlyContinue)) { $script:ConsoleContextState = @{} }
    $contextId = [guid]::NewGuid().ToString('N')
    $script:ConsoleContextState[$contextId] = @{
        Paths = $paths; Runtime = $null; RuntimeReady = $false; RuntimeIssue = $null
        Endpoint = $null; Models = @(); ExpectedRoutes = @(); ModelIssue = $null; Configured = $false
    }
    $context = [pscustomobject]@{ ContextId = $contextId }
    Update-ConsoleContextState -Context $context
    $entry = $script:ConsoleContextState[$contextId]
    # Copy the public paths: changing a returned object cannot redirect process
    # control to another installation inside the private context registry.
    [pscustomobject]@{
        ContextId = $contextId; Paths = $paths.PSObject.Copy(); Endpoint = $entry.Endpoint
        Configured = $entry.Configured; Models = @($entry.Models); ModelIssue = $entry.ModelIssue
        Message = $entry.RuntimeIssue
    }
}

function Get-ConsoleProcessIdentity {
    param([object] $Paths, [ValidateRange(1, 2147483647)] [int] $ProcessId)
    $identity = [ordered]@{ ProcessId = $ProcessId; Exists = $false; Verified = $false; PathMatches = $false; ConfigMatches = $false; QueryFailed = $false }
    try {
        $process = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $ProcessId) -ErrorAction Stop
        if ($null -eq $process) { return [pscustomobject]$identity }
        $identity.Exists = $true
        if ($process.ExecutablePath) {
            $identity.PathMatches = [string]::Equals([IO.Path]::GetFullPath($process.ExecutablePath), [IO.Path]::GetFullPath($Paths.BinaryPath), [StringComparison]::OrdinalIgnoreCase)
        }
        if ($identity.PathMatches -and $process.CommandLine) {
            $match = [regex]::Match($process.CommandLine, '(?i)(?:^|\s)--config(?:\s*=\s*|\s+)(?:"([^"]+)"|([^\s"]+))')
            if ($match.Success) {
                $configArgument = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
                if ([IO.Path]::IsPathFullyQualified($configArgument)) {
                    $identity.ConfigMatches = [string]::Equals([IO.Path]::GetFullPath($configArgument), [IO.Path]::GetFullPath($Paths.ConfigPath), [StringComparison]::OrdinalIgnoreCase)
                }
            }
        }
        $identity.Verified = $identity.PathMatches -and $identity.ConfigMatches
    }
    catch { $identity.QueryFailed = $true }
    [pscustomobject]$identity
}

function Get-ConsolePidRecord {
    param([object] $Paths)
    $record = [ordered]@{ State = 'Missing'; ProcessId = $null; Verified = $false }
    if (-not (Test-Path -LiteralPath $Paths.PidPath -PathType Leaf)) { return [pscustomobject]$record }
    try {
        $recordedProcessId = 0
        if (-not [int]::TryParse([IO.File]::ReadAllText($Paths.PidPath).Trim(), [ref]$recordedProcessId) -or $recordedProcessId -le 0) {
            $record.State = 'Invalid'; return [pscustomobject]$record
        }
        $record.ProcessId = $recordedProcessId
        $identity = Get-ConsoleProcessIdentity -Paths $Paths -ProcessId $recordedProcessId
        $record.State = if ($identity.QueryFailed) { 'Unverified' } elseif (-not $identity.Exists) { 'Exited' } elseif (-not $identity.PathMatches) { 'PathMismatch' } elseif (-not $identity.ConfigMatches) { 'ConfigMismatch' } else { 'Verified' }
        $record.Verified = $identity.Verified
    }
    catch { $record.State = 'Unreadable' }
    [pscustomobject]$record
}

function Get-ConsoleStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Context)
    Update-ConsoleContextState -Context $Context
    $entry = $script:ConsoleContextState[[string]$Context.ContextId]
    $state = 'Unverified'; $message = $entry.RuntimeIssue
    $processIds = @(); $missingRoutes = @(); $authenticated = $false
    $pidRecord = if ($IsWindows) { Get-ConsolePidRecord -Paths $entry.Paths } else { [pscustomobject]@{ State = 'Unverified'; Verified = $false; ProcessId = $null } }
    if ($entry.RuntimeReady -and $IsWindows) {
        $transport = Get-DesktopProxyStatus -Paths $entry.Paths -Runtime $entry.Runtime -ExpectedRoutes $entry.ExpectedRoutes
        $authenticated = $transport.EndpointAuthenticated
        $missingRoutes = @($transport.MissingRoutes)
        $projectIds = @($transport.MatchingProcessIds | Where-Object { (Get-ConsoleProcessIdentity -Paths $entry.Paths -ProcessId $_).Verified })
        $readyIds = @($transport.VerifiedProcessIds | Where-Object { $projectIds -contains $_ })
        $processIds = @($projectIds)
        if ($transport.Ready -and $readyIds.Count -eq 1) {
            try {
                Test-DesktopProxyBinary -Paths $entry.Paths -Runtime $entry.Runtime
                $state = 'Ready'; $message = 'The local proxy is ready; authenticated model discovery and project process identity passed.'
                if (-not $pidRecord.Verified -or $pidRecord.ProcessId -ne $readyIds[0]) { $message += ' Run Start once to record its verified PID before using Stop.' }
            }
            catch { $message = 'The running endpoint was found, but the installed proxy binary is missing or failed its installation hash check. Run setup.cmd.' }
        }
        elseif ($transport.PortOccupied -and $readyIds.Count -eq 0) {
            $state = 'PortConflict'; $message = 'The configured port is occupied by an endpoint that cannot be verified as this project. No other process will be stopped.'
        }
        elseif ($transport.PortOccupied -or $transport.MatchingProcessIds.Count) {
            $message = if ($missingRoutes.Count) { 'The project proxy is present, but required model routes are missing. Complete login and update the model/proxy configuration.' } else { 'A matching proxy process is present but its authenticated endpoint or project configuration could not be verified.' }
        }
        else {
            $state = 'Stopped'; $message = 'The project proxy is stopped.'
            if (-not $entry.Configured) { $message += ' Run setup.cmd before starting it.' }
        }
    }
    elseif (-not $IsWindows) { $message = 'Proxy process verification and control are supported on Windows only.' }
    [pscustomobject]@{
        State = $state; ProcessIds = @($processIds); Endpoint = $entry.Endpoint; Message = $message
        Configured = $entry.Configured; Models = @($entry.Models); ModelIssue = $entry.ModelIssue
        EndpointAuthenticated = $authenticated; MissingRoutes = @($missingRoutes)
        PidFileState = $pidRecord.State; CanStop = [bool]$pidRecord.Verified
    }
}

function Test-ConsoleProxyConfiguration {
    param([object] $Paths, [object] $Runtime)
    if (-not (Test-Path -LiteralPath $Paths.ConfigPath -PathType Leaf)) { throw 'The project proxy configuration is missing. Run setup.cmd.' }
    $configHost = $null; $configPort = $null; $insideServer = $false
    try {
        foreach ($line in [IO.File]::ReadAllLines($Paths.ConfigPath)) {
            if ($line -match '^server:\s*(?:#.*)?$') { $insideServer = $true; continue }
            if (-not $insideServer) { continue }
            if ($line -match '^\S') { break }
            if ($line -match '^  host:\s*["'']?(127\.0\.0\.1|::1)["'']?\s*(?:#.*)?$') { $configHost = $Matches[1] }
            if ($line -match '^  port:\s*(\d+)\s*(?:#.*)?$') { $configPort = [int]$Matches[1] }
        }
    }
    catch { throw 'The private proxy configuration could not be validated; its contents were not printed.' }
    if (-not $configHost -or $configPort -ne [int](Get-DesktopValue $Runtime 'port')) { throw 'The project config must use a loopback server host and the same port as runtime.json. Repair it or run setup.cmd.' }
}

function Start-ConsoleProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Context, [ValidateRange(2, 60)] [int] $TimeoutSeconds = 15)
    if (-not $IsWindows) { throw 'Proxy process control is supported on Windows only.' }
    Update-ConsoleContextState -Context $Context
    $entry = $script:ConsoleContextState[[string]$Context.ContextId]
    if (-not $entry.RuntimeReady) { throw $entry.RuntimeIssue }
    Test-DesktopProxyBinary -Paths $entry.Paths -Runtime $entry.Runtime
    Test-ConsoleProxyConfiguration -Paths $entry.Paths -Runtime $entry.Runtime
    $status = Get-ConsoleStatus -Context $Context
    if ($status.State -eq 'Ready') {
        # Adopt only the exact verified binary + absolute project config. No
        # process is replaced and no credential or authorization is changed.
        [IO.File]::WriteAllText($entry.Paths.PidPath, [string]$status.ProcessIds[0])
        return Get-ConsoleStatus -Context $Context
    }
    if ($status.State -ne 'Stopped') { throw $status.Message }
    $null = [IO.Directory]::CreateDirectory($entry.Paths.LogsRoot)
    $suffix = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $child = Start-Process -FilePath $entry.Paths.BinaryPath -ArgumentList @('--config', ('"{0}"' -f $entry.Paths.ConfigPath), '--local-model') -WorkingDirectory $entry.Paths.DataRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $entry.Paths.LogsRoot ('console-proxy-' + $suffix + '.out.log')) -RedirectStandardError (Join-Path $entry.Paths.LogsRoot ('console-proxy-' + $suffix + '.err.log')) -PassThru
    [IO.File]::WriteAllText($entry.Paths.PidPath, [string]$child.Id)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        $status = Get-ConsoleStatus -Context $Context
        if ($status.State -eq 'Ready' -and $status.ProcessIds -contains $child.Id) { return $status }
    } while ([DateTime]::UtcNow -lt $deadline -and -not $child.HasExited)
    # Roll back only the child created by this invocation, never an unrelated
    # existing process or another owner of the configured port.
    if (-not $child.HasExited -and (Get-ConsoleProcessIdentity -Paths $entry.Paths -ProcessId $child.Id).Verified) { $child.Kill(); $null = $child.WaitForExit(5000) }
    if ($child.HasExited -and (Test-Path -LiteralPath $entry.Paths.PidPath -PathType Leaf) -and [IO.File]::ReadAllText($entry.Paths.PidPath).Trim() -eq [string]$child.Id) { Remove-Item -LiteralPath $entry.Paths.PidPath -Force }
    throw 'The project proxy did not become ready. Inspect its private console-proxy logs; no existing process was stopped.'
}

function Stop-ConsoleProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Context)
    if (-not $IsWindows) { throw 'Proxy process control is supported on Windows only.' }
    Update-ConsoleContextState -Context $Context
    $entry = $script:ConsoleContextState[[string]$Context.ContextId]
    $record = Get-ConsolePidRecord -Paths $entry.Paths
    if (-not $record.Verified) {
        $status = Get-ConsoleStatus -Context $Context
        if ($status.State -eq 'Stopped' -and $record.State -in @('Missing', 'Exited')) { return $status }
        throw ('Refusing to stop an unverified PID file ({0}). Start this project through the launcher first; other processes and port owners were left untouched.' -f $record.State)
    }
    $target = Get-Process -Id $record.ProcessId -ErrorAction Stop
    # Pin a handle to this process, then check identity again before termination
    # so a stale PID cannot redirect Stop to a newly reused process ID.
    $null = $target.Handle
    $identity = Get-ConsoleProcessIdentity -Paths $entry.Paths -ProcessId $record.ProcessId
    if (-not $identity.Verified -or -not [string]::Equals([IO.Path]::GetFullPath($target.Path), [IO.Path]::GetFullPath($entry.Paths.BinaryPath), [StringComparison]::OrdinalIgnoreCase)) { throw 'Project process identity changed before Stop; no process was stopped.' }
    Stop-Process -InputObject $target -Force -ErrorAction Stop
    if (-not $target.WaitForExit(5000)) { throw 'The verified project proxy did not exit. Its PID file was retained.' }
    if ((Test-Path -LiteralPath $entry.Paths.PidPath -PathType Leaf) -and [IO.File]::ReadAllText($entry.Paths.PidPath).Trim() -eq [string]$record.ProcessId) { Remove-Item -LiteralPath $entry.Paths.PidPath -Force }
    Get-ConsoleStatus -Context $Context
}
