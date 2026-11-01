#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    if (-not $IsWindows) { throw 'This launcher supports Windows. Run it from PowerShell 7 on Windows.' }
    $paths = Get-LauncherPaths
    if (-not (Test-Path -LiteralPath $paths.PidPath -PathType Leaf)) {
        Write-Host 'No proxy process is recorded.'
        exit 0
    }
    $proxyProcessId = 0
    if (-not [int]::TryParse((Get-Content -LiteralPath $paths.PidPath -Raw).Trim(), [ref] $proxyProcessId) -or $proxyProcessId -le 0) {
        throw 'The proxy PID file is invalid. No process was stopped.'
    }
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $proxyProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        Remove-Item -LiteralPath $paths.PidPath -Force
        Write-Host 'The recorded proxy has already stopped.'
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) { throw 'The recorded process path cannot be verified. No process was stopped.' }
    $actualPath = [System.IO.Path]::GetFullPath([string] $process.ExecutablePath)
    $expectedPath = [System.IO.Path]::GetFullPath($paths.BinaryPath)
    if (-not [string]::Equals($actualPath, $expectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The recorded PID belongs to a different executable. No process was stopped.'
    }
    $result = Invoke-CimMethod -InputObject $process -MethodName Terminate
    if ($result.ReturnValue -ne 0) { throw ('The proxy could not be stopped. Windows result: ' + $result.ReturnValue) }
    Remove-Item -LiteralPath $paths.PidPath -Force
    Write-Host 'The local OpenAI proxy has stopped.'
    exit 0
}
catch {
    Write-Host ([string] $_.Exception.Message) -ForegroundColor Red
    exit 1
}
