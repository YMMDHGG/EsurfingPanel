#!/bin/sh
# EsurfingGo action CGI endpoint - v1.3.27
# Handles: dial, stop_one, start_all, restart_all, stop_all, status_refresh, upload, log
# v1.3.27: binary-safe upload — dd+grep byte offsets replace awk print

echo "Content-Type: text/html; charset=utf-8"
echo "Cache-Control: no-cache, no-store"
echo ""

# Helper: extract form value from POST body (URL-encoded)
get_post_value() {
    local key="$1"
    # Read from QUERY_STRING first (GET), then from stdin (POST)
    local val=""
    if [ -n "$QUERY_STRING" ]; then
        # URL-decode the QUERY_STRING and extract key=value
        val=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^${key}=" | head -1 | sed "s/^${key}=//" | sed 's/+/ /g')
        # URL-decode %XX
        printf '%b' "${val//%/\\x}" 2>/dev/null
        return
    fi
    if [ -n "$CONTENT_TYPE" ] && echo "$CONTENT_TYPE" | grep -q "multipart/form-data"; then
        # Multipart: just read whole body, look for boundary
        cat
    fi
}

# Helper: extract multipart file (writes to /tmp/esfg_upload_$$)
# v1.3.27: binary-safe — uses dd+grep byte offsets instead of awk print
save_upload() {
    local outfile="/tmp/esfg_upload_$$"
    local rawfile="/tmp/esfg_raw_$$"

    # Get boundary from Content-Type header
    local boundary=$(echo "$CONTENT_TYPE" | sed -n 's/.*boundary=//p' | tr -d '\r\n')
    if [ -z "$boundary" ]; then
        echo "ERROR: no boundary in Content-Type"
        return 1
    fi

    # Read entire multipart body to temp file
    cat > "$rawfile"
    local total=$(stat -c%s "$rawfile" 2>/dev/null || wc -c < "$rawfile")
    if [ "$total" -lt 100 ]; then
        rm -f "$rawfile"
        return 1
    fi

    # Find first boundary occurrence (grep -abo gives byte_offset:match)
    local bnd1=$(grep -abo -m 1 "$boundary" "$rawfile" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$bnd1" ]; then
        # Try with -- prefix
        bnd1=$(grep -abo -m 1 "--$boundary" "$rawfile" 2>/dev/null | head -1 | cut -d: -f1)
    fi
    if [ -z "$bnd1" ]; then
        rm -f "$rawfile"
        return 1
    fi

    # Find Content-Disposition with filename= to locate the file part
    local cdisp=$(grep -abo "Content-Disposition.*filename=" "$rawfile" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$cdisp" ]; then
        rm -f "$rawfile"
        return 1
    fi

    # Find the blank line (\r\n\r\n or \n\n) separating headers from file content
    # Search from Content-Disposition position forward
    local headers_len=$(dd if="$rawfile" bs=1 skip="$cdisp" 2>/dev/null | grep -abo $'\r\n\r\n' | head -1 | cut -d: -f1)
    if [ -z "$headers_len" ]; then
        headers_len=$(dd if="$rawfile" bs=1 skip="$cdisp" 2>/dev/null | grep -abo $'\n\n' | head -1 | cut -d: -f1)
    fi
    if [ -z "$headers_len" ]; then
        rm -f "$rawfile"
        return 1
    fi

    local file_start=$((cdisp + headers_len + 4))  # +4 for \r\n\r\n

    # Find next boundary occurrence after file content starts
    local rel_bnd=$(dd if="$rawfile" bs=1 skip="$file_start" 2>/dev/null | grep -abo "$boundary" | head -1 | cut -d: -f1)
    if [ -z "$rel_bnd" ]; then
        rel_bnd=$(dd if="$rawfile" bs=1 skip="$file_start" 2>/dev/null | grep -abo "--$boundary" | head -1 | cut -d: -f1)
    fi
    if [ -z "$rel_bnd" ]; then
        rm -f "$rawfile"
        return 1
    fi

    # Strip trailing \r\n before the boundary
    local file_end=$rel_bnd
    if [ "$file_end" -ge 2 ]; then
        local trail=$(dd if="$rawfile" bs=1 skip=$((file_start + file_end - 2)) count=2 2>/dev/null | od -A n -t x1 | tr -d ' \n')
        if [ "$trail" = "0d0a" ]; then
            file_end=$((file_end - 2))
        fi
    fi

    # Extract binary file content
    dd if="$rawfile" bs=1 skip="$file_start" count="$file_end" of="$outfile" 2>/dev/null
    rm -f "$rawfile"

    if [ -s "$outfile" ]; then
        echo "$outfile"
        return 0
    fi
    return 1
}

# For multipart uploads, handle separately
case "$CONTENT_TYPE" in
    *multipart/form-data*)
        # Save file
        upfile=$(save_upload)
        if [ -z "$upfile" ] || [ ! -s "$upfile" ]; then
            echo "<h2 style='color:red;'>上传失败：未收到文件</h2>"
            echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
            exit 0
        fi
        # Check arch
        file_type=$(file -b "$upfile" 2>/dev/null)
        router_arch=$(uname -m)
        # Match expected arch
        case "$file_type" in
            *ARM*aarch64*) file_arch="arm64" ;;
            *ARM*) file_arch="arm" ;;
            *x86-64*x86_64*) file_arch="x86_64" ;;
            *Intel*80386*i386*) file_arch="x86" ;;
            *MIPS*) file_arch="mips" ;;
            *) file_arch="unknown" ;;
        esac
        # Check if arch matches router
        case "$router_arch" in
            aarch64) router_arch_short="arm64" ;;
            armv7l|armv6l) router_arch_short="arm" ;;
            x86_64) router_arch_short="x86_64" ;;
            i*86) router_arch_short="x86" ;;
            mips*) router_arch_short="mips" ;;
            *) router_arch_short="$router_arch" ;;
        esac
        # Check ELF magic + executable bit
        if ! head -c 4 "$upfile" | grep -q "ELF"; then
            echo "<h2 style='color:red;'>上传失败：不是 ELF 可执行文件</h2>"
            echo "<p>文件类型: $file_type</p>"
            echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
            rm -f "$upfile"
            exit 0
        fi
        if [ "$file_arch" != "unknown" ] && [ "$file_arch" != "$router_arch_short" ]; then
            echo "<h2 style='color:red;'>上传失败：架构不匹配</h2>"
            echo "<p>路由器架构: <b>$router_arch</b> ($router_arch_short), 模块架构: <b>$file_arch</b></p>"
            echo "<p>ARM 路由不能装 x86 模块。请下载与路由器架构匹配的版本。</p>"
            echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
            rm -f "$upfile"
            exit 0
        fi
        # Stop existing and replace
        killall esurfing 2>/dev/null
        sleep 1
        cp "$upfile" /usr/bin/esurfing && chmod 755 /usr/bin/esurfing
        rm -f "$upfile"
        echo "<h2 style='color:green;'>模块已更新</h2>"
        echo "<p>已重命名为 <code>esurfing</code> 安装到 <code>/usr/bin/</code>，请在账号列表填入账号密码后点击"全部启动"或单行"启动拨号"。</p>"
        echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
        exit 0
        ;;
