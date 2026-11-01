#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $LegacyInstallRoot,
    [string] $StateRoot,
    [string] $DesktopHome,
    [string] $Project,
    [switch] $Status
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Console.ps1')
if (-not $IsWindows) { throw 'This console supports Windows and PowerShell 7.' }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try { [Console]::Title = 'Claude OpenAI 控制台' } catch { }
$consoleParameters = @{}
foreach ($name in @('LegacyInstallRoot','StateRoot','DesktopHome')) {
    $value = Get-Variable -Name $name -ValueOnly
    if (-not [string]::IsNullOrWhiteSpace($value)) { $consoleParameters[$name] = $value }
}
$script:context = Get-ConsoleContext @consoleParameters
if ($Status) { Get-ConsoleStatus -Context $script:context | ConvertTo-Json -Depth 8; return }

$script:preferences = [ordered]@{ project = (Get-Location).Path; model = 'gpt-6.1-sol'; effort = 'low' }
$preferencesPath = Join-Path $script:context.Paths.StateRoot 'console-preferences.json'
if (Test-Path -LiteralPath $preferencesPath -PathType Leaf) {
    try {
        $saved = Get-Content -LiteralPath $preferencesPath -Raw | ConvertFrom-Json
        foreach ($name in @('project','model','effort')) {
            if (-not [string]::IsNullOrWhiteSpace([string]$saved.$name)) { $script:preferences[$name] = [string]$saved.$name }
        }
    } catch { }
}
if ($Project) { $script:preferences.project = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Project.Trim('"'))) }

function Save-ConsolePreferences {
    Write-LauncherJson -Path $preferencesPath -Value $script:preferences
}

function Reset-ConsoleSelection {
    $models = @($script:context.Models)
    if (-not $models.Count) { return }
    $selected = @($models | Where-Object { $_.id -eq $script:preferences.model }) | Select-Object -First 1
    if (-not $selected) { $selected = $models[0]; $script:preferences.model = $selected.id }
    if (@($selected.reasoningLevels) -notcontains $script:preferences.effort) { $script:preferences.effort = $selected.defaultEffort }
}

function Get-ConsoleDesktopArguments {
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($name in @('LegacyInstallRoot','StateRoot','DesktopHome')) {
        if ($consoleParameters.ContainsKey($name)) { $arguments.Add('-' + $name); $arguments.Add([string]$consoleParameters[$name]) }
    }
    return ,$arguments.ToArray()
}

function Resolve-ConsoleActionScript {
    param([string] $Name)
    if ($script:context.Paths.IsLegacy -and $Name -in @('Start.ps1','Login.ps1')) {
        $candidate = Join-Path $script:context.Paths.DataRoot $Name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw '旧安装缺少所需启动脚本，请先修复安装。' }
        return $candidate
    }
    return Join-Path $PSScriptRoot $Name
}

function Invoke-ConsoleAction {
    param([string] $Name, [string[]] $Arguments = @(), [switch] $NewTerminal, [switch] $Administrator)
    $scriptPath = Resolve-ConsoleActionScript -Name $Name
    $shellPath = Join-Path $PSHOME 'pwsh.exe'
    $oldDataDirectory = [Environment]::GetEnvironmentVariable('CLAUDE_OPENAI_DATA_DIR','Process')
    try {
        [Environment]::SetEnvironmentVariable('CLAUDE_OPENAI_DATA_DIR', $script:context.Paths.DataRoot, 'Process')
        if ($NewTerminal -or $Administrator) {
            # ArgumentList performs native argument quoting. Project paths are
            # passed as data to -File, never interpolated into shell source.
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $shellPath
            $info.UseShellExecute = $true
            $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
            $info.WorkingDirectory = if (Test-Path -LiteralPath $script:preferences.project -PathType Container) { $script:preferences.project } else { $script:context.Paths.RepoRoot }
            if ($Administrator) { $info.Verb = 'runas' }
            foreach ($argument in @('-NoLogo','-NoProfile','-NoExit','-File',$scriptPath) + $Arguments) { [void]$info.ArgumentList.Add($argument) }
            $null = [Diagnostics.Process]::Start($info)
        }
        else {
            & $shellPath -NoLogo -NoProfile -File $scriptPath @Arguments
            if ($LASTEXITCODE -ne 0) { throw ('操作未完成，退出码：' + $LASTEXITCODE) }
        }
    }
    finally { [Environment]::SetEnvironmentVariable('CLAUDE_OPENAI_DATA_DIR', $oldDataDirectory, 'Process') }
}

