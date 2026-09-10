# Codex 跨供应商会话桥接器

[简体中文](README.md) | [English](README.en.md)

> [!IMPORTANT]
> 这个项目主要解决一个具体问题：**Codex 通过 CC Switch 从第三方 Provider 切回 OpenAI Official 后，旧会话消失，或虽然能看到但无法继续聊天。**

> [!WARNING]
> 这是一个实验性的非官方兼容层。Codex、CC Switch 或上游 API 更新后，可能需要继续适配。

## 30 秒看懂

Codex 的本地历史不只有聊天文字，还可能包含 Provider 生成的 item ID、加密 reasoning、`previous_response_id`、旧模型名等状态。这些状态在原 Provider 可用，切到另一个 Provider 后不一定能继续复用。

本项目在 Codex 与 CC Switch 之间增加一个本地 Bridge：

```text
Codex CLI / IDE
      ↓
127.0.0.1:15722   Bridge
      ↓
127.0.0.1:15721   CC Switch
      ↓
OpenAI Official / Provider
```

它主要做三件事：

- **让历史会话保持可见**：官方路线启用桥接时，管理器使用统一的 `model_provider = "custom"` 桶；
- **让旧会话可以继续**：发请求前清理不能跨 Provider 复用的状态；
- **处理旧模型名残留**：必要时把旧会话发出的顶层 `model` 改成当前官方模型。

桥接器**不会修改 `.codex/sessions`、Codex SQLite 数据库或 `.codex/auth.json`**，只处理即将发出的请求副本。

### 典型症状


| 现象                                                  | 常见原因                                                          |
| ------------------------------------------------------- | ------------------------------------------------------------------- |
| 三方切回官方后，旧会话看不到                          | 会话被归入不同的`model_provider` 桶                               |
| 会话能看到，但一发送消息就报错                        | 历史中仍包含原 Provider 的私有状态                                |
| `Expected an ID that begins with 'msg'`               | 原 Provider 的 item ID 被发送到另一套 ID 格式的服务端             |
| `Encrypted content could not be decrypted or parsed`  | 加密 reasoning 无法被新 Provider 验证                             |
| `Invalid input[…].content: array too long`           | reasoning item 结构不兼容                                         |
| `The '<third-party-model>' model is not supported...` | 旧会话重放仍携带三方模型名                                        |
| `RESPONSES_MODEL_NOT_SUPPORTED`                       | 当前端点/模型本身不支持 Responses；这不是 Bridge 能修复的协议问题 |

---

## 快速开始

### 环境要求

- Python 3.10+
- Windows PowerShell 5.1 / PowerShell 7，或 Linux/macOS/WSL Bash
- Codex 使用 Responses wire API
- CC Switch 本地 Codex 路由正在运行，通常是 `http://127.0.0.1:15721`
- `codex_provider_bridge.py` 与对应的 manager 脚本放在同一目录

> [!NOTE]
> Windows CMD 不能直接执行 `.ps1`，所以下面的 CMD 命令通过 `powershell.exe -File` 调用管理脚本。

### 1. 三方 → OpenAI Official（主要使用场景）

1. 在 **CC Switch** 中登录并选择 **OpenAI Official**。
2. 如果切换后本地路由没有同步，先重启 CC Switch。
3. 在项目目录运行 `auto`。

**Windows CMD**

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto
```

**Windows PowerShell**

```powershell
.\codex_bridge_manager.ps1 auto
```

**Linux / macOS / WSL**

```bash
chmod +x ./codex_bridge_manager.sh  # 仅首次需要
./codex_bridge_manager.sh auto
```

4. **保持 Bridge 进程运行**，重新加载 VS Code/Codex，然后选择官方路线的模型。
5. 打开原来的三方会话继续聊天。

如果旧会话仍带着三方模型名，例如 `glm-5.3-flash`，请显式指定你账号实际可用的官方模型：

**Windows CMD**

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -Model gpt-5.6-sol
```

**Windows PowerShell**

```powershell
.\codex_bridge_manager.ps1 auto -Model gpt-5.6-sol
```

**Linux / macOS / WSL**

```bash
./codex_bridge_manager.sh auto --model gpt-5.6-sol
```

> [!TIP]
> `gpt-5.6-sol` 只是示例。请替换成 OpenAI Official 路线中你的账号实际可用的模型。若 `config.toml` 顶层已经有 `gpt-*`、`o*` 或 `codex*` 形式的官方模型名，manager 通常会自动复用，不需要额外传 `-Model` / `--model`。

### 2. OpenAI Official → 三方