esac

# For URL-encoded POST: read from stdin
read_post() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null
    fi
}

POST_DATA=$(read_post)
# Use POST_DATA if available, else QUERY_STRING
if [ -n "$POST_DATA" ]; then
    QS="$POST_DATA"
else
    QS="$QUERY_STRING"
fi

# Extract a single key value
extract_kv() {
    local key="$1"
    echo "$QS" | tr '&' '\n' | grep "^${key}=" | head -1 | sed "s/^${key}=//" | sed 's/+/ /g' | sed 's/%20/ /g' | sed 's/%3C/</g' | sed 's/%3E/>/g' | sed 's/%22/"/g' | sed "s/%27/'/g"
}

OP=$(extract_kv "op")
SECTION=$(extract_kv "section")

# Also handle GET for log
if [ -z "$OP" ] && echo "$QUERY_STRING" | grep -q "op=log"; then
    OP="log"
fi

case "$OP" in
    dial)
        # Get account/password/sms from POST (note: form submission also includes cbi form fields, but we only need the section)
        # The cbi form posts account/password/sms for ALL sections. We need to find the right one.
        account=$(echo "$QS" | tr '&' '\n' | grep -F "cbid.esurfinggo.${SECTION}.account=" | head -1 | sed "s/.*=//" | sed 's/+/ /g' | sed 's/%3C/</g' | sed 's/%3E/>/g' | sed 's/%22/"/g' | sed "s/%27/'/g")
        password=$(echo "$QS" | tr '&' '\n' | grep -F "cbid.esurfinggo.${SECTION}.password=" | head -1 | sed "s/.*=//" | sed 's/+/ /g')
        sms=$(echo "$QS" | tr '&' '\n' | grep -F "cbid.esurfinggo.${SECTION}.sms=" | head -1 | sed "s/.*=//" | sed 's/+/ /g')
        if [ -z "$account" ] || [ -z "$password" ]; then
            # Fallback: read from UCI directly
            account=$(uci get "esurfinggo.${SECTION}.account" 2>/dev/null)
            password=$(uci get "esurfinggo.${SECTION}.password" 2>/dev/null)
            sms=$(uci get "esurfinggo.${SECTION}.sms" 2>/dev/null)
        fi
        if [ -z "$account" ] || [ -z "$password" ]; then
            echo "<h2 style='color:red;'>拨号失败：账号或密码为空</h2>"
            echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
            exit 0
        fi
        # Build dial command
        cmd="killall esurfing 2>/dev/null; sleep 0.3; echo \"[$(date +%H:%M:%S)] dial $account\" >> /tmp/esurfing.log; start-stop-daemon -S -b -m -p /tmp/esurfing_${SECTION}.pid -x /usr/bin/esurfing -- -u '$account' -p '$password'"
        if [ -n "$sms" ]; then
            cmd="$cmd -c '$sms'"
            # Clear SMS from UCI after use
            uci delete "esurfinggo.${SECTION}.sms" 2>/dev/null
            uci commit esurfinggo 2>/dev/null
        fi
        cmd="$cmd >> /tmp/esurfing.log 2>&1; true"
        ($cmd) &
        echo "<h2 style='color:green;'>已发起拨号: $account</h2>"
        echo "<p>3 秒后状态会更新，<a href='/cgi-bin/luci/admin/services/esurfing'>点此返回</a></p>"
        echo "<meta http-equiv='refresh' content='3;url=/cgi-bin/luci/admin/services/esurfing'>"
        ;;
    stop_one)
        if [ -n "$SECTION" ]; then
            pid=$(cat "/tmp/esurfing_${SECTION}.pid" 2>/dev/null)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null
            fi
            rm -f "/tmp/esurfing_${SECTION}.pid"
        fi
        echo "<h2 style='color:orange;'>已停止账号 $SECTION</h2>"
        echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
        ;;
    start_all)
        /etc/init.d/esurfinggo start >/dev/null 2>&1
        echo "<h2 style='color:green;'>已发送全部启动命令</h2>"
        echo "<meta http-equiv='refresh' content='2;url=/cgi-bin/luci/admin/services/esurfing'>"
        ;;
    restart_all)
        killall esurfing 2>/dev/null
        sleep 1
        /etc/init.d/esurfinggo start >/dev/null 2>&1 &
        echo "<h2 style='color:green;'>已发送全部重启命令</h2>"
        echo "<meta http-equiv='refresh' content='3;url=/cgi-bin/luci/admin/services/esurfing'>"
        ;;
    stop_all)
        killall esurfing 2>/dev/null
        rm -f /tmp/esurfing_*.pid
        echo "<h2 style='color:orange;'>已停止所有拨号进程</h2>"
        echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
        ;;
    status_refresh)
        echo "<h2>状态已刷新</h2>"
        echo "<meta http-equiv='refresh' content='1;url=/cgi-bin/luci/admin/services/esurfing'>"
        ;;
    log)
        # Output log as plain text in <pre> wrapped in minimal HTML
        if [ -f /tmp/esurfing.log ]; then
            log_content=$(cat /tmp/esurfing.log)
        else
            log_content="暂无日志"
        fi
        # Escape HTML
        log_esc=$(echo "$log_content" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
        echo "<html><head><meta charset='utf-8'><title>运行日志</title>"
        echo "<style>body{background:#1e1e1e;color:#d4d4d4;margin:0;padding:20px;font-family:monospace;}"
        echo "pre{white-space:pre-wrap;word-wrap:break-word;font-size:13px;line-height:1.5;}</style></head><body>"
        echo "<div style='margin-bottom:15px;'><a href='/cgi-bin/luci/admin/services/esurfing' style='color:#28a745;'>← 返回面板</a></div>"
        echo "<pre>$log_esc</pre>"
        echo "</body></html>"
        ;;
    *)
        echo "<h2>未知操作: $OP</h2>"
        echo "<a href='/cgi-bin/luci/admin/services/esurfing'>返回</a>"
        ;;
esac
