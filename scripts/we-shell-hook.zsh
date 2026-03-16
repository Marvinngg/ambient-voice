#!/usr/bin/env zsh
# WE 终端纠错 shell hook
#
# 安装方式：在 ~/.zshrc 中添加：
#   source /path/to/we-shell-hook.zsh
#
# 工作原理：
# 1. WE 向终端注入语音文本后，写 pending 文件到 ~/.we/pending-terminal.json
# 2. 用户修正后按 Enter 执行命令
# 3. zsh preexec hook 在命令执行前触发，读 pending → 对比实际命令 → 写 correction
# 4. 下次 VoicePipeline 运行时导入 corrections

__we_preexec() {
    local pending_file="$HOME/.we/pending-terminal.json"
    local corrections_file="$HOME/.we/terminal-corrections.jsonl"
    local actual_command="$1"

    [[ ! -f "$pending_file" ]] && return
    [[ -z "$actual_command" ]] && return

    # 用 Python 做对比和写入（JSON 处理更可靠）
    python3 -c "
import json, sys, os, time

def main():
    pending_path = '$pending_file'
    corrections_path = '$corrections_file'
    actual = '''$actual_command'''

    try:
        with open(pending_path) as f:
            pending = json.load(f)
    except:
        return

    inserted = pending.get('inserted_text', '')
    if not inserted:
        return

    # 过期检查（>120 秒视为过期）
    try:
        from datetime import datetime
        ts = datetime.fromisoformat(pending['timestamp'].replace('Z', '+00:00'))
        age = (datetime.now(ts.tzinfo) - ts).total_seconds()
        if age > 120:
            os.remove(pending_path)
            return
    except:
        pass

    # 相似度检查
    set_a, set_b = set(inserted), set(actual)
    if not set_a or not set_b:
        os.remove(pending_path)
        return
    intersection = len(set_a & set_b)
    union = len(set_a | set_b)
    sim = intersection / union if union > 0 else 0

    ratio = len(actual) / max(len(inserted), 1)

    # 完全相同 → 没修改
    if sim >= 1.0 and ratio == 1.0:
        os.remove(pending_path)
        return

    # 相似度过低 → 不是纠错
    if sim < 0.3 or ratio < 0.3 or ratio > 3.0:
        os.remove(pending_path)
        return

    quality = sim * min(ratio, 1.0 / ratio) if ratio != 0 else 0

    correction = {
        'inserted_text': inserted,
        'raw_text': pending.get('raw_text', inserted),
        'user_command': actual,
        'quality': round(quality, 4),
        'app_bundle_id': pending.get('app_bundle_id', ''),
        'app_name': pending.get('app_name', ''),
        'timestamp': pending.get('timestamp', '')
    }

    with open(corrections_path, 'a') as f:
        f.write(json.dumps(correction, ensure_ascii=False) + '\n')

    os.remove(pending_path)

main()
" 2>/dev/null
}

# 注册 zsh preexec hook
autoload -Uz add-zsh-hook
add-zsh-hook preexec __we_preexec