1. 在 CC Switch 中选择目标三方 Provider。
2. **无条件重启 CC Switch。** 即使 `config.toml` 已经显示新的三方 `base_url`，也不要省略这一步；运行时路由缓存可能仍然指向旧节点。
3. 确认 `config.toml` 不再指向本地 Bridge 端口（例如 `127.0.0.1:15722` / `15723`）。
4. 如果 Bridge 是前台窗口或 VS Code Task 启动的，直接关闭/终止它；如果你主动使用了后台模式，再执行 `stop`。
5. 在 Codex 中选择三方模型。

后台模式停止命令：

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" stop
```

```powershell
.\codex_bridge_manager.ps1 stop
```

```bash
./codex_bridge_manager.sh stop
```

> [!IMPORTANT]
> manager **不会替你切换 CC Switch Provider，也不会自动重启 CC Switch**。特别是 **Official → 三方**，每次切换后都要手动重启 CC Switch。

---

## 推荐：VS Code 自动启动

如果不想每次三方 → 官方都手动执行 `auto`，可以使用仓库中的 VS Code Task 模板。

### Windows

1. 将 `vscode-task.example.json` 复制为工作区中的 `.vscode/tasks.json`。
2. 把模板里的 `C:\PATH\TO\...\codex_bridge_manager.ps1` 改成 manager 的实际绝对路径。
3. 打开受信任工作区，并在 VS Code 提示时允许自动任务。

任务会在 `folderOpen` 时执行 `auto`：

- 官方/Bridge 配置：启动或复用 Bridge；
- 普通三方配置：保持 Bridge 停止；
- 终止 VS Code Task：同时结束前台 Bridge，不需要再执行 `stop`。

如果要固定官方模型，可在 `args` 中追加：

```json
"args": [
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
  "C:\\你的实际路径\\codex_bridge_manager.ps1", "auto",
  "-Model", "gpt-5.6-sol"
]
```

如果 VS Code 一直开着、期间切换了 Provider，重新加载窗口，或手动执行一次：

```powershell
& "C:\path\to\codex_bridge_manager.ps1" auto
```

### Linux / macOS / WSL

1. 将 `vscode-task-linux.example.json` 复制为 `.vscode/tasks.json`。
2. 把模板中的 `/absolute/path/to/.../codex_bridge_manager.sh` 改成实际绝对路径。
3. 执行 `chmod +x ./codex_bridge_manager.sh`，并允许 VS Code 自动任务。

如需固定官方模型，在 task 的 `args` 中追加：

```json
"--model", "gpt-5.6-sol"
```

---

## 工作原理

### 1. 会话可见性依赖 Provider 身份

Codex/CC Switch 可能按 `model_provider` 对本地会话分组或迁移。如果官方路线使用 `cc-switch-official` / `openai`，第三方使用 `custom`，同一批磁盘历史可能在一个 Provider 桶中可见，切换后却消失。

官方路线启用 Bridge 时，manager 会使用：

```toml
model_provider = "custom"
```

这样使用同一 Provider 桶的会话更容易保持可见。

### 2. Responses 历史不只是聊天文字

Responses 请求可能重放：

- 用户/助手消息；
- tool calls / tool results；
- reasoning item；
- item ID；
- `encrypted_content`；
- `previous_response_id`；
- 顶层 `model`。

当请求仍然回到创建这些状态的服务时，续接通常可以正常工作；跨 Provider 后，这些不透明 ID、加密字段和结构可能使用不同的格式、归属或校验规则。

### 3. Bridge 如何处理请求


| 输入字段 / item                   | 第一遍处理                   | 兼容重试               | 原因                                        |
| ----------------------------------- | ------------------------------ | ------------------------ | --------------------------------------------- |
| 顶层`input[].id`                  | 删除                         | 删除                   | ID 由具体 Provider 创建并校验               |
| `previous_response_id`            | 删除                         | 删除                   | 引用上一 Provider 的服务端状态              |
| `store`                           | 强制`false`                  | 强制`false`            | 使用完整本地重放，而不是依赖旧服务端状态    |
| 外来且非空的`reasoning.content`   | 改成`[]`                     | 省略 reasoning item    | 不同 Provider 接受的 reasoning 重放结构不同 |
| 外来的`encrypted_content`         | 删除                         | 随 reasoning item 省略 | 不能假设新 Provider 可以验证旧密文          |
| `item_reference`                  | 第一遍保留                   | 省略                   | 引用可能指向 Provider 私有状态              |
| 顶层`model`                       | 仅设置 model override 时替换 | 保留替换值             | 旧会话可能仍携带三方模型名                  |
| 用户/助手消息、tool calls/results | 保留                         | 保留                   | 这些是主要的可移植交互历史                  |

如果第一遍请求仍命中特征明确的 HTTP 400 兼容性错误，Bridge 才会使用更保守的历史重放再试一次。

### 4. 为什么不直接改历史文件

把 JSONL 中的 `resp_…` 改成 `msg_…` 只改变字符串前缀，并不能：

- 转移服务端状态归属；
- 修复 encrypted reasoning；
- 更新 SQLite 索引；
- 保证目标 Provider 接受新的 item 结构。

直接改磁盘历史还有可能破坏原本能在旧 Provider 上继续的会话。因此 Bridge 只修改**内存中的请求副本**，不会改写保存的 session。

### 5. 协议支持与历史兼容是两个问题

Bridge **不是协议转换器**。如果某个直连端点本身不支持 `/responses`，Bridge 不能让它凭空支持 Responses。Anthropic Messages、Gemini 或 Chat Completions 等协议转换仍需要由 CC Switch 完成。

---

## 能做什么 / 不能做什么

### 能做

- 处理三方 → 官方时常见的会话可见性问题；
- 清理 Provider 私有的续接状态；
- 在需要时覆盖旧会话顶层模型名；
- 保留用户/助手消息和支持的工具调用；
- 在修改 Codex 用户级配置前创建备份；
- 根据最终 Codex 配置决定 `auto` 是否启用 Bridge。

### 不会做

- 不编辑 `.codex/sessions` JSONL；
- 不编辑 Codex SQLite 数据库；
- 不读取或修改 `.codex/auth.json`；
- 不删除或迁移聊天记录；
- 不修改 CC Switch 内部数据库或自动选择 Provider；
- 不负责把 Responses 转换成 Anthropic/Gemini/Chat Completions；
- 无法无损保留 Provider 私有隐藏 reasoning。

---

## 文件说明


| 文件                             | 用途                                           |
| ---------------------------------- | ------------------------------------------------ |
| `codex_provider_bridge.py`       | 本地 HTTP 兼容 Bridge                          |
| `codex_bridge_manager.ps1`       | Windows 启停、端口检查、配置备份、条件自动启动 |
| `codex_bridge_manager.sh`        | Linux/macOS/WSL Bash manager                   |
| `vscode-task.example.json`       | Windows VS Code`folderOpen` Task 模板          |
| `vscode-task-linux.example.json` | Linux/macOS/WSL VS Code Task 模板              |
| `README.md`                      | English documentation                          |
| `README.zh-CN.md`                | 简体中文文档                                   |

---

## 换电脑 / 首次自检

项目不依赖原电脑用户名、Downloads 目录或固定 Bridge 端口。完整复制项目目录，并保持 Python Bridge 与 manager 脚本在同一目录即可。

换电脑不会自动迁移 Codex 历史；如果需要旧聊天记录，还需要单独迁移原账号的 `.codex` 数据。本项目不会删除或迁移这些记录。

首次运行失败，或想提前检查 Python、路径和端口时，可运行只读 `doctor`：

**Windows CMD**

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" doctor
```

