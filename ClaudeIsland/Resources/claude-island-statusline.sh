#!/bin/bash
# Claude Island StatusLine Wrapper
# 1. Caches session metadata (model, context) to $TMPDIR for Claude Island to read
# 2. Passes stdin through to the original statusLine command for HUD rendering
#    If no original command exists, outputs a basic status line for the CLI HUD

INPUT=$(cat)

# Cache session metadata for Claude Island
if command -v jq &>/dev/null && [ -n "$INPUT" ]; then
    # Also write a shared rate-limit cache (5h/7d) for TokenUsageBadge.
    echo "$INPUT" | jq -c '{
        five_hour: {
            utilization: (.rate_limits.five_hour.used_percentage // 0),
            resets_at: (if .rate_limits.five_hour.resets_at then (.rate_limits.five_hour.resets_at | todate) else null end)
        },
        seven_day: {
            utilization: (.rate_limits.seven_day.used_percentage // 0),
            resets_at: (if .rate_limits.seven_day.resets_at then (.rate_limits.seven_day.resets_at | todate) else null end)
        }
    }' > "${TMPDIR}claude-usage-cache.json" 2>/dev/null

    # Get git branch from cwd (fast, ~5ms)
    _CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
    _GIT_BRANCH=""
    if [ -n "$_CWD" ]; then
        _GIT_BRANCH=$(GIT_OPTIONAL_LOCKS=0 git -C "$_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    fi

    _SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -n "$_SID" ]; then
        echo "$INPUT" | jq -c --arg branch "$_GIT_BRANCH" '{
            session_id,
            model: .model.display_name,
            model_id: .model.id,
            context_pct: .context_window.used_percentage,
            context_size: .context_window.context_window_size,
            input_tokens: .context_window.current_usage.input_tokens,
            output_tokens: .context_window.current_usage.output_tokens,
            cache_creation_tokens: .context_window.current_usage.cache_creation_input_tokens,
            cache_read_tokens: .context_window.current_usage.cache_read_input_tokens,
            total_cost_usd: .cost.total_cost_usd,
            total_duration_ms: .cost.total_duration_ms,
            total_api_duration_ms: .cost.total_api_duration_ms,
            lines_added: .cost.total_lines_added,
            lines_removed: .cost.total_lines_removed,
            five_hour_pct: .rate_limits.five_hour.used_percentage,
            five_hour_resets_at: .rate_limits.five_hour.resets_at,
            seven_day_pct: .rate_limits.seven_day.used_percentage,
            seven_day_resets_at: .rate_limits.seven_day.resets_at,
            git_branch: $branch
        }' > "${TMPDIR}claude-island-session-${_SID}.json" 2>/dev/null
    fi
fi

# Pass through to original statusLine command for HUD display
# HookInstaller writes the original command verbatim into the sidecar script
# below. Execute it directly (no eval) to avoid escaping issues with complex
# quoting like claude-hud's awk pipeline.
_CI_ORIGINAL_SCRIPT="$HOME/.claude/hooks/.claude-island-original-statusline.sh"
if [ -f "$_CI_ORIGINAL_SCRIPT" ]; then
    echo "$INPUT" | bash "$_CI_ORIGINAL_SCRIPT"
else
    # Default status line for users without a custom statusLine command
    if command -v jq &>/dev/null && [ -n "$INPUT" ]; then
        MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "Claude"' 2>/dev/null)
        CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null)
        CTX_INT=$(printf "%.0f" "$CTX_PCT" 2>/dev/null || echo "0")
        FIVE_H=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
        SEVEN_D=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty' 2>/dev/null)

        OUT="$MODEL | ctx: ${CTX_INT}%"
        [ -n "$FIVE_H" ] && OUT="$OUT | 5h: $(printf '%.0f' "$FIVE_H")%"
        [ -n "$SEVEN_D" ] && OUT="$OUT | 7d: $(printf '%.0f' "$SEVEN_D")%"
        echo "$OUT"
    fi
fi
