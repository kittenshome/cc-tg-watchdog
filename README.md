# Claude Code Telegram 看门狗脚本

一套在 Linux VPS 上守护 Claude Code + Telegram 长驻会话的实用脚本：异常重启、上下文自动换气、漏回消息恢复，以及登录凭证刷新尝试。

> [!IMPORTANT]
> 这是个人环境中长期运行后整理出的脚本，不是 Anthropic/Telegram 官方组件，也不能保证 100% 不丢消息。默认阈值、界面文案和进程特征可能随 Claude Code 或插件版本变化，请先在测试 bot 上验证。

## 解决什么问题

在 VPS 上跑 `claude --channels plugin:telegram@claude-plugins-official`，迟早会遇到：

- tmux 进程悄悄死掉
- 撞上额度弹窗卡住不动
- Telegram 的 Bun 进程断连
- API 凭证过期，401 死循环
- 上下文窗口越来越大，每句话烧一大把 token
- 换气/重启那一刻刚好来了消息，没人回

这套脚本针对以上故障做自动检测和恢复；实际效果取决于 Claude Code、Telegram 插件版本和你的 VPS 环境。

## 架构

```
crontab（每3分钟）
  |
  v
tgbot-watchdog.sh ── 检查健康 ── 正常？跳过
  |                                  |
  |（出问题了）                       |
  v                                  |
tgbot.sh ── 杀旧进程                 |
  |      ── 补回漏掉的消息            |
  |      ── 刷新凭证                  |
  |      ── 启动新 tmux 会话          |
  |      ── 验证 Telegram 连接        |
  v                                  |
claude --channels plugin:telegram  <-+
  （跑在 tmux "tgbot" 里）
```

## 快速开始

### 前置条件

- 一台 VPS，装好 Claude Code CLI 并登录
- Telegram 插件（`plugin:telegram@claude-plugins-official`）
- `tmux`
- `python3`、`flock`、`timeout`、`ss`（常见 Debian/Ubuntu 可分别由 `python3`、`util-linux`、`coreutils`、`iproute2` 提供）
- 已在 Claude Code Telegram 插件中安全配置 bot token

强烈建议 Telegram 单独使用一个 `CLAUDE_CONFIG_DIR`，避免看门狗读到普通 Claude Code 项目的会话，或重启错误的频道实例。不要把 `.credentials.json`、bot token、OAuth token、会话 JSONL、日志或真实记忆补丁提交到仓库。

### 1. 复制脚本

```bash
cp watchdog.sh ~/tgbot-watchdog.sh
cp start.sh ~/tgbot.sh
cp orphan-recovery.py ~/tgbot-orphan.py
chmod +x ~/tgbot-watchdog.sh ~/tgbot.sh
```

### 2. 配置

编辑 `tgbot.sh` 和 `tgbot-watchdog.sh`，确保两边使用相同配置。下面是 root 用户示例；非 root 用户请使用自己的 `$HOME`：

```bash
# 建议 Telegram 使用独立配置目录（.credentials.json 所在位置）
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-tgbot}"

# tmux 会话名
SESSION_NAME="tgbot"

# 使用的模型
MODEL="claude-sonnet-4-6"
```

如果 Claude 会话不是从 `$HOME` 启动，还要在两个脚本中显式设置该会话的 JSONL 目录：

```bash
PROJECT_DIR="/path/to/claude-config/projects/<project-slug>"
```

脚本不会替你生成 Telegram bot token，也不会把 token 写进仓库。先用同一个 `CLAUDE_CONFIG_DIR` 手动完成 Claude Code 和 Telegram 插件登录/配置，再启用定时任务。

### 3. 设置定时任务

```bash
crontab -e
# 加这行：
*/3 * * * * /root/tgbot-watchdog.sh
```

完事。看门狗每 3 分钟跑一次，检查健康状态，有问题自动重启。

首次启用前建议手动运行一次并确认返回 `OK`：

```bash
/root/tgbot.sh
tmux attach -t tgbot
```