function Show-ConsoleModels {
    $rows = @($script:context.Models | ForEach-Object {
        [pscustomobject]@{ '模型'=$_.label; '上下文'=$_.contextWindow; '输出预算'=$_.maxOutputTokens; '自动压缩'=$_.autoCompactWindow; '思考强度'=(@($_.reasoningLevels) -join ', ') }
    })
    if ($rows.Count) { $rows | Format-Table -AutoSize | Out-Host }
    else { Write-Host '尚无模型资料，请先完成安装和 OpenAI 登录。' -ForegroundColor Yellow }
}

function Select-ConsoleModel {
    $models = @($script:context.Models)
    if (-not $models.Count) { throw '尚无可选模型，请先登录并刷新模型资料。' }
    for ($index = 0; $index -lt $models.Count; $index++) { Write-Host ('  {0}. {1}' -f ($index + 1), $models[$index].label) }
    $inputValue = Read-Host '选择 CLI 模型（回车取消）'
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return }
    $number = 0
    if (-not [int]::TryParse($inputValue,[ref]$number) -or $number -lt 1 -or $number -gt $models.Count) { throw '请输入列表中的数字。' }
    $script:preferences.model = $models[$number - 1].id
    Reset-ConsoleSelection
    Save-ConsolePreferences
}

function Select-ConsoleEffort {
    $model = @($script:context.Models | Where-Object { $_.id -eq $script:preferences.model }) | Select-Object -First 1
    if (-not $model) { throw '请先选择可用模型。' }
    $levels = @($model.reasoningLevels)
    for ($index = 0; $index -lt $levels.Count; $index++) { Write-Host ('  {0}. {1}' -f ($index + 1), $levels[$index]) }
    $inputValue = Read-Host '选择 CLI 思考强度（回车取消）'
    if ([string]::IsNullOrWhiteSpace($inputValue)) { return }
    $number = 0
    if (-not [int]::TryParse($inputValue,[ref]$number) -or $number -lt 1 -or $number -gt $levels.Count) { throw '请输入列表中的数字。' }
    $script:preferences.effort = $levels[$number - 1]
    Save-ConsolePreferences
}

function Show-ConsoleActionError {
    param([string] $Message)
    $safe = [regex]::Replace($Message, '(?i)(Bearer\s+)[^\s"'']+', '$1[redacted]')
    $safe = [regex]::Replace($safe, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]')
    $safe = [regex]::Replace($safe, '(?i)(?:sk-[A-Za-z0-9_-]{12,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)', '[redacted]')
    if ($safe.Length -gt 600) { $safe = $safe.Substring(0,600) }
    Write-Host ('操作失败：' + $safe) -ForegroundColor Red
}

