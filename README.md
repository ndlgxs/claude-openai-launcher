# Claude OpenAI Launcher（Windows）

在 Claude Code 命令行中使用自己 OpenAI 账号可用的模型。启动器通过本机 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) 转换请求：

```text
Claude Code → 127.0.0.1 上的 CLIProxyAPI → OpenAI / ChatGPT 订阅授权
```

Claude Code 负责工具、文件操作、权限审批和上下文管理；OpenAI 模型负责推理和选择工具。本项目是社区适配，不由 OpenAI 或 Anthropic 提供支持。工具及思考显示可能与两家的原生客户端不同。

仓库只包含启动脚本、配置模板和离线测试，不分发 Claude Code、代理二进制或任何账号凭据。

## 运行条件

- Windows 10 / 11，x64 或 ARM64。本项目不覆盖 macOS、Linux、WSL 和 Claude 桌面版 Code 标签。
- PowerShell 7 或更新版本，命令为 `pwsh`；Windows PowerShell 5.1 不满足要求。
- 本机已安装 Claude Code。
- 自己的 OpenAI 账号，以及可用于相关模型的 ChatGPT / Codex 订阅或计划授权。可用模型与限额以账号实际返回为准。

可先按官方方式安装依赖，再重新打开终端：

```powershell
winget install --id Microsoft.PowerShell --source winget
winget install Anthropic.ClaudeCode
pwsh --version
claude --version
```

来源：[PowerShell 官方安装说明](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)、[Claude Code 官方安装说明](https://code.claude.com/docs/en/setup)。Git for Windows 可提供 Bash 工具；没有 Git for Windows 时，新版 Claude Code 可使用 PowerShell 工具。

这套网关入口使用 OpenAI 授权，不要求另购 Claude 订阅或登录 Claude 账号；直接运行普通 `claude` 仍遵循它自己的登录配置。[Claude Code 网关凭据说明](https://code.claude.com/docs/en/llm-gateway-connect)

## 第一次使用

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

这些脚本不复制已有 `.codex/auth.json`。每台电脑都需要分别安装依赖、执行设置并登录自己的 OpenAI 账号。

## 项目路径、模型和思考强度

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

CLIProxyAPI 支持通过模型名后缀转换推理强度，例如：

```powershell
.\start.cmd -Project "D:\Projects\My App" -Model "astra(high)"
```

只能使用所选模型声明支持的档位。后缀会转换为 OpenAI 的推理参数，不代表 Claude 模型的思考机制。[代理参数说明](https://help.router-for.me/configuration/thinking)

## 模型与上下文元数据

登录和刷新时，从当前账号获取模型元数据，生成该机器自己的 `ModelProfiles.json` 与 Claude 会话配置。窗口不是固定写成某个账号的 872K；不同账号可以得到不同结果，缺少必要字段时会停止并提示。

会话内可切换的模型使用共同安全窗口：取当前可用模型上限的最小值，并为输出与上下文压缩保留空间。启动时会显示实际配置。这里的账号元数据和客户端设置不等于对最大长度请求的实测承诺。

订阅、权限或模型信息变化后，手动刷新：

```powershell
pwsh -NoProfile -File .\scripts\Update-Models.ps1
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

如果组织策略或签名要求仍阻止运行，请让管理员批准或签名这些脚本。不要永久关闭执行策略，也不要尝试覆盖组织策略。本项目不要求管理员权限或关闭 Claude Code 的工具权限审批。

## 离线检查

```powershell
pwsh -NoProfile -File .\tests\Test-Offline.ps1
```

测试使用临时空白数据目录、合成模型目录和不执行的模拟二进制文件，覆盖脚本语法、本地校验安装、带空格的路径、不同账号窗口计算、缺失元数据拒绝和启动参数解析。不登录、不调用模型，也不启动代理。GitHub Actions 在 Windows 上执行相同检查。

## 许可与上游项目

本仓库自有脚本使用 [MIT License](LICENSE)。Claude Code、CLIProxyAPI 及相关服务分别遵循其自己的许可和条款，见 [第三方声明](THIRD_PARTY_NOTICES.md)。