## 看门狗检查什么

按顺序跑以下检查：

| # | 检查项 | 抓什么问题 | 处理方式 |
|---|--------|-----------|---------|
| 1 | tmux 会话是否存在 | 进程崩溃、OOM、服务器重启 | 完整重启 |
| 2 | 屏幕内容：`could not be parsed` | 频道解析错误，无法恢复 | 完整重启 |
| 3 | 屏幕内容：`Upgrade your plan` | 额度弹窗卡住了 | 发 Escape 键 |
| 4 | 屏幕内容：`Select login method` | 不小心进了登录流程 | 发 Escape，卡住就重启 |
| 5 | 上下文 token 数 | 上下文窗口快满了 | 等空闲时重启（见下文） |
| 6 | 屏幕内容：`API Error: 401`（×2） | 凭证过期 | 完整重启 |
| 7 | 本配置目录记录的 Bun PID | Telegram 进程是否存在 | 只检查当前 Telegram 配置，避免误伤其他实例 |
| 8 | Bun TCP 连接 | Telegram 可能静默断连 | 连续失败2次后重启 |

## 上下文换气

看门狗在上下文窗口太大时自动换气（重启会话）。这么做是因为让 Claude 自带的上下文压缩介入会丢更多东西，不如干净地换一次气。

默认按约 200k 上下文的使用场景设了三档阈值；模型或账号的上下文上限不同时必须自行调整：

| 档位 | Token 数 | 空闲要求 | 为什么 |
|------|---------|---------|-------|
| 软限制 | 120,000 | 空闲15分钟 | 正常换气，等个安静的时机 |
| 硬限制 | 155,000 | 空闲2分钟 | 快到压缩区了，简单确认没在回消息就换 |
| 紧急 | 165,000 | 无 | 接近默认预留边界，立刻换 |

