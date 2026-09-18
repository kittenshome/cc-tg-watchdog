# Claude Code Telegram 看门狗脚本

让你的 Claude Code + Telegram 在 VPS 上 7×24 跑着不掉线。自动重启、上下文自动换气（省额度不丢记忆）、换气时漏回的消息自动补回、凭证过期自动刷新。

## 解决什么问题

在 VPS 上跑 `claude --channels plugin:telegram@claude-plugins-official`，迟早会遇到：

- tmux 进程悄悄死掉
- 撞上额度弹窗卡住不动
- Telegram 的 Bun 进程断连
- API 凭证过期，401 死循环
- 上下文窗口越来越大，每句话烧一大把 token
- 换气/重启那一刻刚好来了消息，没人回

这套脚本全解决。

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
- 配好 Telegram bot token

### 1. 复制脚本

```bash
cp watchdog.sh ~/tgbot-watchdog.sh
cp start.sh ~/tgbot.sh
cp orphan-recovery.py ~/tgbot-orphan.py
chmod +x ~/tgbot-watchdog.sh ~/tgbot.sh
```

### 2. 配置

编辑 `tgbot.sh`，设置：

```bash
# Claude 配置目录（.credentials.json 所在位置）
CLAUDE_CONFIG_DIR="/root/.claude"

# tmux 会话名
SESSION_NAME="tgbot"

# 使用的模型
MODEL="claude-sonnet-4-6"
```

### 3. 设置定时任务

```bash
crontab -e
# 加这行：
*/3 * * * * /root/tgbot-watchdog.sh
```

完事。看门狗每 3 分钟跑一次，检查健康状态，有问题自动重启。

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
| 7 | 孤儿 Bun 进程 | Telegram 僵尸进程 | 杀掉孤儿进程 |
| 8 | Bun TCP 连接 | Telegram 静默断连 | 连续失败2次后重启 |

## 上下文换气

看门狗在上下文窗口太大时自动换气（重启会话）。这么做是因为让 Claude 自带的上下文压缩介入会丢更多东西，不如干净地换一次气。

三档阈值：

| 档位 | Token 数 | 空闲要求 | 为什么 |
|------|---------|---------|-------|
| 软限制 | 120,000 | 空闲15分钟 | 正常换气，等个安静的时机 |
| 硬限制 | 155,000 | 空闲2分钟 | 快到压缩区了，简单确认没在回消息就换 |
| 紧急 | 165,000 | 无 | 马上要压缩了，立刻换 |

**怎么测 token 数：** 读会话的 JSONL 文件，取最后一条非零 usage 里的 `cache_creation_input_tokens + cache_read_input_tokens`，这是实际上下文窗口大小。

**怎么判断空闲：** 看两个条件：
1. tmux 屏幕上没有 "esc to interrupt"（Claude 没在回消息）
2. JSONL 文件的修改时间够老（最近没处理过东西）

## 漏回消息自动补回

最痛的故障：换气/重启那一刻刚好来了消息，旧会话死了没回，新会话又不知道有这条消息。

补回机制：

1. 杀旧会话之前，读它的 JSONL 记录
2. `tgbot-orphan.py` 找到最后一条用户消息，检查后面有没有 `telegram__reply` 工具调用
3. 如果最后一条消息没被回过，就是"漏网之鱼"
4. 新会话启动后，自动注入一条提示让 Claude 回复这条漏掉的消息，附带前面几轮对话作为上下文

## 记忆注入（进阶功能）

如果你想让 Claude 在换气后还能记住之前聊的内容，可以搭一个记忆网关：

1. 把所有 Telegram 收发的消息存到数据库
2. 每条新消息进来时，取出相关记忆和最近对话历史
3. 作为前缀注入到用户消息前面，Claude 看到的时候就带着上下文了

这需要给 Telegram 插件的 `server.ts` 打补丁。

`ensure-patch.sh` 脚本会在插件自动更新后重新打补丁，打失败自动回滚：

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
| `CLAUDE_CODE_OAUTH_TOKEN` | （无） | 覆盖认证 token |
| `SESSION_NAME` | `tgbot` | tmux 会话名 |
| `MODEL` | `claude-sonnet-4-6` | 使用的 Claude 模型 |

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

7. **重启前先刷新凭证。** 启动真正的会话之前，先跑一次最小的 Claude 调用（haiku，"ok"）强制刷新凭证。不这么做的话，401 死循环能连续重复 21 次。

8. **区分真消息和系统事件。** Telegram 频道里用户消息和系统通知（监控告警之类的）用的是同一个 `<channel>` 格式。检测漏回消息时要按用户 ID 过滤（真人用户的 ID 是数字）。

## License

MIT
