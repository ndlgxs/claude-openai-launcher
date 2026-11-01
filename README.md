# Claude OpenAI Launcher（Windows）

在 Claude Code 命令行或 Claude 桌面 App 中使用自己 OpenAI 账号可用的模型。启动器通过本机 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 转换请求：

```text
Claude Code / Claude App → 本机 CLIProxyAPI → 自己的 OpenAI 授权
```

Claude 客户端负责工具、文件操作、权限审批和上下文管理；OpenAI 模型负责推理和选择工具。本项目是社区适配，不由 OpenAI 或 Anthropic 提供支持。工具及思考显示可能与两家的原生客户端不同。

仓库只包含启动脚本、配置模板和离线测试，不分发 Claude Code、代理二进制或任何账号凭据。

## 运行条件

- Windows 10 / 11，x64 或 ARM64。本项目不覆盖 macOS、Linux 和 WSL。
- PowerShell 7 或更新版本，命令为 `pwsh`；Windows PowerShell 5.1 不满足要求。
- 使用命令行时，本机已安装 Claude Code，或已有可被发现的桌面 App 内置 CLI；使用 App 时，另行安装最新 [Claude Desktop](https://claude.com/download)。
- 自己的 OpenAI 账号，以及可用于相关模型的 ChatGPT / Codex 订阅或计划授权。可用模型与限额以账号实际返回为准。

可先按官方方式安装依赖，再重新打开终端：

```powershell
winget install --id Microsoft.PowerShell --source winget
winget install Anthropic.ClaudeCode
pwsh --version
claude --version
```

来源：[PowerShell 官方安装说明](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)、[Claude Code 官方安装说明](https://code.claude.com/docs/en/setup)。Git for Windows 可提供 Bash 工具；没有 Git for Windows 时，新版 Claude Code 可使用 PowerShell 工具。

这套网关入口使用自己的 OpenAI 授权，不要求另购 Claude 订阅。命令行使用本机网关凭据；App 使用官方第三方推理模式，可在登录页选择不使用 Claude 账号。直接运行普通 `claude` 或标准 Claude App 仍遵循原来的登录配置。[CLI 网关说明](https://code.claude.com/docs/en/llm-gateway-connect)、[App 第三方推理模式](https://claude.com/docs/third-party/claude-desktop/overview)

## 先完成本机安装和自己的账号登录

下载本仓库源码或克隆到本机。在仓库目录打开 PowerShell 7，依次执行：

```powershell
.\setup.cmd
.\login.cmd
.\start.cmd -Project "D:\Projects\My App"
```

1. `setup.cmd` 下载固定版本 **CLIProxyAPI 8.0.48**，按当前 x64 / ARM64 架构选择上游发布包，并使用同一发布版本的 SHA-256 校验文件验证。它会发现本机 Claude Code 路径并建立独立数据目录。
2. `login.cmd` 打开 OpenAI 浏览器登录流程，再完成 ChatGPT 计划使用授权。登录由你本人完成；不要把密码、回调令牌或凭据文件贴到聊天、Issue 或仓库里。
3. `start.cmd` 启动仅监听本机地址的代理和 Claude Code，并显示当前账号可用的模型选择菜单。

如果 Claude Code 未在常见位置或 PATH 中，可以显式指定：

```powershell
.\setup.cmd -ClaudePath "D:\Apps\Claude Code\claude.exe"
```

如果本机 8317 端口已被其他程序占用，可在设置时改端口：

```powershell
.\setup.cmd -Port 18317
```

这些脚本不复制已有 `.codex/auth.json`。每台电脑都需要分别安装依赖、执行设置并登录自己的 OpenAI 账号。不能把一台电脑的授权或模型限额复制给另一台电脑。

## 项目路径、模型和思考强度

也可以双击仓库根目录的 `console.cmd`，使用中文数字菜单管理代理和启动入口。控制台显示当前连接状态、所选项目、CLI 模型和思考强度，提供代理启动 / 停止 / 重启、打开 App、打开独立 CLI 终端、模型资料刷新、OpenAI 登录及管理员上下文配置入口。选择 `0` 退出控制台后，代理继续运行；停止代理使用菜单 `2`。

菜单 `6` 更换项目目录，`7` 选择 CLI 模型，`8` 选择思考强度，随后选择 `5` 打开该项目。App 的模型和强度仍在 App 的模型菜单中选择。控制台不展示账号密钥，不会自动执行模型测试；首次使用仍需按上节安装依赖并登录自己的账号。

打开 App 时，控制台只显示简短的启动结果。App 的标准输出和错误日志保存在本机私有日志目录的 `app-*.out.log`、`app-*.err.log` 中，菜单 `13` 可打开日志目录。更新这个启动行为后，已在运行的 App 需完全退出并重新打开一次。

```powershell
.\console.cmd -Project "D:\Projects\My App"
# 只读取连接状态，不进入菜单、不发送模型请求：
.\console.cmd -Status
```

沿用旧安装时可指定本机路径（`StateRoot` 是之前桌面配置使用的私有状态目录）：

```powershell
.\console.cmd -LegacyInstallRoot "D:\Private\Old Claude OpenAI" -StateRoot "$env:LOCALAPPDATA\ClaudeOpenAI\desktop"
```

启动时明确传项目目录，可使用带空格的路径；也可以把项目文件夹拖到 `start.cmd` 上。没有指定项目时，使用启动命令所在的当前目录。

```powershell
.\start.cmd -Project "D:\Projects\My App" -Model astra
.\start.cmd -Project "D:\Projects\My App" -Model sol
.\start.cmd -Project "D:\Projects\My App" -Model terra
.\start.cmd -Project "D:\Projects\My App" -Model luna
```

| 简写 | 模型 ID |
|---|---|
| `astra` | `gpt-6-astra` |
| `sol` | `gpt-6.1-sol` |
| `terra` | `gpt-6.1-terra` |
| `luna` | `gpt-6-luna` |

菜单只显示账号元数据中可用且本项目支持的模型。指定完整模型 ID 也可以；不支持的 ID 会明确报错。

可独立指定思考强度，也兼容 Claude 风格的 `--effort` 参数：

```powershell
.\start.cmd -Project "D:\Projects\My App" -Model astra -Effort high
.\start.cmd -Model sol --effort xhigh
```

CLI 模型菜单保留四个模型，强度单独设置。在运行中的命令行会话里，也可以用 `/effort high` 等原生命令改档。旧的模型名后缀写法仍受支持：

```powershell
.\start.cmd -Project "D:\Projects\My App" -Model "astra(high)"
```

只能使用所选模型声明支持的档位。CLI 启动器将参数和旧后缀统一为原始模型 ID 加原生 `--effort`，保留会话内 `/effort` 调档能力；固定后缀不会一直压过后续选择。同一次启动不要给出互相冲突的强度。这些档位最终对应 OpenAI 的推理参数，不代表 Claude 模型的思考机制。[CLI 强度设置](https://code.claude.com/docs/en/model-config#adjust-effort-level)

## Claude 桌面 App

先完成上面的 `setup.cmd` 和 `login.cmd`，再执行：

```powershell
.\configure-desktop.cmd -Preview
.\configure-desktop.cmd
```

配置脚本为这台电脑生成本地第三方推理配置，使用本机代理和真实 GPT 显示名；不修改 App 二进制。预览不会写入配置。App 的第三方推理配置与 CLI 的环境变量、`settings.json` 是两套入口。[官方配置说明](https://claude.com/docs/third-party/claude-desktop/in-app-configuration)

要让 Chat、Cowork 和 Code 使用账号资料中的精确上下文窗口，在**以管理员身份打开的 PowerShell 7** 中进入仓库目录，再执行：

```powershell
.\apply-desktop-context.cmd -WhatIf
.\apply-desktop-context.cmd
```

该步骤从本机 `ModelProfiles.json` 读取共同上下文、输出预算和压缩窗口，合并到 `%ProgramFiles%\ClaudeCode\managed-settings.json`，并保留可校验的备份。它影响机器上的所有适用 Claude Code 会话；不会只局限于四个 GPT 模型。脚本保留原来的权限规则，并用 `parentSettingsBehavior: "merge"` 保留桌面宿主的策略。它不自动提权、不安装软件、不更改执行策略。[策略合并说明](https://claude.com/docs/third-party/claude-desktop/code#interaction-with-claude-codes-own-managed-settings)

完全退出 Claude App，再回到普通 PowerShell 7 启动：

```powershell
.\start-desktop.cmd
```

首次进入第三方模式时，在登录页选择使用已配置的第三方推理入口，无需 Claude 账号。日常启动不需要管理员权限。账号或模型限额变化后，重新刷新模型资料、配置 App、应用管理员上下文，然后完全退出并重新启动 App。

App 在模型菜单中提供“模型＋强度”组合，例如 **GPT-6.1 Sol - high**。当前四模型各声明五档时共有 20 项：`low / medium / high / xhigh / max`；实际选项以自己的账号资料为准。这是模型菜单中的显式选项，**不是 App 原生 Effort 滑块**。我们不使用 `behavesAs` 把 GPT 套成某个 Claude 型号，也不把实际窗口冒充为 1M。[官方模型与强度规则](https://claude.com/docs/third-party/claude-desktop/models)

如需使用同一台电脑已有的旧安装目录，桌面两个入口和管理员上下文脚本均可传入同一个参数：

```powershell
.\configure-desktop.cmd -LegacyInstallRoot "D:\Private\Old Claude OpenAI"
.\apply-desktop-context.cmd -LegacyInstallRoot "D:\Private\Old Claude OpenAI"
.\start-desktop.cmd -LegacyInstallRoot "D:\Private\Old Claude OpenAI"
```

这只用于访问自己原有的本机安装，不应把旧安装目录随源码分享。高级用法可同时提供 `-Context`、`-Output`、`-Compact` 三个限额覆盖自动读取；只给一项或两项会被拒绝，压缩窗口还必须为输出和保留空间留出余量。

应用上下文后的结果会打印备份 `manifest.json` 的完整路径。在管理员 PowerShell 7 中回滚：

```powershell
.\apply-desktop-context.cmd -RestoreBackup "D:\Private\ClaudeOpenAI\desktop-backups\备份目录\manifest.json"
```

使用脚本实际打印的路径。回滚会检查当前文件和备份的 SHA-256；若管理员后来修改了策略，会拒绝覆盖。备份留在本机数据目录，不能上传仓库。

## 模型与上下文元数据

登录和刷新时，从当前账号获取模型元数据，生成该机器自己的 `ModelProfiles.json` 与 Claude 会话配置。窗口不是固定写成某个账号的 872K；不同账号可以得到不同结果，缺少必要字段时会停止并提示。

会话内可切换的模型使用共同安全窗口：取当前可用模型上限的最小值，并为输出与上下文压缩保留空间。启动时会显示实际配置。这里的账号元数据和客户端设置不等于对最大长度请求的实测承诺；本项目没有做长上下文压力测试。

输出预算也不是模型每次一定生成的长度。部分 SDK 结果中的 `modelUsage.maxOutputTokens` 报告默认值，不能单靠这个值判断实际请求预算；订阅推理端还可能采用自己的输出规则。

订阅、权限或模型信息变化后，手动刷新：

```powershell
.\update-models.cmd
```

如果刷新提示授权失效，重新运行 `login.cmd`。代理模型列表里的名称本身不证明账号的实际调用权限。

## 停止与数据位置

```powershell
.\stop.cmd
```

停止脚本只终止 PID 及可执行路径都与本项目代理一致的进程；不会按进程名批量结束其他代理。

运行数据默认放在：

```text
%LOCALAPPDATA%\ClaudeOpenAI
```

其中包括下载的二进制、代理配置、本机访问密钥、OpenAI 授权、日志、进程记录和账号模型资料。需要自定义位置时，在同一个终端先设置环境变量，然后再执行各入口：

```powershell
$env:CLAUDE_OPENAI_DATA_DIR = "D:\Private App Data\ClaudeOpenAI"
.\setup.cmd
.\login.cmd
.\start.cmd -Project "D:\Projects\My App"
```

不要把这个数据目录放到公开仓库或同步给其他人。分享本项目只需分享源码；不要上传最初调试时的整个 `work` 文件夹或任何旧凭据。

## 脚本执行提示

使用 PowerShell 7 正常运行入口即可。下载的 ZIP 可能保留 Windows 下载标记；在核对仓库来源与脚本内容后，可只对本仓库的脚本解除文件下载标记：

```powershell
Get-ChildItem .\scripts -Filter *.ps1 | Unblock-File
```

如果组织策略或签名要求仍阻止运行，请让管理员批准或签名这些脚本。不要永久关闭执行策略，也不要尝试覆盖组织策略。日常安装、登录和启动不要求管理员权限；只有明确应用或回滚机器级上下文的步骤需要管理员权限。工具仍遵循 Claude 客户端的权限审批。

## 离线检查

```powershell
pwsh -NoProfile -File .\tests\Test-Offline.ps1
pwsh -NoProfile -File .\tests\Test-DesktopOffline.ps1
```

测试使用临时空白数据目录和合成资料，覆盖脚本语法、校验安装、带空格的路径、不同账号窗口计算、缺失元数据拒绝、CLI 参数与桌面配置生成。不登录、不调用模型、不启动代理，也不修改真实 App 或机器策略。GitHub Actions 在 Windows 上执行这两套检查。

`tests/verify-effort.mjs` 是单独的协议检查：需要先下载并校验真实代理二进制，会临时启动随机本机端口的代理和模拟上游，默认不访问真实模型。它不属于纯离线 CI 流程，可手动运行：

```powershell
. .\scripts\Common.ps1
$launcherPaths = Get-LauncherPaths
node .\tests\verify-effort.mjs --proxy-binary $launcherPaths.BinaryPath --output-dir (Join-Path $launcherPaths.DataRoot 'effort-check')
```

只有显式提供 `--live-runtime` 时才会使用真实账号发送短请求，详见测试脚本参数。

已有本机验证确认 App 可通过第三方网关进入，无需 Claude 账号；Code 中 Sol、Astra 的短对话与文件读写已通过。其余模型的完整 App 验收及 Chat、Cowork 模式尚未全部完成。离线检查通过不代表 App 的所有功能已通过，也不代表最大上下文或最大输出长度经过了实测。

## 许可与上游项目

本仓库自有脚本使用 [MIT License](LICENSE)。Claude Code、CLIProxyAPI 及相关服务分别遵循其自己的许可和条款，见 [第三方声明](THIRD_PARTY_NOTICES.md)。
