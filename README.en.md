# Codex Cross-Provider Session Bridge

[简体中文](README.md) | [English](README.en.md)

> [!IMPORTANT]
> This project focuses on one concrete problem: **after switching a Codex session from a third-party provider back to OpenAI Official through CC Switch, the old session may disappear or remain visible but fail to continue.**

> [!WARNING]
> This is an experimental, unofficial compatibility layer. Codex, CC Switch, or upstream API changes may require future updates.

## 30-second overview

A Codex local session contains more than chat text. It can also include provider-owned item IDs, encrypted reasoning, `previous_response_id`, and a stale model name. Those fields may work with the provider that created them but fail after the session is replayed through another provider.

This project inserts a local bridge between Codex and CC Switch:

```text
Codex CLI / IDE
      ↓
127.0.0.1:15722   Bridge
      ↓
127.0.0.1:15721   CC Switch
      ↓
OpenAI Official / Provider
```

The bridge mainly does three things:

- **Keeps sessions discoverable** by using a shared `model_provider = "custom"` bucket on the official route when needed;
- **Makes old sessions replayable** by removing provider-owned state that is not portable;
- **Fixes stale model names** by optionally rewriting the outbound top-level `model` to the current official model.

The bridge **does not modify `.codex/sessions`, Codex SQLite databases, or `.codex/auth.json`**. It only transforms a copy of the outgoing request.

### Typical symptoms


| Symptom                                                   | Common cause                                                                             |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Old sessions disappear after switching providers          | The session is indexed under another`model_provider` bucket                              |
| The session is visible but sending the next message fails | Provider-owned state from the previous route is still replayed                           |
| `Expected an ID that begins with 'msg'`                   | An item ID from another provider is being validated by a different ID schema             |
| `Encrypted content could not be decrypted or parsed`      | Encrypted reasoning cannot be verified by the new provider                               |
| `Invalid input[…].content: array too long`               | The previous reasoning item shape is incompatible                                        |
| `The '<third-party-model>' model is not supported...`     | The old replay still carries a third-party model name                                    |
| `RESPONSES_MODEL_NOT_SUPPORTED`                           | The endpoint/model itself does not support Responses; this is a protocol/routing problem |

---

## Quick start

### Requirements

- Python 3.10+
- Windows PowerShell 5.1 / PowerShell 7, or Bash on Linux/macOS/WSL
- Codex using the Responses wire API
- A running CC Switch local Codex route, normally `http://127.0.0.1:15721`
- `codex_provider_bridge.py` next to the manager script you use

> [!NOTE]
> Windows CMD cannot execute a `.ps1` file directly, so the CMD examples invoke it through `powershell.exe -File`.

### 1. Third-party → OpenAI Official (primary use case)

