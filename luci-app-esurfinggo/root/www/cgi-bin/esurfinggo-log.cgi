#!/bin/sh
# EsurfingGo log - direct CGI endpoint

echo "Content-Type: application/json; charset=utf-8"
echo "Cache-Control: no-cache, no-store"
echo ""

LOG=""
if [ -f /tmp/esurfing.log ]; then
    LOG=$(cat /tmp/esurfing.log)
fi

# Escape for JSON
LOG_ESC=$(echo "$LOG" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g' | tr '\n' ' ' | head -c 5000)

echo "{\"log\":\"$LOG_ESC\"}"