Reset-ConsoleSelection
$quit = $false
while (-not $quit) {
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
    Write-Host '  Claude OpenAI 控制台' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------------------------'
    try {
        $proxy = Get-ConsoleStatus -Context $script:context
        $stateLabel = switch ($proxy.State) { 'Ready' {'运行正常'} 'Stopped' {'已停止'} 'PortConflict' {'端口被占用'} default {'连接待修复'} }
        $color = if ($proxy.State -eq 'Ready') {'Green'} else {'Yellow'}
        Write-Host ('  代理：{0}    {1}' -f $stateLabel, $script:context.Endpoint) -ForegroundColor $color
        if (@($proxy.ProcessIds).Count) { Write-Host ('  进程：' + (@($proxy.ProcessIds) -join ', ')) }
        if ($proxy.State -ne 'Ready' -and $proxy.Message) { Write-Host ('  ' + $proxy.Message) -ForegroundColor Yellow }
    } catch { Show-ConsoleActionError -Message $_.Exception.Message }
    Write-Host ('  CLI 模型：{0}    思考强度：{1}' -f $script:preferences.model, $script:preferences.effort)
    Write-Host ('  项目：' + $script:preferences.project)
    Write-Host ''
    Write-Host '   1  启动代理                  2  停止代理'
    Write-Host '   3  重启代理                  4  打开 Claude App'
    Write-Host '   5  打开 Claude Code CLI      6  更换项目目录'
    Write-Host '   7  选择 CLI 模型             8  选择 CLI 思考强度'
    Write-Host '   9  查看模型和上下文配置      10  刷新模型并同步 App'
    Write-Host '  11  登录 / 重新授权 OpenAI    12  应用 App 上下文（管理员）'
    Write-Host '  13  打开日志目录             14  首次安装 / 修复安装'
    Write-Host '   0  退出控制台（代理继续运行）'
    Write-Host ''
    Write-Host '  App 的模型与强度在 App 自己的模型菜单中选择。' -ForegroundColor DarkGray
    $choice = Read-Host '输入数字，回车刷新状态'
    if ($null -eq $choice) { break }
    if ([string]::IsNullOrWhiteSpace($choice)) { continue }
    try {
        switch ($choice.Trim()) {
            '0' { $quit = $true }
            '1' { $null = Start-ConsoleProxy -Context $script:context; Write-Host '代理已启动。' -ForegroundColor Green }
            '2' { $null = Stop-ConsoleProxy -Context $script:context; Write-Host '代理已停止；App 和 CLI 的请求会暂停，选择 1 可恢复。' }
            '3' { $null = Stop-ConsoleProxy -Context $script:context; $null = Start-ConsoleProxy -Context $script:context; Write-Host '代理已重启。' -ForegroundColor Green }
            '4' { Invoke-ConsoleAction -Name 'Start-Desktop.ps1' -Arguments (Get-ConsoleDesktopArguments) }
            '5' {
                if (-not (Test-Path -LiteralPath $script:preferences.project -PathType Container)) { throw '项目目录不存在，请先选择 6 更换目录。' }
                Reset-ConsoleSelection
                $null = Start-ConsoleProxy -Context $script:context
                Invoke-ConsoleAction -Name 'Start.ps1' -Arguments @('-Project',$script:preferences.project,'-Model',$script:preferences.model,'-Effort',$script:preferences.effort) -NewTerminal
                Write-Host 'CLI 已在新终端打开。'
            }
            '6' {
                $inputPath = Read-Host '输入或拖入项目文件夹路径（回车取消）'
                if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
                    $expanded = [Environment]::ExpandEnvironmentVariables($inputPath.Trim().Trim('"'))
                    if (-not (Test-Path -LiteralPath $expanded -PathType Container)) { throw '该项目目录不存在。' }
                    $script:preferences.project = (Resolve-Path -LiteralPath $expanded).ProviderPath
                    Save-ConsolePreferences
                }
            }
            '7' { Select-ConsoleModel }
            '8' { Select-ConsoleEffort }
            '9' { Show-ConsoleModels }
            '10' {
                Invoke-ConsoleAction -Name 'Update-Models.ps1'
                Invoke-ConsoleAction -Name 'Configure-Desktop.ps1' -Arguments (Get-ConsoleDesktopArguments)
                $script:context = Get-ConsoleContext @consoleParameters
                Reset-ConsoleSelection
                Write-Host '模型资料和 App 配置已同步。App 完全退出并重开后生效；上下文限额若有变化，请选择 12。' -ForegroundColor Green
            }
            '11' { Invoke-ConsoleAction -Name 'Login.ps1' -NewTerminal; Write-Host '已在新终端打开授权流程；完成后回到这里选择 10 同步配置。' }
            '12' {
                # UAC does not reliably inherit temporary process environment.
                # This parameter selects ModelProfiles.json for both install layouts.
                $arguments = @('-LegacyInstallRoot',$script:context.Paths.DataRoot)
                Invoke-ConsoleAction -Name 'Apply-DesktopContext.ps1' -Arguments $arguments -Administrator
                Write-Host '已请求打开管理员终端，请在 Windows 提示中确认并查看该终端的结果。'
            }
            '13' {
                if (-not (Test-Path -LiteralPath $script:context.Paths.LogsRoot -PathType Container)) { throw '日志目录尚未建立，请先启动代理。' }
                $null = Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $script:context.Paths.LogsRoot) -PassThru
            }
            '14' {
                if ($script:context.Paths.IsLegacy) { throw '当前使用旧安装。为避免覆盖现用授权，请在另一份源码目录按 README 执行 setup.cmd。' }
                Invoke-ConsoleAction -Name 'Setup.ps1'
                $script:context = Get-ConsoleContext @consoleParameters
                Write-Host '安装完成。接下来选择 11 登录，再选择 10 同步 App。'
            }
            default { Write-Host '请输入菜单中的数字。' -ForegroundColor Yellow }
        }
    } catch { Show-ConsoleActionError -Message $_.Exception.Message }
    if (-not $quit) { $null = Read-Host '按回车返回菜单' }
}
Write-Host '控制台已退出，代理和现有 App / CLI 会话继续运行。'