**Windows PowerShell**

```powershell
.\codex_bridge_manager.ps1 doctor
```

**Linux / macOS / WSL**

```bash
./codex_bridge_manager.sh doctor
```

重点确认：

- `BridgeScriptExists: true`
- Python >= 3.10
- `UpstreamListening` 与实际 CC Switch 路由一致

CC Switch 默认通常监听 `127.0.0.1:15721`。如果实际使用其他端口，请传 `-UpstreamUrl` / `--upstream-url`。

---

## 命令参考

正常使用通常只需要 `auto`。其他命令主要用于排障、恢复或手动控制。


| 命令                                   | 作用                                                 |
| ---------------------------------------- | ------------------------------------------------------ |
| `auto`                                 | 根据最终 Codex 配置决定是否启动 Bridge；正常使用首选 |
| `auto -Model ...` / `auto --model ...` | 启动并覆盖旧会话残留的三方模型名                     |
| `start`                                | 强制启动并写入 Bridge 配置                           |
| `repair`                               | 不选择 CC Switch Provider，只重新写入 Bridge 配置    |
| `status`                               | 查看进程、端口、上游和配置状态                       |
| `doctor`                               | 只读检查 Python、路径、配置与端口                    |
| `stop`                                 | 只停止由 manager 跟踪的后台 Bridge                   |

### Windows PowerShell

```powershell
.\codex_bridge_manager.ps1 auto
.\codex_bridge_manager.ps1 auto -Model gpt-5.6-sol
.\codex_bridge_manager.ps1 start
.\codex_bridge_manager.ps1 repair
.\codex_bridge_manager.ps1 status
.\codex_bridge_manager.ps1 doctor
.\codex_bridge_manager.ps1 stop
```

