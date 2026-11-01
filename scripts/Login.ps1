#Requires -Version 7.0
[CmdletBinding()]
param([switch] $NoBrowser)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Invoke-ProxyAuthorization {
    param([string[]] $Arguments)
    $lines = [System.Collections.Generic.List[string]]::new()
    & $paths.BinaryPath @Arguments | ForEach-Object {
        $line = [string] $_
        $lines.Add($line)
        Write-Host $line
    }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines.ToArray() }
}

try {
    if (-not $IsWindows) { throw 'This launcher supports Windows. Run it from PowerShell 7 on Windows.' }
    $paths = Get-LauncherPaths
    $runtime = Read-LauncherRuntime -Paths $paths -Required
    foreach ($requiredFile in @($paths.BinaryPath, $paths.ConfigPath)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw 'The proxy is not installed. Run setup.cmd first.' }
    }
    Initialize-LauncherDataDirectory -Paths $paths
    $loginArguments = @('--config', $paths.ConfigPath, '--codex-login')
    if ($NoBrowser) { $loginArguments += '--no-browser' }
    Write-Host 'Sign in with your own ChatGPT account. Credentials stay in the private launcher data directory.'
    $loginResult = Invoke-ProxyAuthorization -Arguments $loginArguments
    $savedCredential = $null
    foreach ($line in $loginResult.Lines) {
        if ($line -match '^Authentication saved to (.+)$') { $savedCredential = $Matches[1].Trim() }
    }
    if ($loginResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($savedCredential)) {
        throw 'Codex authorization did not finish successfully. Retry login.cmd after reviewing the browser message.'
    }
    $credentialPath = [System.IO.Path]::GetFullPath($savedCredential)
    $authPrefix = [System.IO.Path]::GetFullPath($paths.AuthRoot).TrimEnd([char[]] @('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $credentialPath.StartsWith($authPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The authorization result points outside the private launcher authentication directory.'
    }
    $credentialFile = Get-Item -LiteralPath $credentialPath -ErrorAction Stop
    if ($credentialFile.PSIsContainer -or ($credentialFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'The authorization credential must be a regular local file.'
    }
    try { $credential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json }
    catch { throw 'The saved Codex credential is unreadable or invalid. Its contents were not printed.' }
    if ($credential.type -ne 'codex' -or [string]::IsNullOrWhiteSpace([string] $credential.access_token) -or [string]::IsNullOrWhiteSpace([string] $credential.refresh_token)) {
        throw 'The authorization did not create a complete Codex credential.'
    }
    $credential = $null
    $bindArguments = @('--config', $paths.ConfigPath, '--siwc-bind', $credentialFile.Name)
    if ($NoBrowser) { $bindArguments += '--no-browser' }
    Write-Host 'Complete the second Sign in with ChatGPT authorization for the OpenAI API route.'
    $bindResult = Invoke-ProxyAuthorization -Arguments $bindArguments
    $bindingSucceeded = @($bindResult.Lines | Where-Object { $_ -eq 'Sign in with ChatGPT authentication successful!' }).Count -gt 0
    if ($bindResult.ExitCode -ne 0 -or -not $bindingSucceeded) { throw 'Sign in with ChatGPT authorization did not finish successfully. Run login.cmd again.' }
    try { $boundCredential = Get-Content -LiteralPath $credentialPath -Raw | ConvertFrom-Json }
    catch { throw 'The saved Sign in with ChatGPT credential is unreadable or invalid. Its contents were not printed.' }
    if ($boundCredential.use_siwc -ne $true -or [string]::IsNullOrWhiteSpace([string] $boundCredential.siwc.access_token)) {
        throw 'Sign in with ChatGPT credentials were not saved. Run login.cmd again.'
    }
    $boundCredential = $null
    Write-Host 'Authorization complete. Refreshing the model profiles for this account.'
    & (Join-Path $PSScriptRoot 'Update-Models.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Authorization succeeded, but model profile refresh failed. Run scripts\Update-Models.ps1 again.' }
    Write-Host 'Ready. Run start.cmd from the project directory you want Claude Code to use.'
    exit 0
}
catch {
    Write-Host ([string] $_.Exception.Message) -ForegroundColor Red
    exit 1
}