1. In **CC Switch**, sign in to and select **OpenAI Official**.
2. If the local route has not reloaded, restart CC Switch.
3. Run `auto` from the project directory.

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
chmod +x ./codex_bridge_manager.sh  # first time only
./codex_bridge_manager.sh auto
```

4. **Keep the bridge process running**, reload VS Code/Codex, and select an official-route model.
5. Reopen the previous third-party session and continue it.

If the old session still sends a third-party model name such as `glm-5.3-flash`, explicitly provide the official model that your account actually offers:

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
> `gpt-5.6-sol` is only an example. Replace it with the model actually available on your OpenAI Official route. If the top level of `config.toml` already contains an official-looking model name (`gpt-*`, `o*`, or `codex*`), the manager normally reuses it automatically.

### 2. OpenAI Official → third-party

1. Select the target third-party provider in CC Switch.
2. **Restart CC Switch unconditionally.** Do this even if `config.toml` already shows the new third-party `base_url`; the runtime route cache may still be stale.
3. Confirm `config.toml` no longer points to a local bridge port such as `127.0.0.1:15722` or `15723`.
4. If the bridge is running in a foreground terminal or VS Code task, close/terminate it. Run `stop` only if you deliberately started the bridge in background mode.
5. Select the third-party model in Codex.

Background-mode stop commands:

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
> The manager **does not switch the CC Switch provider and does not restart CC Switch for you**. In particular, after every **Official → third-party** switch, restart CC Switch manually.

---

## Recommended: automatic start in VS Code

If you do not want to run `auto` manually every time you switch back to OpenAI Official, use the included VS Code task template.

### Windows

1. Copy `vscode-task.example.json` to `.vscode/tasks.json` in a trusted workspace.
2. Replace `C:\PATH\TO\...\codex_bridge_manager.ps1` with the manager's real absolute path.
3. Open the workspace and allow automatic tasks when VS Code asks.

The task runs `auto` on `folderOpen`:

- official/bridge configuration: start or reuse the bridge;
- normal third-party configuration: keep the bridge stopped;
- terminating the VS Code task also stops the foreground bridge.

To force an official model, append it to the task `args`:

```json
"args": [
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
  "C:\\your\\actual\\path\\codex_bridge_manager.ps1", "auto",
  "-Model", "gpt-5.6-sol"
]
```

If VS Code remains open while you switch providers, reload the window or run:

```powershell
& "C:\path\to\codex_bridge_manager.ps1" auto
```

### Linux / macOS / WSL

1. Copy `vscode-task-linux.example.json` to `.vscode/tasks.json`.
2. Replace `/absolute/path/to/.../codex_bridge_manager.sh` with the real absolute path.
3. Run `chmod +x ./codex_bridge_manager.sh` and allow automatic tasks.

To force an official model, append this to the task `args`:

```json
"--model", "gpt-5.6-sol"
```

---

## How it works

### 1. Session discovery depends on provider identity

Codex/CC Switch may group or migrate local sessions according to `model_provider`. If the official route uses `cc-switch-official` / `openai` while third-party routes use `custom`, the same on-disk history can be visible in one provider bucket and disappear in another.

When the official route uses the bridge, the manager applies:

```toml
model_provider = "custom"
```

This keeps sessions that use the same provider bucket discoverable.

### 2. Responses history contains more than messages

A Responses replay may contain:

- user/assistant messages;
- tool calls and tool results;
- reasoning items;
- item IDs;
- `encrypted_content`;
- `previous_response_id`;
- a top-level `model`.

These fields can work when continuation returns to the service that created them. Across unrelated providers or compatibility gateways, opaque IDs, encrypted fields, and item shapes may use different schemas, ownership, or validation rules.

### 3. Request transformation


| Input field / item                   | First pass                       | Portable retry           | Why                                                                |
| -------------------------------------- | ---------------------------------- | -------------------------- | -------------------------------------------------------------------- |
| Top-level`input[].id`                | Remove                           | Remove                   | IDs are created and validated by a provider                        |
| `previous_response_id`               | Remove                           | Remove                   | It references server-side state owned by the previous provider     |
| `store`                              | Force`false`                     | Force`false`             | Replay full local history instead of depending on old server state |
| Foreign non-empty`reasoning.content` | Replace with`[]`                 | Omit reasoning item      | Providers accept different reasoning replay shapes                 |
| Foreign`encrypted_content`           | Remove                           | Omit with reasoning item | Another provider cannot be assumed to verify the ciphertext        |
| `item_reference`                     | Keep initially                   | Omit                     | The reference may point to provider-owned state                    |
| Top-level`model`                     | Replace only with model override | Keep replacement         | An old session may still carry a third-party model name            |
| Messages and tool calls/results      | Preserve                         | Preserve                 | These are the main portable interaction history                    |

Only a matching HTTP 400 portability error triggers one more conservative replay.

### 4. Why stored session files are not rewritten

Changing `resp_…` to `msg_…` in JSONL would only change a string prefix. It would not transfer server-side ownership, repair encrypted reasoning, update SQLite indexes, or guarantee that the target provider accepts the item shape.

Rewriting stored history could also damage a session that still works with its original provider. The bridge therefore transforms only an **in-memory copy of the outgoing request**.

### 5. Protocol support is a separate problem

The bridge **is not a protocol converter**. If a direct endpoint does not support `/responses`, the bridge cannot make it implement Responses. Conversion to Anthropic Messages, Gemini, or Chat Completions must still be handled by CC Switch.

---

## Scope

### What it does

- helps keep old sessions visible when returning to the official route;
- removes provider-owned continuation state that is not portable;
- optionally overrides a stale third-party model name;
- preserves user/assistant messages and supported tool calls;
- backs up the user-level Codex config before changes;
- conditionally starts the bridge based on the final Codex configuration.

### What it does not do

- does not edit `.codex/sessions` JSONL files;
- does not edit Codex SQLite databases;
- does not read or modify `.codex/auth.json`;
- does not delete or migrate conversation history;
- does not modify the CC Switch internal database or select a provider;
- does not convert Responses to Anthropic/Gemini/Chat Completions;
- cannot preserve provider-private hidden reasoning losslessly.

---

## Files


| File                             | Purpose                                                               |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `codex_provider_bridge.py`       | Local HTTP compatibility bridge                                       |
| `codex_bridge_manager.ps1`       | Windows lifecycle, port checks, config backup, conditional auto-start |
| `codex_bridge_manager.sh`        | Linux/macOS/WSL Bash manager                                          |
| `vscode-task.example.json`       | Windows VS Code`folderOpen` task template                             |
| `vscode-task-linux.example.json` | Linux/macOS/WSL VS Code task template                                 |
| `README.md`                      | English documentation                                                 |
| `README.zh-CN.md`                | Simplified Chinese documentation                                      |

---

## Moving to another computer / first-run check

The project does not depend on the old computer's username, Downloads directory, or a fixed bridge port. Copy the complete project directory and keep the Python bridge beside the manager script.

Moving this project does not move Codex conversations. If you need old local history, migrate the old account's `.codex` data separately. This project does not delete or migrate those records.

Use the read-only `doctor` command if the first run fails or if you want to check Python, paths, and ports in advance.

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

Check especially:

- `BridgeScriptExists: true`
- Python >= 3.10
- `UpstreamListening` matches the actual CC Switch route

CC Switch normally listens on `127.0.0.1:15721`. For another upstream port, use `-UpstreamUrl` / `--upstream-url`.

---

## Command reference

Normal use usually needs only `auto`. The other commands are mainly for troubleshooting, recovery, or manual control.


| Command                                | Purpose                                                               |
| ---------------------------------------- | ----------------------------------------------------------------------- |
| `auto`                                 | Conditionally start the bridge based on the final Codex configuration |
| `auto -Model ...` / `auto --model ...` | Start and override a stale third-party model name                     |
| `start`                                | Force start and apply bridge configuration                            |
| `repair`                               | Reapply bridge configuration without selecting a CC Switch provider   |
| `status`                               | Show process, port, upstream, and config status                       |
| `doctor`                               | Read-only check of Python, paths, config, and ports                   |
| `stop`                                 | Stop only a background bridge tracked by the manager                  |

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

Custom port:

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

Custom port:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" start -BridgePort 18080 -UpstreamUrl http://127.0.0.1:15721
```

