-- EsurfingGo CBI Model v1.4.11
-- v1.4.11: multipart/form-data upload (avoids ucode 100KB URL-encoded limit)
-- v1.4.8: fix IPK format, unify build pipeline
-- v1.4.6: sync init.d sms flag fix
-- v1.4.5: sync Lua 5.1 ELF check fix
-- v1.3.38: text file import (txt/md/csv/json) with smart account/password parsing
-- v1.3.31: fix MD5 compute via shell md5sum (nixio.crypto not available)
-- v1.3.15b changes:

local m, s, o

-- v1.3.25: Bootstrap config if missing (allows zero-config install)
if not nixio.fs.access("/etc/config/esurfinggo") then
    local ok, uci = pcall(function() return require("luci.model.uci").cursor() end)
    if ok and uci then
        pcall(function()
            uci:set("esurfinggo", "module", "main")
            uci:save("esurfinggo")
            uci:commit("esurfinggo")
        end)
    end
end

m = Map("esurfinggo", translate("天翼校园网面板"),
    translate("天翼校园网 (ESurfing) 自动认证拨号管理 · 支持多账号多播 · 模块热更新 · GitHub: xxmod/EsurfingGo"))

-- ============ Token-based parser (handles quoted args, redirects, background) ============
local function _parse_line(line)
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:sub(1,1) == "#" then return nil end
    if not line:find("esurfing") then return nil end
    -- Tokenize respecting single/double quotes
    local tokens = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "'" then
            local j = i + 1
            while j <= n and line:sub(j, j) ~= "'" do j = j + 1 end
            table.insert(tokens, line:sub(i+1, j-1))
            i = j + 1
        elseif c == '"' then
            local j = i + 1
            while j <= n and line:sub(j, j) ~= '"' do j = j + 1 end
            table.insert(tokens, line:sub(i+1, j-1))
            i = j + 1
        else
            local j = i
            while j <= n and not line:sub(j, j):match("%s") do j = j + 1 end
            table.insert(tokens, line:sub(i, j-1))
            i = j
        end
    end
    local flags = {}
    local flag_map = { ["-u"]="account", ["-p"]="password", ["-s"]="sms", ["-c"]="sms", ["-n"]="interface" }
    local k = 1
    while k <= #tokens do
        local t = tokens[k]
        if flag_map[t] and k+1 <= #tokens then
            flags[flag_map[t]] = tokens[k+1]
            k = k + 2
        else
            k = k + 1
        end
    end
    if not flags.account or flags.account == "" then return nil end
    return flags
end

local function _parse_rclocal()
    local r = { has_esurfing=false, has_login=false, has_sms=false, has_interface=false, interface="", accounts={}, raw_lines={} }
    local f = io.open("/etc/rc.local", "r")
    if not f then return r end
    local content = f:read("*a") or ""
    f:close()
    if not content:find("esurfing") then return r end
    r.has_esurfing = true
    for line in (content.."\n"):gmatch("([^\n]*)\n") do
        if line:find("esurfing") then
            table.insert(r.raw_lines, line)
            local flags = _parse_line(line)
            if flags then
                table.insert(r.accounts, flags)
                if flags.password and flags.password ~= "" then r.has_login = true end
                if flags.sms and flags.sms ~= "" then r.has_sms = true end
                if flags.interface and flags.interface ~= "" then
                    r.has_interface = true
                    r.interface = flags.interface
                end
            end
        end
    end
    return r
end

local function _check_status()
    local bin_exists, bin_size, arch, router_arch = false, 0, "?", "?"
    local running, pids = false, {}
    if nixio and nixio.uname then
        local u = nixio.uname()
        if u and u.machine then router_arch = u.machine end
    end
    if nixio and nixio.fs and nixio.fs.access and nixio.fs.access("/usr/bin/esurfing") then
        bin_exists = true
        local st = nixio.fs.stat("/usr/bin/esurfing")
        if st and st.size then bin_size = tonumber(st.size) or 0 end
        local bf = io.open("/usr/bin/esurfing", "rb")
        if bf then
            local hdr = bf:read(64) or ""
            bf:close()
            local mid = hdr:sub(19, 20)
            local b = mid and string.byte(mid) or 0
            if hdr:find("AArch64") or b == 0xB7 then arch = "aarch64"
            elseif hdr:find("ARM aarch32") or b == 0x28 then arch = "arm"
            elseif hdr:find("x86%-64") or b == 0x3E then arch = "x86_64"
            elseif hdr:find("80386") or b == 0x03 then arch = "x86"
            elseif hdr:find("MIPS") or b == 0x08 then arch = "mips"
            else
                local ff = io.popen("file /usr/bin/esurfing 2>/dev/null")
                if ff then
                    local line = ff:read("*l") or ""
                    ff:close()
                    if line:find("aarch64") then arch = "aarch64"
                    elseif line:find("ARM,") then arch = "arm"
                    elseif line:find("x86%-64") or line:find("x86_64") then arch = "x86_64"
                    elseif line:find("i386") then arch = "x86"
                    elseif line:find("MIPS") then arch = "mips"
                    else arch = "unknown" end
                end
            end
        end
    end
    if nixio and nixio.fs and nixio.fs.dir then
        local p = nixio.fs.dir("/proc")
        if p then
            for entry in p do
                if entry:match("^%d+$") then
                    local cmdfile = io.open("/proc/" .. entry .. "/cmdline", "rb")
                    if cmdfile then
                        local c = cmdfile:read(2048) or ""
                        cmdfile:close()
                        if c:find("esurfing") and not c:find("cgi%-bin") and not c:find("luci") then
                            running = true
                            table.insert(pids, entry)
                        end
                    end
                end
            end
        end
    end
    return { bin_exists=bin_exists, bin_size=bin_size, arch=arch, router_arch=router_arch, running=running, pids=pids }
end