自定义端口：

```powershell
.\codex_bridge_manager.ps1 start `
  -BridgePort 18080 `
  -UpstreamUrl http://127.0.0.1:15721
```

### Windows CMD

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -Model gpt-5.6-sol
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" repair
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" stop
```

自定义端口：

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" start -BridgePort 18080 -UpstreamUrl http://127.0.0.1:15721
```

需要固定端口时追加 `-FixedPort`；否则端口被占用时 manager 可以选择其他空闲本地端口。

### Linux / macOS / WSL

```bash
./codex_bridge_manager.sh auto
./codex_bridge_manager.sh auto --model gpt-5.6-sol
./codex_bridge_manager.sh start
./codex_bridge_manager.sh repair
./codex_bridge_manager.sh status
./codex_bridge_manager.sh doctor
./codex_bridge_manager.sh stop
```

自定义端口：

```bash
./codex_bridge_manager.sh start \
  --bridge-port 18080 \
  --upstream-url http://127.0.0.1:15721
```

需要固定端口时追加 `--fixed-port`。

### `auto` 的判断逻辑


| 最终 Codex 配置                         | `auto` 动作                                        |
| ----------------------------------------- | ---------------------------------------------------- |
| `model_provider = "cc-switch-official"` | 启动 Bridge，并应用 Bridge 配置                    |
| `custom` 已经指向本 Bridge              | 确保 Bridge 正在运行                               |
| 普通三方或其他非 Bridge Provider        | 停止此前由 manager 管理的 Bridge，其他配置保持不变 |

判断依据是**最终生效的 Codex 用户级配置**，不是 CC Switch UI 显示的 Provider 名称。`auto` 无法刷新 CC Switch 的运行时路由缓存。

---

## 官方路线启用后的 Codex 配置

Provider 设置必须位于用户级 `~/.codex/config.toml`（Windows 对应当前用户的 Codex 配置目录）。项目级 `.codex/config.toml` 不能覆盖 `model_provider` / `model_providers`。

Bridge 启用后，相关配置通常是：

```toml
model_provider = "custom"
disable_response_storage = true

[model_providers.custom]
name = "CC Switch Bridge"
base_url = "http://127.0.0.1:15722/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false

[features]
enable_request_compression = false
```

manager 会保留其他无关配置，并在真正修改前为 `config.toml` 创建带时间戳的同目录备份。

模型 override 是 Bridge 的运行时参数，不是新的 session 文件格式，也不会作为额外 TOML 键写入旧会话。

---

## Linux / macOS / WSL 进阶用法

如果 Bridge 与 manager 不在同一目录，可显式指定 Bridge 脚本：

```bash
./codex_bridge_manager.sh auto \
  --bridge-script /path/to/codex_provider_bridge.py
```

### 手动配置 Codex（仅在 manager 无法使用时）

```bash
mkdir -p ~/.codex
cp ~/.codex/config.toml ~/.codex/config.toml.bridge-backup-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
nano ~/.codex/config.toml
```

然后使用上一节的 Bridge 配置。

### 手动前台启动

```bash
python3 ./codex_provider_bridge.py \
  --listen 127.0.0.1:15722 \
  --upstream http://127.0.0.1:15721 \
  --model-override gpt-5.6-sol
```

按 `Ctrl+C` 停止。

### 手动后台启动

```bash
mkdir -p ~/.local/state/codex-provider-bridge
nohup python3 ./codex_provider_bridge.py \
  --listen 127.0.0.1:15722 \
  --upstream http://127.0.0.1:15721 \
  --model-override gpt-5.6-sol \
  >~/.local/state/codex-provider-bridge/bridge.stdout.log \
  2>~/.local/state/codex-provider-bridge/bridge.stderr.log &
echo $! >~/.local/state/codex-provider-bridge/bridge.pid
```

检查：

```bash
ss -ltnp | grep -E ':15721|:15722'
cat ~/.local/state/codex-provider-bridge/bridge.pid
tail -n 100 ~/.local/state/codex-provider-bridge/bridge.stderr.log
```

停止：

```bash
if [ -f ~/.local/state/codex-provider-bridge/bridge.pid ]; then
  kill "$(cat ~/.local/state/codex-provider-bridge/bridge.pid)" 2>/dev/null || true
  rm -f ~/.local/state/codex-provider-bridge/bridge.pid
fi
```

---

## 兼容性

兼容性取决于 CC Switch 的协议转换能力和上游 API，不只是模型名称。