Append `-FixedPort` to fail instead of choosing another free local port.

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

Custom port:

```bash
./codex_bridge_manager.sh start \
  --bridge-port 18080 \
  --upstream-url http://127.0.0.1:15721
```

Append `--fixed-port` to fail instead of choosing another free local port.

### `auto` decision logic


| Final Codex configuration                         | `auto` action                                                                     |
| --------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `model_provider = "cc-switch-official"`           | Start the bridge and apply bridge config                                          |
| `custom` already points to this bridge            | Ensure the bridge is running                                                      |
| Normal third-party or another non-bridge provider | Stop a bridge previously managed by this manager and leave other config unchanged |

Detection uses the **final user-level Codex configuration**, not the provider name shown in the CC Switch UI. `auto` cannot refresh CC Switch's in-memory route cache.

---

## Resulting official-route Codex configuration

Provider settings belong in the user-level `~/.codex/config.toml` (or the corresponding user-level Codex config directory on Windows). A project-level `.codex/config.toml` cannot override `model_provider` or `model_providers`.

When the bridge is active, the relevant settings are normally:

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

The manager preserves unrelated settings and creates a timestamped sibling backup of `config.toml` before a real change.

The model override is a runtime bridge option, not a new session-file format and not a separate TOML key in the saved session.

---

## Linux / macOS / WSL advanced usage

If the bridge and manager are in different directories, provide the bridge path explicitly:

```bash
./codex_bridge_manager.sh auto \
  --bridge-script /path/to/codex_provider_bridge.py
```

### Manual Codex configuration (only if the manager cannot be used)

```bash
mkdir -p ~/.codex
cp ~/.codex/config.toml ~/.codex/config.toml.bridge-backup-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
nano ~/.codex/config.toml
```

Then use the bridge configuration shown above.

### Manual foreground start

```bash
python3 ./codex_provider_bridge.py \
  --listen 127.0.0.1:15722 \
  --upstream http://127.0.0.1:15721 \
  --model-override gpt-5.6-sol
```

Press `Ctrl+C` to stop it.

### Manual background start

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

Check it with:

```bash
ss -ltnp | grep -E ':15721|:15722'
cat ~/.local/state/codex-provider-bridge/bridge.pid
tail -n 100 ~/.local/state/codex-provider-bridge/bridge.stderr.log
```

Stop it with:

```bash
if [ -f ~/.local/state/codex-provider-bridge/bridge.pid ]; then
  kill "$(cat ~/.local/state/codex-provider-bridge/bridge.pid)" 2>/dev/null || true
  rm -f ~/.local/state/codex-provider-bridge/bridge.pid
fi
```