local function _get_accounts()
    local result = {}
    local ok, uci = pcall(require, "luci.model.uci")
    if not ok or not uci then return result end
    local ok2, cur = pcall(uci.cursor)
    if not ok2 or not cur then return result end
    pcall(function()
        cur:foreach("esurfinggo", "account", function(sec)
            table.insert(result, {
                name = sec[".name"],
                account = cur:get("esurfinggo", sec[".name"], "account") or "",
                password = cur:get("esurfinggo", sec[".name"], "password") or "",
                sms = cur:get("esurfinggo", sec[".name"], "sms") or "",
                interface = cur:get("esurfinggo", sec[".name"], "interface") or "",
            })
        end)
    end)
    return result
end
local _rclocal = _parse_rclocal()

-- ============ Auto-import rc.local accounts to UCI on first load (v1.3.25 restored) ============
-- v1.3.15 broke this by disabling auto-import. Restored from v1.3.10 logic.
local function _auto_import_rclocal()
    local ok, uci = pcall(function() return require("luci.model.uci").cursor() end)
    if not ok or not uci then return end
    local count = 0
    pcall(function() uci:foreach("esurfinggo", "account", function() count = count + 1 end) end)
    if count > 0 then return end  -- already has accounts, skip
    if #_rclocal.accounts == 0 then return end
    for _, a in ipairs(_rclocal.accounts) do
        local sid = uci:add("esurfinggo", "account")
        uci:set("esurfinggo", sid, "account", a.account)
        if a.password and a.password ~= "" then uci:set("esurfinggo", sid, "password", a.password) end
        if a.sms and a.sms ~= "" then uci:set("esurfinggo", sid, "sms", a.sms) end
        if a.interface and a.interface ~= "" then uci:set("esurfinggo", sid, "interface", a.interface) end
    end
    pcall(function() uci:save("esurfinggo"); uci:commit("esurfinggo") end)
end
_auto_import_rclocal()

-- ============ Check init.d autostart status ============
local function _autostart_status()
    local enabled = false
    local f = io.popen("/etc/init.d/esurfinggo enabled 2>/dev/null")
    if f then
        local s = f:read("*a") or ""
        f:close()
        enabled = s:find("enabled") ~= nil
    end
    return enabled
end

local _status = _check_status()
local _accounts = _get_accounts()
local _autostart = _autostart_status()

-- ============ Message dialog (parse ?msg= from URL) ============
local _msg = luci.http.formvalue("msg") or ""
if _msg == "" then
    -- try getany for ?msg=
    _msg = luci.http.getenv("QUERY_STRING") or ""
    local s, e = _msg:find("msg=")
    if s then
        _msg = _msg:sub(e + 1)
        local amp = _msg:find("&")
        if amp then _msg = _msg:sub(1, amp - 1) end
        _msg = luci.util.urlsafe_decode(_msg) or _msg
    else
        _msg = ""
    end
end
local _DIALOG_JS = ""
if _msg ~= "" and _msg:find("upload_failed:arch_mismatch") then
    -- format: upload_failed:arch_mismatch:<bin>_vs_<router>
    local detail = _msg:gsub("upload_failed:arch_mismatch:", "")
    local binarch, routerarch = detail:match("([^_]+)_vs_(.+)")
    local alert_text = "⛔ 架构不匹配 — 上传被拒绝\n\n路由器架构: " .. (routerarch or "?")
        .. "\n插件架构: " .. (binarch or "?")
        .. "\n\nARM 路由器只能装 arm/arm64 插件\nx86 路由器只能装 x86/x86_64 插件\n\n请下载与路由器架构匹配的 esurfing 二进制。"
    _DIALOG_JS = "<script>setTimeout(function(){alert('" .. alert_text .. "');}, 100);</script>"
elseif _msg:find("upload_failed:") then
    local reason = _msg:gsub("upload_failed:", "")
    _DIALOG_JS = "<script>setTimeout(function(){alert('上传失败: " .. reason .. "');}, 100);</script>"
elseif _msg:find("dial_failed:") then
    local reason = _msg:gsub("dial_failed:", "")
    local msg_map = {
        no_account_with_credentials = "拨号失败: 找不到有效账号(账号 1 必须有账密)",
        no_binary = "拨号失败: 插件未安装,请先在「热更新模块」段上传",
        no_section = "拨号失败: 未指定账号",
        empty_account_or_password = "拨号失败: 账号或密码为空",
    }
    local text = msg_map[reason] or ("拨号失败: " .. reason)
    _DIALOG_JS = "<script>setTimeout(function(){alert('" .. text .. "');}, 100);</script>"
elseif _msg:find("dial_ok_primary:") then
    local sec = _msg:gsub("dial_ok_primary:", "")
    _DIALOG_JS = "<script>setTimeout(function(){alert('✅ 启动模块成功\n账号段: " .. sec .. "\n走 procd 自动保活');}, 100);</script>"
elseif _msg:find("dial_ok:") then
    _DIALOG_JS = "<script>setTimeout(function(){alert('✅ 拨号成功');}, 100);</script>"
elseif _msg:find("restarted_primary:") then
    _DIALOG_JS = "<script>setTimeout(function(){alert('✅ 重启模块成功');}, 100);</script>"
elseif _msg == "refreshed" then
    -- no alert, just refresh
    _DIALOG_JS = ""
end

