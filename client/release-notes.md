# WE v0.2.0

首个公开发布版本。

## 新功能

- **会议模式**：菜单栏 → 「开始会议」，长时间录音 → 自动分段 → L2 模型纠错 → 导出 Markdown 纪要
- **自定义热键**：菜单栏 → 「设置热键...」，支持单 modifier（Right Option 等）或组合键（⌘⇧R 等），冲突检测
- **字典纠错**：自动加载 `~/.we/correction-dictionary.json`，把高频术语注入语音识别上下文
- **完整数据留痕**：每段 L2 纠错的输入/输出实时写入 `~/.we/meeting-history.jsonl`
- **远程录音**:iOS Shortcut 通过 HTTP 推到 Mac 的 :9800 端口转写

## 安装（首次必读）

1. 下载 `WE-0.2.0.dmg`，双击挂载
2. 把 `WE.app` 拖进「应用程序」
3. 终端执行（绕过未签名警告，**只此一次**）：
   ```
   xattr -cr /Applications/WE.app
   ```
4. 启动 WE，按提示逐项授权：麦克风、语音识别、辅助功能

详见 DMG 内 `INSTALL.txt`。

## 配置

菜单栏 → 「编辑配置文件...」，关键项：

- `server.endpoint`：默认 `http://localhost:11434`，需要改成你自己的 ollama 服务器地址
- `polish.context_dictionary_enabled`：开启字典纠错（默认 false）
- `meeting.audio_source`：`mic` / `system` / `both`（系统音频/混音录会议对方声音）

## 系统要求

- macOS 26 (Tahoe)
- Apple Silicon (M 系列)
- 远程或本地 ollama 服务器，跑 `we-polish` 模型

## 已知限制

- 自签名构建：升级后 TCC 隐私授权可能要重新勾选一次
- L2 纠错依赖外部 ollama 服务，server 不通时降级为透传 SA 原文（日志里 `kind=failed`）

## 卸载

```
killall WE 2>/dev/null
rm -rf /Applications/WE.app ~/Applications/WE.app
# 同时清除历史数据：
rm -rf ~/.we/
```