---

## Compatibility

Compatibility depends on CC Switch protocol conversion and the upstream API, not only on a model name.


| Provider / model family   | Status      | Requirement                                                |
| --------------------------- | ------------- | ------------------------------------------------------------ |
| OpenAI Responses models   | Tested path | The CC Switch official route accepts the sanitized request |
| GLM / DeepSeek            | Tested path | Correct CC Switch endpoint and format mapping              |
| Qwen / MiniMax            | Conditional | CC Switch supports the selected upstream protocol          |
| Claude / Opus             | Conditional | CC Switch converts Responses to Anthropic Messages         |
| Gemini                    | Conditional | CC Switch converts Responses to Gemini protocol            |
| Direct Anthropic / Gemini | Unsupported | The bridge is not a protocol converter                     |

Files, images, hosted tools, new item types, and provider-specific extensions may require future updates.

---

## Troubleshooting

### `Expected an ID that begins with 'msg'`

Confirm that Codex points to the bridge port instead of directly to CC Switch, and ensure the configuration contains:

```toml
supports_websockets = false
```

### `The '<model>' model is not supported when using Codex with a ChatGPT account`

The old third-party session is still sending its original model name. Start the bridge with the official model actually offered to your account:

```powershell
.\codex_bridge_manager.ps1 auto -Model gpt-5.6-sol
```

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -Model gpt-5.6-sol
```

```bash
./codex_bridge_manager.sh auto --model gpt-5.6-sol
```

The bridge log should show `model_rewritten=true`. Do not use model override while a normal third-party route is active.

### `Request body size did not match Content-Length`

Confirm:

```toml
[features]
enable_request_compression = false
```

Then restart Codex and make sure only one bridge instance owns the configured bridge port.

### `Join-Path ... $PSScriptRoot ... Path is an empty string`

This was an older Windows manager issue caused by resolving a script-relative default during PowerShell 5.1 parameter binding. Prefer the latest manager. Older copies can temporarily use:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\codex_bridge_manager.ps1 auto `
  -BridgeScript "$PWD\codex_provider_bridge.py"
```

CMD:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" auto -BridgeScript "%CD%\codex_provider_bridge.py"
```

### `File.Replace ... The path is not of a legal form`

This was an older Windows manager issue when the bridge port changed, for example `15722` → `15723`, and the manager wrote `config.toml` back. Update `codex_bridge_manager.ps1` and rerun `auto`.

`Port 15722 is occupied; using 15723 instead` is only an informational message: the manager found another available local bridge port.

### `stream disconnected before completion`

The streaming response ended before completion. The cause may be the upstream provider, CC Switch, the network, or the bridge.

On Windows, inspect bridge stderr:

```powershell
Get-Content "$env:LOCALAPPDATA\CodexProviderBridge\bridge-stderr.log" -Tail 100
```

Testing a fresh request separately through `15721` and `15722` helps identify whether the failure is upstream of the bridge or on the bridge path.

### Third-party route still does not work after leaving Official

**Restart CC Switch first.** Even when the UI and `config.toml` already show the third-party route, the runtime route cache may still point to the previous node. After restarting, verify the config and reload Codex.

### Check status

PowerShell:

```powershell
.\codex_bridge_manager.ps1 status
Test-NetConnection 127.0.0.1 -Port 15721
Test-NetConnection 127.0.0.1 -Port 15722
```

CMD:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\codex_bridge_manager.ps1" status
netstat -ano | findstr ":15721 :15722"
```

---

## Backups and logs

Config backups are created next to the original `config.toml`:

```text
config.toml.bridge-backup-YYYYMMDD-HHMMSS-fff
```

On Windows, runtime state and logs are stored under:

```text
%LOCALAPPDATA%\CodexProviderBridge
```

The bridge does not log request bodies or Authorization headers.

---

## Security and stability

- Keep the bridge bound to `127.0.0.1`; do not expose it on `0.0.0.0` or the public internet.
- Treat this project as experimental/Beta software.
- Review the scripts before using them in sensitive repositories.
- Using an official subscription through an unofficial local route may involve product-policy or account risk; prefer officially supported paths when available.

---

## Tested environment

- Windows 11 workflow
- Codex CLI 0.153.4
- Python 3.10+
- HTTP Responses transport
- `supports_websockets = false`

When filing an issue, include the exact Codex, CC Switch, Python, provider, model, and route information.

This project is licensed under the [MIT License](LICENSE).