-- ============ CSS ============
local CSS = [[
<style>
.esg-row { display:flex; align-items:center; gap:8px; padding:5px 0; }
.esg-row .esg-label { font-weight:600; min-width:90px; }
.esg-row .esg-val { color:#374151; }
.esg-status { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px; vertical-align:middle; }
.esg-ok { background:#10b981; } .esg-warn { background:#f59e0b; } .esg-err { background:#ef4444; } .esg-off { background:#9ca3af; }
.esg-mini-btn { display:inline-block; padding:4px 10px; border-radius:4px; font-size:12px; color:#fff !important; border:none; cursor:pointer; text-decoration:none; }
.esg-mini-btn:hover { opacity:0.85; }
.esg-mini-green { background:#10b981; } .esg-mini-red { background:#ef4444; } .esg-mini-gray { background:#6b7280; }
.esg-acc-table { width:100%; border-collapse:collapse; margin-top:6px; }
.esg-acc-table th { padding:5px 6px; background:#f9fafb; border-bottom:2px solid #e5e7eb; font-size:12px; color:#6b7280; text-align:left; }
.esg-acc-table td { padding:5px 6px; border-bottom:1px solid #f3f4f6; font-size:13px; vertical-align:middle; }
.esg-acc-table tr:hover { background:#f9fafb; }
.esg-acc-num { color:#10b981; font-weight:700; font-size:13px; text-align:center; width:28px; }
.esg-pw-wrap { position:relative; display:inline-block; }
.esg-pw-wrap input { padding-right:26px !important; }
.esg-pw-toggle { position:absolute; right:3px; top:50%; transform:translateY(-50%); background:transparent; border:none; cursor:pointer; color:#6b7280; padding:2px 4px; font-size:13px; line-height:1; }
.esg-pw-toggle:hover { color:#374151; }
.esg-log { background:#1e293b; color:#e2e8f0; padding:8px 10px; border-radius:4px; max-height:140px; min-height:0; overflow:auto; font-family:Menlo,Consolas,monospace; font-size:11px; line-height:1.5; white-space:pre-wrap; word-wrap:break-word; }
.esg-log-empty { color:#9ca3af; background:#f3f4f6; border:1px dashed #d1d5db; padding:6px 10px; border-radius:4px; font-size:12px; text-align:center; }
.esg-log::-webkit-scrollbar { width:6px; height:6px; }
.esg-log::-webkit-scrollbar-thumb { background:#475569; border-radius:3px; }
.esg-rc-summary { background:#ecfeff; border:1px solid #a5f3fc; border-radius:4px; padding:6px 10px; font-size:12px; color:#0e7490; margin:6px 0; }
.esg-credit { font-size:11px; color:#9ca3af; text-align:right; margin-top:4px; }
.esg-credit a { color:#3b82f6; text-decoration:none; }
.esg-empty { padding:12px; text-align:center; color:#9ca3af; background:#f9fafb; border:1px dashed #d1d5db; border-radius:4px; font-size:12px; }
.esg-info { margin:4px 0 6px 0; color:#6b7280; font-size:12px; }
.esg-btn-row { display:flex; flex-wrap:wrap; gap:6px; align-items:center; margin-top:6px; }
</style>
]]

local function build_module_body()
    local html = CSS .. _DIALOG_JS
    local bin_color = _status.bin_exists and "esg-ok" or "esg-err"
    local bin_text = _status.bin_exists
        and string.format("已安装 · %s · %s", _status.arch,
            _status.bin_size > 1048576 and string.format("%.1f MB", _status.bin_size/1048576) or string.format("%d B", _status.bin_size))
        or "未安装 /usr/bin/esurfing"
    local run_color = _status.running and "esg-ok" or "esg-off"
    local run_text = _status.running and ("运行中 · PID " .. table.concat(_status.pids, ",")) or "未运行"
    local arch_no_bin = _status.arch == "?"
    local arch_unknown = _status.arch == "unknown"
    local arch_ok = (not arch_no_bin) and (not arch_unknown) and _status.arch == _status.router_arch
    local arch_color, arch_text
    if arch_no_bin then
        arch_color = "esg-off"
        arch_text = "? 未安装模块"
    elseif arch_unknown then
        arch_color = "esg-warn"
        arch_text = "⚠ 未知架构"
    elseif arch_ok then
        arch_color = "esg-ok"
        arch_text = "✓ 匹配"
    else
        arch_color = "esg-err"
        arch_text = "✗ 不匹配"
    end
    html = html .. '<div class="esg-row"><span class="esg-status ' .. bin_color .. '"></span><span class="esg-label">插件有无</span> <span class="esg-val">/usr/bin/esurfing : <b>' .. bin_text .. '</b></span></div>'
    html = html .. '<div class="esg-row"><span class="esg-status ' .. run_color .. '"></span><span class="esg-label">esurfing 进程</span> <span class="esg-val">esurfing : <b>' .. run_text .. '</b></span></div>'
    html = html .. '<div class="esg-row"><span class="esg-status ' .. arch_color .. '"></span><span class="esg-label">路由器架构</span> <span class="esg-val">' .. _status.router_arch .. ' · 架构匹配: <b>' .. arch_text .. '</b></span></div>'
    html = html .. '<div class="esg-btn-row">'
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/refresh" style="display:inline;"><button type="submit" class="cbi-button cbi-button-neutral">↻ 刷新</button></form> '
    -- Arch mismatch check
    local _arch_ok = _status.arch ~= "?" and _status.arch ~= "unknown" and _status.arch == _status.router_arch
    local _arch_mismatch = (not _arch_ok) and _status.bin_exists
    local _arch_warn = ''
    if _arch_mismatch then
        _arch_warn = '<div id="esg-arch-warn" style="background:#fee2e2; border:1px solid #fca5a5; border-radius:4px; padding:8px 10px; margin:6px 0; color:#7f1d1d;">'
            .. '<b>⛔ 架构不匹配 — 已禁用启动按钮</b><br/>'
            .. '<span style="font-size:11px;">路由器架构: <code>' .. _status.router_arch .. '</code> · 插件架构: <code>' .. _status.arch .. '</code><br/>'
            .. 'ARM 路由装上 x86 插件无法运行。x86 路由装上 ARM 插件也无法运行。请先在「热更新模块」段上传正确架构的二进制。</span></div>'
    end
    html = html .. _arch_warn
    -- Primary (account #1 only) - default safe path; disabled if arch mismatch OR no binary
    local _start_disabled = _arch_mismatch or (not _status.bin_exists)
    local _start_disabled_attr = _start_disabled and ' disabled title="架构不匹配或插件未安装"' or ''
    local _start_onclick = _arch_mismatch and ' onclick="alert(\'架构不匹配\\n路由器: ' .. _status.router_arch .. '\n插件: ' .. _status.arch .. '\n请先上传正确架构的插件\');return false;"' or ''
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/dial_primary" style="display:inline;"><button type="submit" class="cbi-button cbi-button-positive"' .. _start_disabled_attr .. _start_onclick .. '>▶ 启动模块</button></form> '
    local _restart_disabled = _arch_mismatch or (not _status.bin_exists)
    local _restart_disabled_attr = _restart_disabled and ' disabled title="架构不匹配或插件未安装"' or ''
    local _restart_onclick = _arch_mismatch and ' onclick="alert(\'架构不匹配\\n无法重启。请先修复插件架构\');return false;"' or ''
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/restart_primary" style="display:inline;"><button type="submit" class="cbi-button cbi-button-warning"' .. _restart_disabled_attr .. _restart_onclick .. '>↻ 重启模块</button></form> '
    -- Stop button: always enabled (you may want to kill misbehaving processes)
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/stop_all" style="display:inline;" onsubmit="return confirm(\'确认停止所有拨号?\');"><button type="submit" class="cbi-button cbi-button-negative">■ 停止模块</button></form>'
    html = html .. '</div>'
    -- Multi-cast subsection (collapsed by default, hidden if no extra accounts)
    if #_accounts > 1 then
        html = html .. '<div class="esg-multicast-block" style="background:#f0f9ff; border:1px solid #bae6fd; border-radius:4px; padding:8px 10px; margin:6px 0;">'
        html = html .. '<div style="font-weight:600; margin-bottom:3px; color:#075985; font-size:12px;">📡 多播模式 (高级 · 多个账号同时拨号)</div>'
        html = html .. '<div style="font-size:11px; color:#0c4a6e; margin-bottom:5px;">⚠️ 多账号可能违反校园网规定,部分学校会检测到封号。默认只跑账号 1。</div>'
        local _multi_disabled_attr = (not _status.arch ~= "?" and _status.arch ~= "unknown" and _status.arch == _status.router_arch) and (_status.arch ~= "?" and _status.arch ~= "unknown" and _status.arch == _status.router_arch or true) and (_status.arch ~= "?" and _status.arch ~= "unknown" and _status.arch ~= _status.router_arch) and ' disabled title="架构不匹配"' or ''
        local _multi_disabled = (not (_status.arch ~= "?" and _status.arch ~= "unknown" and _status.arch == _status.router_arch))
        local _multi_disabled_attr2 = _multi_disabled and ' disabled title="架构不匹配"' or ''
        local _multi_onclick = _multi_disabled and ' onclick="alert(\'架构不匹配，无法启动多播\');return false;"' or ''
        html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/start_all" style="display:inline;"><button type="submit" class="cbi-button cbi-button-positive"' .. _multi_disabled_attr2 .. _multi_onclick .. '>🚀 启动多播 (所有账号)</button></form> '
        html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/restart_all" style="display:inline;"><button type="submit" class="cbi-button cbi-button-warning"' .. _multi_disabled_attr2 .. _multi_onclick .. '>↻ 重启多播</button></form> '
        html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/stop_all" style="display:inline;" onsubmit="return confirm(\'确认停止所有多播进程?\');"><button type="submit" class="cbi-button cbi-button-negative">■ 停止多播</button></form>'
        html = html .. '</div>'
    end
    html = html .. '<div class="esg-credit">模块来源: <a href="https://github.com/xxmod/EsurfingGo" target="_blank">github.com/xxmod/EsurfingGo</a> · 感谢原作者 <strong>xxmod</strong></div>'
    return html
end

local function build_upload_body()
    -- MD5 of installed binary
    local installed_md5 = ""
    if nixio.fs.access("/usr/bin/esurfing") then
        -- nixio.crypto may not exist on all OpenWrt builds; use shell md5sum
        local f = io.popen("md5sum /usr/bin/esurfing 2>/dev/null")
        if f then
            local out = f:read("*l")
            f:close()
            if out then
                installed_md5 = out:match("^(%x+)") or out:sub(1,32)
            end
        end
    end
    local md5_display = installed_md5 ~= ""
        and '<div style="font-size:11px; color:#059669; margin:4px 0;">📦 当前内部模块 MD5: <code style="background:#d1fae5; padding:2px 6px; border-radius:3px; font-size:11px;">' .. installed_md5 .. '</code></div>'
        or '<div style="font-size:11px; color:#dc2626; margin:2px 0;">⚠ 当前未安装模块 (/usr/bin/esurfing 不存在)</div>'

    local html = '<div style="background:#fffbeb; border:1px solid #fde68a; border-radius:4px; padding:8px 10px; margin:4px 0;">'
    html = html .. '<div style="font-weight:600; margin-bottom:3px; color:#92400e; font-size:12px;">📤 上传并热更新模块</div>'
    html = html .. '<div style="font-size:11px; color:#78350f; margin-bottom:5px;">自动检测 ELF 架构，避免 ARM 路由装上 x86 模块。上传后覆盖 <code>/usr/bin/esurfing</code>。</div>'
    html = html .. md5_display
    html = html .. '<form id="esfg_upload_form" method="post" action="#" style="display:flex; gap:6px; align-items:center;">'
    html = html .. '<input type="file" name="esfg_file" id="esfg_file_input" class="cbi-input-file" style="flex:1;" onchange="esfg_show_md5(this)" />'
    html = html .. '<span id="esfg_upload_md5" style="font-size:10px; color:#9ca3af; min-width:80px;"></span>'
    html = html .. '<button type="submit" class="cbi-button cbi-button-positive" id="esfg_upload_btn">📤 上传并安装</button>'
    html = html .. '</form>'
    html = html .. '</div>'
    -- Progress overlay
    html = html .. [[
<div id="esfg_progress_overlay" style="display:none; position:fixed; top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.55);z-index:9999;justify-content:center;align-items:center;">
<div style="background:#fff;border-radius:8px;padding:24px 28px;min-width:320px;max-width:420px;box-shadow:0 8px 32px rgba(0,0,0,0.2);text-align:center;">
<div id="esfg_progress_icon" style="font-size:36px;margin-bottom:12px;">⏳</div>
<div id="esfg_progress_text" style="font-size:14px;font-weight:600;color:#1f2937;margin-bottom:8px;">正在上传...</div>
<div style="background:#e5e7eb;border-radius:99px;height:8px;overflow:hidden;margin:12px 0;">
<div id="esfg_progress_bar" style="background:linear-gradient(90deg,#3b82f6,#2563eb);height:100%;width:0%;border-radius:99px;transition:width 0.3s;"></div>
</div>
<div id="esfg_progress_percent" style="font-size:12px;color:#6b7280;">0%</div>
<div id="esfg_progress_detail" style="font-size:11px;color:#9ca3af;margin-top:6px;"></div>
<button id="esfg_progress_close" onclick="document.getElementById('esfg_progress_overlay').style.display='none'" style="display:none;margin-top:14px;padding:6px 20px;background:#3b82f6;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:13px;">关闭</button>
</div></div>
<script>
(function(){
var form=document.getElementById('esfg_upload_form');
if(!form)return;
form.addEventListener('submit',function(e){
e.preventDefault();
var fileInput=document.getElementById('esfg_file_input');
var file=fileInput.files[0];
if(!file){alert('请先选择要上传的文件');return;}
var overlay=document.getElementById('esfg_progress_overlay');
var bar=document.getElementById('esfg_progress_bar');
var pct=document.getElementById('esfg_progress_percent');
var icon=document.getElementById('esfg_progress_icon');
var txt=document.getElementById('esfg_progress_text');
var detail=document.getElementById('esfg_progress_detail');
var btn=document.getElementById('esfg_upload_btn');
var closeBtn=document.getElementById('esfg_progress_close');
overlay.style.display='flex';btn.disabled=true;
bar.style.width='0%';pct.textContent='0%';
icon.textContent='⏳';txt.textContent='正在编码文件...';
detail.textContent=file.name+' ('+(file.size/1024).toFixed(0)+' KB)';
bar.style.background='linear-gradient(90deg,#3b82f6,#2563eb)';
closeBtn.style.display='none';
// v1.4.11: use FormData multipart (avoids ucode 100KB URL-encoded limit)
var formData = new FormData();
formData.append('esfg_file', file);
icon.textContent='📤';txt.textContent='正在上传至路由器...';
bar.style.width='5%';pct.textContent='5%';
detail.textContent=file.name+' ('+(file.size/1024).toFixed(0)+' KB)';
var xhr=new XMLHttpRequest();
xhr.open('POST','/cgi-bin/luci/admin/services/esurfing/upload_bin',true);
xhr.upload.onprogress=function(pev){
if(pev.lengthComputable){
var p=Math.round(5+pev.loaded/pev.total*70);
bar.style.width=p+'%';pct.textContent=p+'%';
}
};
xhr.onload=function(){
bar.style.width='100%';pct.textContent='100%';
var r=(xhr.responseText||'').trim();
if(xhr.status===200 && r.indexOf('OK')>=0){
icon.textContent='✅';txt.textContent='上传成功！热更新已完成';
bar.style.background='linear-gradient(90deg,#059669,#10b981)';
detail.textContent=r;closeBtn.style.display='inline-block';
setTimeout(function(){location.reload();},1500);
}else{
icon.textContent='❌';
var errMsg=r.substring(0,80).replace('ERR:','');
txt.textContent='上传失败';bar.style.background='linear-gradient(90deg,#dc2626,#ef4444)';
detail.textContent=errMsg||'未知错误';btn.disabled=false;closeBtn.style.display='inline-block';
}
};
xhr.onerror=function(){
bar.style.width='100%';bar.style.background='linear-gradient(90deg,#dc2626,#ef4444)';
icon.textContent='❌';txt.textContent='网络错误';
detail.textContent='请检查路由器连接';btn.disabled=false;closeBtn.style.display='inline-block';
};
xhr.send(formData);
});
})();
</script>]]
    -- Client-side MD5 computation (minimal inline)
    html = html .. [[
<script>
function esfg_md5_js(t){function e(t,e){return t<<e|t>>>32-e}function n(t,e){var n,o,i,r,s;return i=2147483648&t,r=2147483648&e,s=(1073741823&t)+(1073741823&e),1&(n=1073741824&t)&(o=1073741824&e)?2147483648^s^i^r:n|o?1073741824&s?3221225472^s^i^r:1073741824^s^i^r:s^i^r}function o(t,o,i,r,s,a,u){return t=n(t,n(n(function(t,e){return t^e}(o,i),r),u),n(e(o,s||a||0),i))}function i(t,e){return t<<e|t>>>32-e}function r(t,e){var n,o,i,r,s,a=[];for(t=e?function(t){for(var e=[],n=0;n<t.length;n+=2)e.push(String.fromCharCode(parseInt(t.substr(n,2),16)));return e.join("")}(t):function(t){for(var e,n=t.length,o=n+8,i=16*((o-o%64)/64+1),r=Array(i-1),s=0,a=0;a<n;)s=a%4*8,e=(a-a%4)/4,r[e]|=t.charCodeAt(a)<<s,a++;return s=a%4*8,e=(a-a%4)/4,r[e]|=128<<s,r[i-2]=n<<3,r[i-1]=n>>>29,r}(t),s=1732584193,a=4023233417,u=2562383102,c=271733878,a=4023233417,s=1732584193,n=0;n<r.length;n+=16)o=s,i=a;for(var u=c,f=d,l=0;l<80;l++){if(l<16)v[l]=r[n+l];else{var p=v[l-3]^v[l-8]^v[l-14]^v[l-16];v[l]=p<<1|p>>>31}var h=o+i>>>0,g=function(t,e,n,o,i,r){var s=e&n|~e&o,a=e^n^o,u=e&n|e&o|n&o,c=e^n;return t<20?s+1518500249:t<40?a+1859775393:t<60?u+2400959708:c+3395469782}(l,o,i,u),y=e(h,5)+g+f+v[l]+(l<20?1518500249:l<40?1859775393:l<60?2400959708:3395469782)>>>0;f=u,u=i,i=e(o,30)>>>0,o=y>>>0}s=n(s,o),a=n(a,i),u=n(u,c),c=n(c,f)}return(s>>>0).toString(16)+(a>>>0).toString(16)+(u>>>0).toString(16)+(c>>>0).toString(16)}var d=1732584193,v=[];return r(t,!1)}
function esfg_show_md5(input){
    var span=document.getElementById('esfg_upload_md5');
    var file=input.files[0];
    if(!file){span.innerHTML='';return;}
    span.style.color='#6b7280';span.innerHTML='⏳ 计算中...';
    var reader=new FileReader();
    reader.onload=function(e){
        try{var md5=esfg_md5_js(e.target.result);span.innerHTML='MD5: <code style="background:#e5e7eb;padding:1px 4px;border-radius:3px;font-size:10px;">'+md5+'</code>';span.style.color='#059669';}
        catch(err){span.innerHTML='计算失败';span.style.color='#dc2626';}
    };
    reader.onerror=function(){span.innerHTML='读取失败';span.style.color='#dc2626';};
    reader.readAsBinaryString(file);
}
</script>]]
    return html
end

local function build_autostart_body()
    local rc_color = _autostart and "esg-ok" or "esg-off"
    local rc_text = _autostart and "已开启 (/etc/init.d/esurfinggo enable)" or "未开启 (/etc/init.d/esurfinggo disable)"
    local html = '<div class="esg-row"><span class="esg-status ' .. rc_color .. '"></span><span class="esg-label">开机自启</span> <span class="esg-val">' .. rc_text .. '</span></div>'
    html = html .. '<div class="esg-info">开启后系统启动时自动执行 <code>/etc/init.d/esurfinggo start</code>，无需再手动 rc.local。</div>'
    html = html .. '<div class="esg-btn-row">'
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/toggle_autostart" style="display:inline;">'
    html = html .. '<input type="hidden" name="current" value="' .. (_autostart and "1" or "0") .. '" />'
    html = html .. '<button type="submit" class="cbi-button ' .. (_autostart and "cbi-button-negative" or "cbi-button-positive") .. '">' .. (_autostart and "关闭" or "开启") .. '开机启动</button>'
    html = html .. '</form></div>'
    return html
end

local function build_account_body()
    local html = '<div class="esg-info">当前 <b>' .. #_accounts .. '</b> / 10 个账号 · <b style="color:#dc2626;">账号 1 = 主拨号账号</b>(「启动模块」按钮用这个) · 账号 2+ = 多播副账号(需点「启动多播」)</div>'
    html = html .. '<div class="esg-btn-row">'
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/add_account" style="display:inline;">'
    html = html .. '<button type="submit" class="cbi-button cbi-button-positive"' .. (#_accounts >= 10 and ' disabled' or '') .. '>+ 添加多播账号</button></form>'
    html = html .. '<button type="button" class="cbi-button cbi-button-positive" onclick="esfg_save_accounts()">💾 保存所有账号密码</button>'
    html = html .. '</div>'

    if #_accounts == 0 then
        html = html .. '<div class="esg-empty">📭 暂无账号 — 点击「+ 添加账号」创建，或在「/etc/rc.local 导入」中读取自动导入</div>'
    else
        html = html .. '<table class="esg-acc-table">'
        html = html .. '<colgroup><col style="width:28px;"><col style="width:120px;"><col style="width:140px;"><col style="width:90px;"><col style="width:90px;"><col style="width:60px;"></colgroup>'
        html = html .. '<thead><tr><th>#</th><th>账号</th><th>密码</th><th>短信</th><th>状态/操作</th><th>删除</th></tr></thead><tbody>'
        for idx, acc in ipairs(_accounts) do
            local pid_file = "/tmp/esurfing_" .. acc.name .. ".pid"
            local running, pid = false, ""
            local pf = io.open(pid_file, "r")
            if pf then pid = pf:read("*l") or ""; pf:close()
                if pid ~= "" then
                    local cf = io.open("/proc/" .. pid .. "/cmdline", "rb")
                    if cf then local cmd = cf:read(64) or ""; cf:close(); if cmd:find("esurfing") then running = true end end
                end
            end
            local pw_id = "pw_" .. acc.name
            html = html .. '<tr>'
            html = html .. '<td class="esg-acc-num">' .. idx .. '</td>'
            html = html .. '<td><input type="text" name="account_' .. acc.name .. '" value="' .. acc.account .. '" maxlength="11" placeholder="11位账号" class="cbi-input-text" style="width:110px;" /></td>'
            html = html .. '<td><div class="esg-pw-wrap"><input type="password" id="' .. pw_id .. '" name="password_' .. acc.name .. '" value="' .. acc.password .. '" placeholder="密码" class="cbi-input-text" style="width:130px;" /><button type="button" class="esg-pw-toggle" onclick="var x=document.getElementById(\'' .. pw_id .. '\');x.type=(x.type===\'password\'?\'text\':\'password\');this.textContent=(x.type===\'password\'?\'👁\':\'🙈\');" title="显示/隐藏密码">👁</button></div></td>'
            html = html .. '<td><input type="text" name="sms_' .. acc.name .. '" value="' .. acc.sms .. '" maxlength="6" placeholder="6位" class="cbi-input-text" style="width:70px;" /></td>'
            html = html .. '<td>'
            if running then
                html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/stop_one?section=' .. acc.name .. '" style="display:inline;" onsubmit="return confirm(\'确认停止账号 ' .. (acc.account ~= "" and acc.account or acc.name) .. '?\');">'
                html = html .. '<button type="submit" class="esg-mini-btn esg-mini-green" title="PID ' .. pid .. '">● 运行中</button></form>'
            else
                html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/dial?section=' .. acc.name .. '" style="display:inline;">'
                html = html .. '<button type="submit" class="esg-mini-btn esg-mini-gray">▶ 拨号</button></form>'
            end
            html = html .. '</td>'
            html = html .. '<td><form method="post" action="/cgi-bin/luci/admin/services/esurfing/delete_account?section=' .. acc.name .. '" style="display:inline;" onsubmit="return confirm(\'确认删除账号 ' .. (acc.account ~= "" and acc.account or acc.name) .. '?\\n（最少保留 1 行）\');">'
            html = html .. '<button type="submit" class="esg-mini-btn esg-mini-red">删除</button></form></td>'
            html = html .. '</tr>'
        end
        html = html .. '</tbody></table>'
        html = html .. [[
<script>
function esfg_save_accounts(){
var inputs=document.querySelectorAll('[name^="account_"],[name^="password_"],[name^="sms_"],[name^="interface_"]');
var params=[];
for(var i=0;i<inputs.length;i++){
params.push(encodeURIComponent(inputs[i].name)+'='+encodeURIComponent(inputs[i].value));
}
var xhr=new XMLHttpRequest();
xhr.open('POST','/cgi-bin/luci/admin/services/esurfing/save_accounts',true);
xhr.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
xhr.onload=function(){location.reload();};
xhr.onerror=function(){alert('保存失败，请检查网络连接');};
xhr.send(params.join('&'));
}
</script>]]
    end
    return html
end

local function build_rclocal_body()
    local html = ""
    local summary
    if _rclocal.has_esurfing then
        summary = string.format("检测到 <b>%d</b> 个 esurfing 命令", #_rclocal.accounts)
        if _rclocal.has_login then summary = summary .. " · 含密码" end
        if _rclocal.has_sms then summary = summary .. " · 含短信" end
        if _rclocal.has_interface then summary = summary .. " · 网卡=" .. _rclocal.interface end
    else
        summary = "rc.local 中无 esurfing 命令"
    end
    html = html .. '<div class="esg-rc-summary">' .. summary .. '</div>'
    html = html .. '<div class="esg-btn-row">'
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/import_rclocal" style="display:inline;">'
    html = html .. '<button type="submit" class="cbi-button cbi-button-neutral"' .. (not _rclocal.has_esurfing and ' disabled' or '') .. '>📥 读取并导入到 web</button></form> '
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/view_rclocal" style="display:inline;" target="_blank">'
    html = html .. '<button type="submit" class="cbi-button cbi-button-neutral">📄 查看完整 rc.local</button></form>'
    html = html .. '</div>'
    -- Text file import (v1.3.38)
    html = html .. '<div class="esg-info" style="margin-top:6px;">💡 也可从 .txt/.md/.json 文档导入：将账号密码粘贴进去即可智能识别</div>'
    html = html .. '<div style="margin-top:4px; display:flex; gap:6px; align-items:center;">'
    html = html .. '<input type="file" id="esfg_txt_file" accept=".txt,.md,.json,.csv,.log" style="display:none;" onchange="esfg_handle_text_file(this)" />'
    html = html .. '<button type="button" class="cbi-button cbi-button-neutral" onclick="document.getElementById(\'esfg_txt_file\').click()">📂 从文档导入</button>'
    html = html .. '<span id="esfg_txt_status" style="font-size:11px; color:#6b7280;"></span>'
    html = html .. '</div>'
    -- Smart text parsing JS
    html = html .. [[
<script>
function esfg_handle_text_file(input) {
    var file = input.files[0];
    var status = document.getElementById('esfg_txt_status');
    if (!file) { status.innerHTML = ''; return; }
    status.style.color = '#6b7280';
    status.innerHTML = '⏳ 读取中...';
    var reader = new FileReader();
    reader.onload = function(e) {
        var text = e.target.result;
        var pairs = esfg_parse_accounts(text);
        if (pairs.length === 0) {
            status.style.color = '#dc2626';
            status.innerHTML = '❌ 未识别到账号密码，请检查格式';
            return;
        }
        var preview = pairs.map(function(p, i) {
            return (i+1) + '. ' + p.acc + (p.sms ? ' (短信:' + p.sms + ')' : '');
        }).join('\\n');
        var msg = '📋 检测到 ' + pairs.length + ' 个账号:\\n\\n' + preview + '\\n\\n确认导入到拨号列表？';
        if (!confirm(msg)) { status.innerHTML = '已取消'; return; }
        esfg_post_accounts(pairs, status);
    };
    reader.onerror = function() {
        status.style.color = '#dc2626';
        status.innerHTML = '❌ 读取文件失败';
    };
    reader.readAsText(file, 'UTF-8');
}

// Smart account/password parser - supports multiple formats
function esfg_parse_accounts(text) {
    var pairs = [];
    var seen = {};
    function add(acc, pwd, sms) {
        acc = (acc || '').replace(/^[\\s\"'\\[\\]{}()]+|[\\s\"'\\[\\]{}()]+$/g, '').trim();
        pwd = (pwd || '').replace(/^[\"']+|[\"']+$/g, '').trim();
        sms = (sms || '').replace(/[^0-9]/g, '');
        if (!acc) return;
        // Require account to be 11-digit mobile number
        if (!/^\\d{11}$/.test(acc)) {
            // If password is numeric 6-digit, swap (common user mistake: pwd first)
            if (/^\\d{6}$/.test(pwd) && /^\\d{11}$/.test(pwd)) {
                var tmp = acc; acc = pwd; pwd = tmp;
            } else {
                return; // Skip non-phone-number entries
            }
        }
        if (pwd === '') {
            // Look for 6-digit near this account
            var near = text.substr(Math.max(0, text.indexOf(acc) - 30), 80);
            var m = near.match(/\\b\\d{6}\\b/g);
            if (m) pwd = m[m.length - 1];
        }
        if (acc !== '' && !seen[acc]) {
            seen[acc] = true;
            pairs.push({ acc: acc, pwd: pwd, sms: sms || '' });
        }
    }

    var clean = text.replace(/\\r/g, '');

    // Strategy 1: esurfing command line: esurfing -u 13800138000 -p abc123 -s 123456
    var re1 = /esurfing\\s+[^\\n]*?-u\\s+['\"]?(\\d{11})['\"]?[^\\n]*?-p\\s+['\"]?([^\\s'\"]+)['\"]?/g;
    var m;
    while ((m = re1.exec(clean)) !== null) {
        var sms1 = '';
        var full = clean.substring(m.index, clean.indexOf('\\n', m.index) || clean.length);
        var sm = full.match(/-s\\s+['\"]?(\\d{6})['\"]?/);
        if (sm) sms1 = sm[1];
        add(m[1], m[2], sms1);
    }

    // Strategy 2: JSON array: [{"account":"138...","password":"..."}]
    try {
        var obj = JSON.parse(clean);
        var arr = Array.isArray(obj) ? obj : [obj];
        arr.forEach(function(o) {
            var a = o.account || o.acc || o.user || o.username || o.phone || o.mobile || o['账号'] || '';
            var p = o.password || o.pwd || o.pass || o['密码'] || '';
            var s = o.sms || o.code || o['短信'] || '';
            add(String(a), String(p), String(s));
        });
    } catch(e) { /* not JSON */ }

    // Strategy 3: Key-value lines: 账号:13800138000  密码:abc123
    var lines = clean.split('\\n');
    var curAcc = '', curPwd = '', curSms = '';
    lines.forEach(function(line) {
        line = line.trim();
        if (!line || line[0] === '#') return;
        // 账号:xxx / 密码:xxx / 短信:xxx
        var kv = line.match(/^(账号|帐户|account|user|username|手机|phone)[\\s:：=]+(\\S+)/i);
        if (kv) { if (curAcc && curPwd) add(curAcc, curPwd, curSms); curAcc = kv[2]; curPwd = ''; curSms = ''; return; }
        kv = line.match(/^(密码|password|pwd|pass)[\\s:：=]+(\\S+)/i);
        if (kv) { curPwd = kv[2]; return; }
        kv = line.match(/^(短信|sms|code|验证码)[\\s:：=]+(\\S+)/i);
        if (kv) { curSms = kv[2]; return; }
        // Strategy 4: 11-digit + anything on same or next line
        var phone = line.match(/\\b(\\d{11})\\b/);
        if (phone) {
            if (curAcc && curPwd) add(curAcc, curPwd, curSms);
            curAcc = phone[1];
            // Check if password follows on same line
            var rest = line.substring(line.indexOf(phone[1]) + 11).trim();
            var pwdMatch = rest.match(/[\\s,:;|\\t]+(\\S+)/);
            if (pwdMatch) {
                var candidate = pwdMatch[1];
                if (!/^\\d{11}$/.test(candidate)) { curPwd = candidate; }
            }
            curSms = '';
            return;
        }
        // If we have an account but no password yet, treat this line as password
        if (curAcc && !curPwd && line.length >= 1 && line.length <= 64 && !line.match(/^[\\s:：=#-]/)) {
            curPwd = line;
            // Also check for SMS code nearby
            var smsMatch = line.match(/\\b(\\d{6})\\b/);
            if (smsMatch && line.indexOf(curPwd) !== line.indexOf(smsMatch[1])) curSms = smsMatch[1];
        }
    });
    if (curAcc && curPwd) add(curAcc, curPwd, curSms);

    // Strategy 5: CSV / tab-separated: 13800138000,abc123,123456
    lines.forEach(function(line) {
        line = line.trim();
        var parts = line.split(/[\\t,;|]+/);
        if (parts.length >= 2) {
            var a = parts[0].trim(), p = parts[1].trim(), s = (parts[2] || '').trim();
            if (/^\\d{11}$/.test(a) && p.length >= 1) add(a, p, s);
        }
    });

    return pairs;
}

// POST parsed accounts to server
function esfg_post_accounts(pairs, status) {
    status.style.color = '#6b7280';
    status.innerHTML = '⏳ 正在导入...';
    var body = 'count=' + pairs.length;
    pairs.forEach(function(p, i) {
        body += '&acc' + i + '=' + encodeURIComponent(p.acc);
        body += '&pwd' + i + '=' + encodeURIComponent(p.pwd);
        if (p.sms) body += '&sms' + i + '=' + encodeURIComponent(p.sms);
    });
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/cgi-bin/luci/admin/services/esurfing/import_text', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.onload = function() {
        // Refresh to show new accounts (controller will redirect, but XHR may follow)
        location.reload();
    };
    xhr.onerror = function() {
        status.style.color = '#dc2626';
        status.innerHTML = '❌ 网络错误，请重试';
    };
    xhr.send(body);
}
</script>]]
    return html
end

local function build_log_body()
    local f = io.open("/tmp/esurfing.log", "r")
    local content = ""
    if f then content = f:read("*a") or ""; f:close() end
    if content == "" then
        local html = '<div class="esg-log-empty">暂无日志</div>'
        html = html .. '<div style="margin-top:4px; text-align:right;">'
        html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/log_view" style="display:inline;" target="_blank">'
        html = html .. '<button type="submit" class="cbi-button cbi-button-neutral">查看完整日志 →</button></form></div>'
        return html
    end
    local lines = {}
    for line in content:gmatch("[^\n]+") do table.insert(lines, line) end
    local preview_lines
    if #lines > 20 then
        local start_idx = #lines - 19
        local new_lines = {}
        for i = start_idx, #lines do table.insert(new_lines, lines[i]) end
        preview_lines = new_lines
    else
        preview_lines = lines
    end
    local preview = table.concat(preview_lines, "\n"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local html = '<div class="esg-log">' .. preview .. '</div>'
    html = html .. '<div style="margin-top:4px; text-align:right;">'
    html = html .. '<form method="post" action="/cgi-bin/luci/admin/services/esurfing/log_view" style="display:inline;" target="_blank">'
    html = html .. '<button type="submit" class="cbi-button cbi-button-neutral">查看完整日志 →</button></form></div>'
    return html
end

-- ============ Section 1: Module status ============
s = m:section(NamedSection, "main", "esurfinggo", translate("模块状态"))
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_module_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_module_body() end

-- ============ Section 2: Hot update (v1.3.29: revert to raw HTML, action routes through LuCI) ============
s = m:section(NamedSection, "main", "esurfinggo", translate("热更新模块"))
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_upload_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_upload_body() end

-- ============ Section 3: Autostart ============
s = m:section(NamedSection, "main", "esurfinggo", translate("开机启动"))
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_autostart_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_autostart_body() end

-- ============ Section 4: Account list ============
s = m:section(NamedSection, "main", "esurfinggo", translate("拨号账号列表") .. " · " .. #_accounts .. " / 10")
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_account_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_account_body() end

-- ============ Section 5: rc.local import ============
s = m:section(NamedSection, "main", "esurfinggo", translate("/etc/rc.local 导入"))
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_rclocal_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_rclocal_body() end

-- ============ Section 6: Log ============
s = m:section(NamedSection, "main", "esurfinggo", translate("运行日志"))
s.addremove = false
s.anonymous = true
o = s:option(DummyValue, "_log_body", "")
o.rawhtml = true
o.cfgvalue = function(self, section) return build_log_body() end

return m
