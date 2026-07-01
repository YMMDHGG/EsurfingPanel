#!/bin/sh
# EsurfingGo status - direct CGI endpoint
# Bypasses LuCI routing for reliable JSON output
# Place at /www/cgi-bin/esurfinggo-status, chmod 755

echo "Content-Type: application/json; charset=utf-8"
echo "Cache-Control: no-cache, no-store"
echo ""

# Get router arch
ROUTER_ARCH=$(uname -m 2>/dev/null)

# Check binary
BIN_EXISTS="false"
BIN_SIZE=0
if [ -f /usr/bin/esurfing ]; then
    BIN_EXISTS="true"
    BIN_SIZE=$(stat -c %s /usr/bin/esurfing 2>/dev/null || echo 0)
fi

# Find all pids of esurfing
PIDS=""
for pid_dir in /proc/[0-9]*; do
    [ -d "$pid_dir" ] || continue
    pid=$(basename "$pid_dir")
    if [ -r "$pid_dir/cmdline" ]; then
        cmd=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null)
        if echo "$cmd" | grep -q "esurfing"; then
            if [ -z "$PIDS" ]; then
                PIDS="\"$pid\""
            else
                PIDS="$PIDS,\"$pid\""
            fi
        fi
    fi
done

# Build instances
INSTANCES=""
for pid_file in /tmp/esurfing_*.pid; do
    [ -f "$pid_file" ] || continue
    name=$(basename "$pid_file" .pid | sed 's/^esurfing_//')
    pid=$(cat "$pid_file" 2>/dev/null)
    en=$(uci get "esurfinggo.$name.enabled" 2>/dev/null)
    acc=$(uci get "esurfinggo.$name.account" 2>/dev/null)

    running="false"
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        if echo "$cmd" | grep -q "esurfing"; then
            running="true"
        fi
    fi

    if [ -n "$INSTANCES" ]; then
        INSTANCES="$INSTANCES,"
    fi
    # Escape account for JSON
    acc_esc=$(echo "$acc" | sed 's/\\/\\\\/g; s/"/\\"/g')
    INSTANCES="$INSTANCES{\"name\":\"$name\",\"account\":\"$acc_esc\",\"enabled\":\"$en\",\"running\":$running}"
done

# Determine running
RUNNING="false"
if [ -n "$PIDS" ]; then
    RUNNING="true"
fi

cat << EOF
{"running":$RUNNING,"bin_exists":$BIN_EXISTS,"bin_size":$BIN_SIZE,"bin_path":"/usr/bin/esurfing","arch":"","router_arch":"$ROUTER_ARCH","pids":[$PIDS],"instances":[$INSTANCES]}
EOF
