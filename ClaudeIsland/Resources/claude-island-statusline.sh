#!/bin/bash
# Claude Island StatusLine Wrapper
# 1. Caches session metadata (model, context) to $TMPDIR for Claude Island to read
# 2. Passes stdin through to the original statusLine command for HUD rendering

INPUT=$(cat)

# Cache session metadata for Claude Island
if command -v jq &>/dev/null && [ -n "$INPUT" ]; then
    _SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -n "$_SID" ]; then
        echo "$INPUT" | jq -c '{session_id, model: .model.display_name, context_pct: .context_window.used_percentage, context_size: .context_window.context_window_size}' > "${TMPDIR}claude-island-session-${_SID}.json" 2>/dev/null
    fi
fi

# Pass through to original statusLine command for HUD display
# HookInstaller sets _CI_HAS_ORIGINAL=1 and _CI_ORIGINAL_CMD when wrapping an existing command
_CI_HAS_ORIGINAL=0
_CI_ORIGINAL_CMD=""
if [ "$_CI_HAS_ORIGINAL" = "1" ] && [ -n "$_CI_ORIGINAL_CMD" ]; then
    echo "$INPUT" | eval "$_CI_ORIGINAL_CMD"
fi