| Provider / 模型系列     | 状态       | 前提                                             |
| ------------------------- | ------------ | -------------------------------------------------- |
| OpenAI Responses 模型   | 已测试路线 | CC Switch 官方路线接受处理后的请求               |
| GLM / DeepSeek          | 已测试路线 | CC Switch 端点和格式映射正确                     |
| Qwen / MiniMax          | 条件支持   | CC Switch 支持相应上游协议                       |
| Claude / Opus           | 条件支持   | CC Switch 能把 Responses 转为 Anthropic Messages |
| Gemini                  | 条件支持   | CC Switch 能把 Responses 转为 Gemini 协议        |
| 直连 Anthropic / Gemini | 不支持     | Bridge 不是协议转换器                            |

文件、图片、托管工具、新 item 类型和 Provider 专有扩展，未来可能需要继续适配。

---

## 常见问题

### `Expected an ID that begins with 'msg'`

确认 Codex 指向 Bridge 端口，而不是直接指向 CC Switch；同时确认配置包含：

```toml
supports_websockets = false
```

### `The '<model>' model is not supported when using Codex with a ChatGPT account`

旧三方会话仍然在发送原模型名。使用当前官方路线实际提供的模型启动：

```powershell
.\codex_bridge_manager.ps1 auto -Model gpt-5.6-sol
```

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -Model gpt-5.6-sol
```

```bash
./codex_bridge_manager.sh auto --model gpt-5.6-sol
```

Bridge 日志应出现 `model_rewritten=true`。三方路线不要使用 model override；普通三方配置下 `auto` 会停止 manager 管理的 Bridge。

### `Request body size did not match Content-Length`

确认：

```toml
[features]
enable_request_compression = false
```

然后重启 Codex，并确保配置中的 Bridge 端口只被一个 Bridge 实例占用。

### `Join-Path ... $PSScriptRoot ... Path is an empty string`

这是旧版 Windows manager 在 PowerShell 5.1 参数绑定阶段计算脚本相对默认路径导致的问题。优先更新最新版 manager。旧版本可临时使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\codex_bridge_manager.ps1 auto `
  -BridgeScript "$PWD\codex_provider_bridge.py"
```

CMD：

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -BridgeScript "%CD%\codex_provider_bridge.py"
```

### `File.Replace ... The path is not of a legal form`

这是旧版 Windows manager 在 Bridge 端口变化（例如 `15722` → `15723`）后写回 `config.toml` 时的路径替换问题。请更新最新版 `codex_bridge_manager.ps1` 后重新执行 `auto`。

`Port 15722 is occupied; using 15723 instead` 本身只是提示：manager 找到了另一个可用的本地 Bridge 端口。

### `stream disconnected before completion`

表示流式响应在完成前中断，来源可能是上游 Provider、CC Switch、网络或 Bridge。

Windows 可查看 Bridge stderr：

```powershell
Get-Content "$env:LOCALAPPDATA\CodexProviderBridge\bridge-stderr.log" -Tail 100
```

建议分别通过 `15721` 和 `15722` 测试新请求，用于判断问题是在 CC Switch 上游还是 Bridge 链路。

### 官方 → 三方后仍然不能正常使用

**先重启 CC Switch。** 即使 UI 与 `config.toml` 已经显示三方路线，运行时路由缓存也可能仍然是旧节点。重启后再核对配置，并重新加载 Codex。

### 查看运行状态

PowerShell：

```powershell
.\codex_bridge_manager.ps1 status
Test-NetConnection 127.0.0.1 -Port 15721
Test-NetConnection 127.0.0.1 -Port 15722
```

CMD：

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" status
netstat -ano | findstr ":15721 :15722"
```

---

## 备份与日志

配置备份位于原 `config.toml` 旁：

```text
config.toml.bridge-backup-YYYYMMDD-HHMMSS-fff
```

Windows 运行状态和日志默认位于：

```text
%LOCALAPPDATA%\CodexProviderBridge
```

Bridge 不记录请求正文或 Authorization 请求头。

---

## 安全性与稳定性

- Bridge 监听地址应保持为 `127.0.0.1`，不要暴露到 `0.0.0.0` 或公网；
- 本项目应视为实验版 / Beta；
- 在敏感代码仓库中使用前，请自行审查脚本；
- 通过非官方本地路由使用官方订阅可能涉及产品政策或账号风险，应优先使用官方支持的调用路径。

---

## 已测试环境

- Windows 11 工作流程
- Codex CLI 0.153.4
- Python 3.10+
- HTTP Responses 传输
- `supports_websockets = false`

提交 Issue 时，请附上准确的 Codex、CC Switch、Python、Provider、模型和路由信息。
This project is licensed under the [MIT License](LICENSE).
