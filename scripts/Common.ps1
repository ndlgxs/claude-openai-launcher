#Requires -Version 7.0

function Get-LauncherPaths {
    [CmdletBinding()]
    param()
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $dataRoot = $env:CLAUDE_OPENAI_DATA_DIR
    if ([string]::IsNullOrWhiteSpace($dataRoot)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            throw 'LOCALAPPDATA is unavailable. Set CLAUDE_OPENAI_DATA_DIR to a private data directory.'
        }
        $dataRoot = Join-Path $env:LOCALAPPDATA 'ClaudeOpenAI'
    }
    $dataRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($dataRoot))
    [pscustomobject]@{
        RepoRoot = $repoRoot
        ScriptsRoot = Join-Path $repoRoot 'scripts'
        DataRoot = $dataRoot
        BinRoot = Join-Path $dataRoot 'bin'
        BinaryPath = Join-Path $dataRoot 'bin\cli-proxy-api.exe'
        RuntimePath = Join-Path $dataRoot 'runtime.json'
        ConfigPath = Join-Path $dataRoot 'proxy.config.yaml'
        ProfilesPath = Join-Path $dataRoot 'ModelProfiles.json'
        SessionSettingsPath = Join-Path $dataRoot 'Claude.settings.json'
        AuthRoot = Join-Path $dataRoot 'auth'
        LogsRoot = Join-Path $dataRoot 'logs'
        PidPath = Join-Path $dataRoot 'proxy.pid'
        ProxyVersion = '8.0.48'
    }
}

function Protect-LauncherDataDirectory {
    [CmdletBinding()]
    param([object] $Paths = (Get-LauncherPaths))
    $null = [System.IO.Directory]::CreateDirectory($Paths.DataRoot)
    if (-not $IsWindows) { return }
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    # Load and persist only the DACL. A new descriptor or SetOwner can ask Windows
    # to write owner/audit sections and require privileges a normal user lacks.
    $directoryInfo = [System.IO.DirectoryInfo]::new($Paths.DataRoot)
    $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl(
        $directoryInfo, [System.Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
        $acl.RemoveAccessRuleSpecific($existingRule)
    }
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @($userSid, $systemSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $acl)
}

function Initialize-LauncherDataDirectory {
    [CmdletBinding()]
    param([object] $Paths = (Get-LauncherPaths))
    Protect-LauncherDataDirectory -Paths $Paths
    foreach ($directory in @($Paths.BinRoot, $Paths.AuthRoot, $Paths.LogsRoot)) {
        $null = [System.IO.Directory]::CreateDirectory($directory)
    }
}

function Write-LauncherJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Value
    )
    $destination = [System.IO.Path]::GetFullPath($Path)
    $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination))
    $temporary = $destination + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $destination, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Read-LauncherRuntime {
    [CmdletBinding()]
    param([object] $Paths = (Get-LauncherPaths), [switch] $Required)
    if (-not (Test-Path -LiteralPath $Paths.RuntimePath -PathType Leaf)) {
        if ($Required) { throw 'Launcher setup is incomplete. Run setup.cmd first.' }
        return $null
    }
    try {
        return Get-Content -LiteralPath $Paths.RuntimePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'The private runtime configuration is invalid. Repair it or rerun setup.cmd; credential contents were not printed.'
    }
}

function Write-LauncherRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Runtime, [object] $Paths = (Get-LauncherPaths))
    Write-LauncherJson -Path $Paths.RuntimePath -Value $Runtime
}

function Test-ClaudeCliCandidate {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ([System.IO.Path]::GetExtension($Path) -notin @('.exe', '.cmd', '.bat', '.ps1')) { return $false }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    # Desktop's Electron executable is not its embedded Claude Code executable.
    if ($fullPath -match '(?i)[\\/]claude-code[\\/][^\\/]+[\\/][^\\/]+[\\/]claude\.exe$') { return $true }
    if ($fullPath -match '(?i)[\\/]WindowsApps[\\/].*claude.*[\\/]claude\.exe$' -or
        $fullPath -match '(?i)[\\/](?:AnthropicClaude|Programs[\\/]Claude)[\\/](?:app-[^\\/]+[\\/])?claude\.exe$') { return $false }
    if ([System.IO.Path]::GetFileName($fullPath) -ieq 'claude.exe') {
        try {
            $description = (Get-Item -LiteralPath $fullPath -ErrorAction Stop).VersionInfo.FileDescription
            if ($description -match '(?i)^claude$|electron') { return $false }
        }
        catch { return $false }
    }
    return $true
}

function Resolve-ClaudeExecutable {
    [CmdletBinding()]
    param([string] $ClaudePath, [object] $Runtime, [object] $Paths = (Get-LauncherPaths))
    if (-not [string]::IsNullOrWhiteSpace($ClaudePath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ClaudePath)
        if ($expanded.StartsWith('~') -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $expanded = Join-Path $env:USERPROFILE $expanded.Substring(1).TrimStart([char[]] @('\', '/'))
        }
        if (-not (Test-ClaudeCliCandidate -Path $expanded)) {
            throw 'The supplied ClaudePath is not an available Claude Code CLI. Select the CLI executable, not the desktop app executable.'
        }
        return [System.IO.Path]::GetFullPath($expanded)
    }
    if ($null -eq $Runtime) { $Runtime = Read-LauncherRuntime -Paths $Paths }
    if ($null -ne $Runtime -and $null -ne $Runtime.PSObject.Properties['claudePath']) {
        $savedPath = [string] $Runtime.claudePath
        if (Test-ClaudeCliCandidate -Path $savedPath) { return [System.IO.Path]::GetFullPath($savedPath) }
    }
    $commands = @(Get-Command -Name claude, claude.exe, claude.cmd -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if (Test-ClaudeCliCandidate -Path $command.Source) { return [System.IO.Path]::GetFullPath($command.Source) }
    }
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        foreach ($name in @('claude.exe', 'claude.cmd')) { $candidates.Add((Join-Path $env:USERPROFILE ('.local\bin\' + $name))) }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { $candidates.Add((Join-Path $env:APPDATA 'npm\claude.cmd')) }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $desktopData = Join-Path $env:LOCALAPPDATA 'Claude-Data'
        if (Test-Path -LiteralPath $desktopData -PathType Container) {
            Get-ChildItem -Path (Join-Path $desktopData '*\claude-code\*\*\claude.exe') -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { $candidates.Add($_.FullName) }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-ClaudeCliCandidate -Path $candidate) { return [System.IO.Path]::GetFullPath($candidate) }
    }
    return $null
}
