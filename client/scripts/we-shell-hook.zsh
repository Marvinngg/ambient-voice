#!/usr/bin/env zsh
# WE Shell Hook — Terminal correction capture for voice input
#
# Add to your ~/.zshrc:
#   source /path/to/we-shell-hook.zsh
#
# How it works:
# 1. WE pastes voice transcription into the terminal
# 2. WE writes the injected text to ~/.we/pending-terminal.json
# 3. You edit the text (fix errors) and press Enter
# 4. This preexec hook compares your final command with what WE injected
# 5. If different, saves the correction to ~/.we/terminal-corrections.jsonl
# 6. WE imports these corrections and learns from them (L1 AlternativeSwap)

_we_dir="${HOME}/.we"
_we_pending="${_we_dir}/pending-terminal.json"
_we_corrections="${_we_dir}/terminal-corrections.jsonl"

_we_preexec() {
    # $1 = the command line the user is about to execute
    local user_command="$1"

    # Check if there's a pending WE injection
    [[ -f "$_we_pending" ]] || return

    # Use python3 to do everything: read pending, compare, write correction
    python3 - "$user_command" "$_we_pending" "$_we_corrections" << 'PYEOF'
import json, sys, os, uuid, datetime

def levenshtein_similarity(s1, s2):
    """Compute Levenshtein edit distance similarity (matching Swift implementation).

    Returns: 1.0 - (edit_distance / max_length)
    This matches the similarity calculation in CorrectionCapture.swift:stringSimilarity
    """
    m, n = len(s1), len(s2)
    if m == 0 and n == 0:
        return 1.0
    if m == 0 or n == 0:
        return 0.0

    # Space-optimized DP: two rows only
    prev = list(range(n + 1))
    curr = [0] * (n + 1)

    for i in range(1, m + 1):
        curr[0] = i
        for j in range(1, n + 1):
            if s1[i - 1] == s2[j - 1]:
                curr[j] = prev[j - 1]
            else:
                curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
        prev, curr = curr, prev

    max_len = max(m, n)
    return 1.0 - prev[n] / max_len

def main():
    user_command = sys.argv[1]
    pending_path = sys.argv[2]
    corrections_path = sys.argv[3]

    # Read and delete pending file
    try:
        with open(pending_path) as f:
            pending = json.load(f)
        os.remove(pending_path)
    except:
        return

    inserted_text = pending.get("insertedText", "")
    raw_text = pending.get("rawText", "")
    app_bundle_id = pending.get("appBundleID", "")
    app_name = pending.get("appName", "")
    timestamp_str = pending.get("timestamp", "")

    if not inserted_text:
        return

    # Skip if identical
    if user_command == inserted_text:
        return

    # Check staleness (> 120s)
    if timestamp_str:
        try:
            ts = datetime.datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
            age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
            if age > 120:
                return
        except:
            pass

    # Calculate similarity using Levenshtein distance (consistent with Swift CorrectionCapture)
    sim = levenshtein_similarity(inserted_text, user_command)
    ratio = len(user_command) / max(len(inserted_text), 1)

    # Only capture if it looks like a correction (not a complete rewrite)
    if not (sim > 0.3 and sim < 1.0 and ratio > 0.5 and ratio < 2.0):
        return

    quality = sim * min(ratio, 1.0 / max(ratio, 0.01))

    # Write correction
    entry = {
        "id": str(uuid.uuid4()),
        "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rawText": raw_text,
        "insertedText": inserted_text,
        "userFinalText": user_command,
        "quality": round(quality, 4),
        "appBundleID": app_bundle_id,
        "appName": app_name,
    }
    with open(corrections_path, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

main()
PYEOF
}

# Install the hook
autoload -Uz add-zsh-hook
add-zsh-hook preexec _we_preexec
