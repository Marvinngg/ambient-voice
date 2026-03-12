.PHONY: build run run-raw clean setup install uninstall check-data check-log sync install-sync uninstall-sync

APP_BUNDLE = .build/WE.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_MACOS = $(APP_CONTENTS)/MacOS

# 安装相关变量
INSTALL_DIR = $(HOME)/Applications
INSTALL_APP = $(INSTALL_DIR)/WE.app
CERT_NAME = Apple Development
LAUNCHD_LABEL = com.antigravity.we
LAUNCHD_PLIST = ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist

build:
	swift build

# 构建 app bundle 并通过 LaunchServices 启动（TCC 权限归属 WE 而非 Terminal）
run: build
	@mkdir -p $(APP_MACOS)
	@cp .build/debug/WE $(APP_MACOS)/WE
	@cp Sources/Info.plist $(APP_CONTENTS)/Info.plist
	@codesign --force --sign "$(CERT_NAME)" $(APP_BUNDLE) 2>/dev/null || codesign --force --sign - $(APP_BUNDLE)
	@killall WE 2>/dev/null; sleep 0.5; true
	@echo "Launching WE.app... (logs: tail -f ~/.we/debug.log)"
	@open $(APP_BUNDLE)
	@sleep 1 && tail -f ~/.we/debug.log

# 直接运行裸二进制（调试用，麦克风可能不工作）
run-raw: build
	.build/debug/WE

clean:
	swift package clean
	rm -rf .build/WE.app

# 创建自签名代码签名证书（TCC 权限跨编译持久化）
setup:
	@bash scripts/setup-cert.sh

# 安装到 ~/Applications 并设置开机自启
install: build
	@echo "=== 构建 app bundle ==="
	@mkdir -p $(APP_MACOS)
	@cp .build/debug/WE $(APP_MACOS)/WE
	@cp Sources/Info.plist $(APP_CONTENTS)/Info.plist
	@codesign --force --sign "$(CERT_NAME)" $(APP_BUNDLE) 2>/dev/null || codesign --force --sign - $(APP_BUNDLE)
	@echo "=== 安装到 $(INSTALL_DIR) ==="
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_APP)
	@cp -R $(APP_BUNDLE) $(INSTALL_APP)
	@echo "=== 配置开机自启 ==="
	@mkdir -p ~/Library/LaunchAgents
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>Label</key>' \
		'    <string>$(LAUNCHD_LABEL)</string>' \
		'    <key>ProgramArguments</key>' \
		'    <array>' \
		'        <string>open</string>' \
		'        <string>-a</string>' \
		'        <string>'"$$HOME/Applications/WE.app"'</string>' \
		'    </array>' \
		'    <key>RunAtLoad</key>' \
		'    <true/>' \
		'    <key>KeepAlive</key>' \
		'    <false/>' \
		'</dict>' \
		'</plist>' > $(LAUNCHD_PLIST)
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@launchctl load $(LAUNCHD_PLIST)
	@echo ""
	@echo "✅ 安装完成！"
	@echo "   应用位置: $(INSTALL_APP)"
	@echo "   开机自启: 已启用"
	@echo ""
	@echo "   手动启动: open $(INSTALL_APP)"
	@echo "   查看日志: tail -f ~/.we/debug.log"
	@echo "   卸载:     make uninstall"

# 卸载应用并移除开机自启
uninstall:
	@echo "=== 停止开机自启 ==="
	@launchctl unload $(LAUNCHD_PLIST) 2>/dev/null || true
	@rm -f $(LAUNCHD_PLIST)
	@echo "=== 停止运行中的 WE ==="
	@killall WE 2>/dev/null || true
	@echo "=== 移除应用 ==="
	@rm -rf $(INSTALL_APP)
	@echo ""
	@echo "✅ 卸载完成！"
	@echo ""
	@echo "   如需清除用户数据，请手动执行:"
	@echo "   rm -rf ~/.we/"

# 检查数据落盘
check-data:
	@echo "=== ~/.we/ data files ==="
	@ls -lh ~/.we/voice-history.jsonl 2>/dev/null || echo "  voice-history.jsonl: not yet"
	@ls -lh ~/.we/corrections.jsonl 2>/dev/null || echo "  corrections.jsonl: not yet"
	@ls -lh ~/.we/semantic-diffs.jsonl 2>/dev/null || echo "  semantic-diffs.jsonl: not yet"
	@echo "=== audio files ==="
	@ls ~/.we/audio/ 2>/dev/null | head -5 || echo "  no audio files yet"
	@echo "=== config ==="
	@cat ~/.we/config.json 2>/dev/null || echo "  no config yet (will be created on first run)"

# 查看最近日志
check-log:
	@tail -30 ~/.we/debug.log 2>/dev/null || echo "  no log yet"

# 手动同步数据到 4090 服务器
sync:
	@bash scripts/sync-to-server.sh
	@tail -3 ~/.we/sync.log

# 安装自动同步（launchd 监听 voice-history 变化）
install-sync:
	@SCRIPT_PATH="$$(cd scripts && pwd)/sync-to-server.sh"; \
	sed -e "s|__SYNC_SCRIPT__|$$SCRIPT_PATH|g" -e "s|__HOME__|$$HOME|g" \
		scripts/com.antigravity.we.sync.plist > ~/Library/LaunchAgents/com.antigravity.we.sync.plist
	@launchctl load ~/Library/LaunchAgents/com.antigravity.we.sync.plist
	@echo "Auto-sync installed (triggers on voice-history.jsonl change)"

# 卸载自动同步
uninstall-sync:
	@launchctl unload ~/Library/LaunchAgents/com.antigravity.we.sync.plist 2>/dev/null || true
	@rm -f ~/Library/LaunchAgents/com.antigravity.we.sync.plist
	@echo "Auto-sync uninstalled"