**怎么估算 token 数：** 读会话 JSONL 中最后一条非零 usage，计算 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`。这是输入上下文的近似值，不是官方稳定接口；日志结构变化后可能需要更新脚本。

**怎么判断空闲：** 看两个条件：
1. tmux 屏幕上没有 "esc to interrupt"（Claude 没在回消息）
2. JSONL 文件的修改时间够老（最近没处理过东西）

## 漏回消息自动补回

最痛的故障：换气/重启那一刻刚好来了消息，旧会话死了没回，新会话又不知道有这条消息。

补回机制：

1. 杀旧会话之前，读它的 JSONL 记录
2. `tgbot-orphan.py` 找到最后一条用户消息，检查后面有没有同一 `chat_id` 的成功 `telegram__reply` 工具结果
3. 如果没有记录到成功结果，就把它视为可能的“漏网之鱼”
4. 新会话启动后，自动注入一条提示让 Claude 回复这条漏掉的消息，附带前面几轮对话作为上下文

恢复上下文保存在 `CLAUDE_CONFIG_DIR/watchdog-recovery/`，目录和文件权限仅限当前用户；日志不记录消息正文或 chat ID。该机制偏向“宁可补回”，极端情况下仍可能产生重复回复。

## 记忆注入（进阶功能）

如果你想让 Claude 在换气后还能记住较长时间（例如最近 24 小时）的聊天内容，可以自行搭建记忆网关：

1. 把所有 Telegram 收发的消息存到数据库
2. 每条新消息进来时，取出相关记忆和最近对话历史
3. 作为前缀注入到用户消息前面，Claude 看到的时候就带着上下文了

这需要你自己实现数据库/记忆后端，并给 Telegram 插件的 `server.ts` 编写对应补丁。本仓库**没有包含记忆后端、24 小时注入实现或可直接使用的 `.patch` 文件**。

`ensure-patch.sh` 只是补丁维护模板：当你通过 `PATCH` 和 `PATCH_MARKER` 提供自己的补丁后，它会在插件自动更新后尝试重新应用，失败则回滚：

1. 检查 `server.ts` 是否已经有补丁标记
2. 没有的话尝试应用 `.patch` 文件
3. 构建验证能不能编译
4. 编译失败就回滚到备份

## 文件说明

| 文件 | 用途 |
|------|------|
| `watchdog.sh` | 健康检查器，crontab 每3分钟跑 |
| `start.sh` | 完整启动流程，含漏回消息补回 |
| `orphan-recovery.py` | 检测会话记录里没被回复的消息 |
| `ensure-patch.sh` | 插件更新后自动重新打记忆网关补丁 |

## 配置项

### 环境变量

| 变量 | 默认值 | 说明 |
|------|-------|------|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code 配置目录 |
| `SESSION_NAME` | `tgbot` | tmux 会话名 |
| `MODEL` | `claude-sonnet-4-6` | 使用的 Claude 模型 |
| `REFRESH_MODEL` | `claude-haiku-4-5-20251001` | 启动前最小调用使用的模型 |
| `PROJECT_DIR` | `$CLAUDE_CONFIG_DIR/projects/<HOME 路径转换>` | 此频道会话的 JSONL 目录 |
| `START_SCRIPT` | `~/tgbot.sh` | 看门狗调用的启动脚本 |
| `ORPHAN_HELPER` | `~/tgbot-orphan.py` | 漏消息检测脚本 |
| `WATCHDOG_STATE_DIR` | `$CLAUDE_CONFIG_DIR/watchdog-state` | 私有锁文件和健康检查状态目录 |

### 调整换气阈值

编辑 `watchdog.sh` 里的阈值：

```bash
CTX_LIMIT=120000      # 软限制：空闲15分钟后换气
CTX_HARD_LIMIT=155000 # 硬限制：空闲2分钟后换气
CTX_PANIC_LIMIT=165000 # 紧急：立刻换气
```

想换气更频繁就调低，想聊更久再换就调高。

## 踩过的坑

在 7×24 实际跑了几个月踩出来的：

1. **额度弹窗不能按方向键。** "Upgrade your plan / Stop and wait" 弹窗不理方向键，按回车会选中 "Upgrade" 然后进入 `/upgrade` 登录流程，出不来。要按 Escape。

2. **换气必须等空闲。** 早期版本在聊天中途换气，用户第一条消息打到一个零上下文的 Claude 上。现在换气前先确认空闲。

3. **硬限制也得等空闲。** 就算到了 155k token 的硬限制，至少也等 2 分钟空闲。有一次消息到达 4 秒后就被强制换气，那条消息被吞了没回。

4. **杀 Bun 僵尸要查父进程 PID。** 不能直接杀所有 `bun server.ts` 进程，会把正在用的那个也杀了。只杀父进程 PID 是 1（被 init 接管）的孤儿进程。

5. **TCP 检查要连续失败两次。** 一次 Telegram TCP 连接检查失败可能只是网络抖了一下。连续两次失败才重启。

6. **401 错误要累计。** 一次 401 可能是暂时的，两次以上才说明凭证真的过期了。

7. **重启前先尝试刷新凭证。** 启动真正的会话之前，脚本先跑一次最小 Claude 调用。成功时可触发已有登录凭证刷新；失败只写日志并继续，不能代替人工重新登录。

8. **区分真消息和系统事件。** Telegram 频道里用户消息和系统通知（监控告警之类的）可能使用相似的 `<channel>` 格式。检测漏回消息时要按数字用户 ID 过滤。

## 发布与安全检查

仓库当前脚本只含占位路径和配置项，不含真实 token、私钥、服务器 IP、chat ID 或对话内容。你自己 fork/修改后，发布前至少运行：

```bash
git grep -nEi 'token|secret|password|api[_-]?key|chat[_-]?id|BEGIN .*PRIVATE KEY'
git log --all --format='%h %an <%ae> %s'
```

还要人工检查所有提交历史，因为删除当前文件并不会从 Git 历史中移除曾提交过的密钥。若密钥曾经提交过，应先撤销/轮换密钥，再清理历史。

## License

MIT
