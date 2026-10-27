# gemini-claudeCLIproxy

一个用于 Windows 的 CLIProxyAPI 本机启动与账号管理面板，使用 PowerShell 和 Windows Forms 实现。通过图形界面启动代理、打开 Antigravity 授权、切换账号，并查看 Claude / Gemini 的额度和用量。

本仓库提供助手脚本；运行前需要自行准备 CLIProxyAPI 程序及配置。

## 功能

- 启动、停止本机 CLIProxyAPI 服务，检查配置、端口与进程状态。
- 打开 Antigravity 登录授权，观察本地授权文件更新。
- 在本地授权账号间切换，或暂停全部账号；默认采用单账号模式。
- 查看当前账号的请求次数、成功率、平均延迟及 Token 用量。
- 手动查询额度，并在服务和账号就绪时每 10 分钟自动刷新。
- 分别开启 Claude / Gemini 额度耗尽后的自动切号，两个开关默认关闭。
- 展示 Gemini 4 Argon 的额度或可用状态；上游没有返回额度时显示状态文字。

账号状态依据本地授权文件和代理管理接口。面板中的可用状态不代表上游授权一定有效，也不能证明某次请求使用了哪个账号。

## 环境与准备

- Windows 桌面环境，能够使用 Windows Forms。
- Windows PowerShell 5.1（启动器默认调用 `powershell.exe`）。
- CLIProxyAPI Windows amd64 程序及可用的 `config.yaml`。

目前脚本默认使用以下目录：

```text
%USERPROFILE%\Downloads\CLIProxyAPI_7.3.17_windows_amd64\
├── cli-proxy-api.exe
└── config.yaml
```

默认账号目录为 `%USERPROFILE%\.cli-proxy-api`。主面板会读取 `config.yaml` 的 `auth-dir`，额度查询脚本目前仍使用这个默认账号目录。

如果安装目录不同，请同步修改以下文件中的 `Downloads\CLIProxyAPI_7.3.17_windows_amd64`；若使用自定义账号目录，还需调整 `CLIProxyAPI-Metrics.ps1` 中的账号读取路径：

- `启动CLIProxyAPI助手.cmd`
- `CLIProxyAPI-Helper.ps1`
- `CLIProxyAPI-Metrics.ps1`
- `配置用量监控.ps1`

## 使用

```powershell
git clone https://github.com/bakrilivas-boop/gemini-claudeCLIproxy.git
cd gemini-claudeCLIproxy
```

准备好上述程序与配置后，双击 `启动CLIProxyAPI助手.cmd` 打开面板。

1. 点击“启动服务”；需要添加账号时点击“打开授权”，在浏览器中完成登录。
2. 展开“切换账号”，选择账号后点击“只用选中账号”。
3. 配置用量监控后，可查看用量并点击“查询额度”。
4. 按需开启 Claude / Gemini 的“耗尽自动切号”。只有解析出的剩余额度确实为零时才触发；查询失败、未知状态及四舍五入显示为零都不会触发切号。

也可以在命令行调用启动器：

```powershell
# 仅启动服务
& '.\启动CLIProxyAPI助手.cmd' --service

# 打开 Antigravity 授权流程
& '.\启动CLIProxyAPI助手.cmd' --login
```

## 配置用量监控

在项目目录执行：

```powershell
powershell.exe -NoLogo -NoProfile -File '.\配置用量监控.ps1'
```

配置脚本要求 `config.yaml` 中存在唯一的 `secret-key` 条目和 `usage-statistics-enabled` 条目。首次配置会生成随机管理密钥、开启用量统计，并备份原配置；完成后需重启 CLIProxyAPI。

管理密钥通过 Windows DPAPI 绑定当前 Windows 用户，保存到项目目录的 `管理密钥.dat`。如果已有管理密钥而缺少对应的本地密钥文件，脚本会停止，避免覆盖已有配置。

运行时会生成 `面板状态.json`、`面板用量.json` 和 `面板额度.json`。这些文件可能包含账号信息，已通过 `.gitignore` 排除；管理密钥、本地配置、修复备份及本地截图也不会进入版本库。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `启动CLIProxyAPI助手.cmd` | 图形面板、服务及授权流程入口 |
| `CLIProxyAPI-Helper.ps1` | 主面板、服务检查和账号切换 |
| `CLIProxyAPI-Metrics.ps1` | 用量采集、额度查询与解析 |
| `配置用量监控.ps1` | 配置管理密钥和用量统计 |
| `Test-AccountSwitch.ps1` | 账号切换与额度自动切号回归测试 |
| `Test-Metrics.ps1` | 用量汇总和额度解析回归测试 |
| `Test-PanelLayout.ps1` | Windows Forms 布局与交互测试 |

## 验证

在 Windows 桌面环境、新克隆且未放入个人运行状态的目录中执行：

```powershell
powershell.exe -NoLogo -NoProfile -File '.\Test-AccountSwitch.ps1'
powershell.exe -NoLogo -NoProfile -File '.\Test-Metrics.ps1'
powershell.exe -NoLogo -NoProfile -STA -File '.\Test-PanelLayout.ps1'
```

账号切换和额度测试使用测试账号及模拟返回值；布局测试需要可用的 Windows 桌面。额度查询依赖上游接口，其可用性取决于代理版本、网络和账号状态。
