-- EsurfingGo Controller v1.4.11
-- v1.4.11: multipart/form-data upload (avoids ucode 100KB URL-encoded limit)
-- v1.4.9: fix arch display when no binary installed
-- v1.4.8: fix IPK format, unify build pipeline
-- v1.4.6: sync init.d sms flag fix -c -> -s
-- v1.4.5: fix Lua 5.1 "\x7f" -> string.char(127) for ELF check
-- v1.3.38: text file import for accounts (txt/md/json/csv -> auto parse)

module("luci.controller.esurfinggo", package.seeall)

function index()
    entry({"admin", "services", "esurfing"}, cbi("esurfinggo"), "天翼校园网面板", 80).dependent = false
    entry({"admin", "services", "esurfing", "dial"}, call("action_dial")).leaf = true
    entry({"admin", "services", "esurfing", "dial_primary"}, call("action_dial_primary")).leaf = true
    entry({"admin", "services", "esurfing", "restart_primary"}, call("action_restart_primary")).leaf = true
    entry({"admin", "services", "esurfing", "refresh"}, call("action_refresh")).leaf = true
    entry({"admin", "services", "esurfing", "stop_one"}, call("action_stop_one")).leaf = true
    entry({"admin", "services", "esurfing", "start_all"}, call("action_start_all")).leaf = true
    entry({"admin", "services", "esurfing", "restart_all"}, call("action_restart_all")).leaf = true
    entry({"admin", "services", "esurfing", "stop_all"}, call("action_stop_all")).leaf = true
    entry({"admin", "services", "esurfing", "log_view"}, call("action_log_view")).leaf = true
    entry({"admin", "services", "esurfing", "upload"}, call("action_upload")).leaf = true
    entry({"admin", "services", "esurfing", "upload_bin"}, call("action_upload_bin")).leaf = true
    entry({"admin", "services", "esurfing", "add_account"}, call("action_add_account")).leaf = true
    entry({"admin", "services", "esurfing", "delete_account"}, call("action_delete_account")).leaf = true
    entry({"admin", "services", "esurfing", "save_accounts"}, call("action_save_accounts")).leaf = true
    entry({"admin", "services", "esurfing", "toggle_autostart"}, call("action_toggle_autostart")).leaf = true
    entry({"admin", "services", "esurfing", "import_rclocal"}, call("action_import_rclocal")).leaf = true
    entry({"admin", "services", "esurfing", "import_text"}, call("action_import_text")).leaf = true
    entry({"admin", "services", "esurfing", "view_rclocal"}, call("action_view_rclocal")).leaf = true
end

-- Resolve interface name to esurfing -n index (e.g., "mv0" -> 6)
local function resolve_interface_index(iface)
    if not iface or iface == "" then return nil end
    -- If already a number, return as-is
    if iface:match("^%d+$") then return iface end
    -- Try esurfing -s to get interface->index mapping
    local h = io.popen("/usr/bin/esurfing -s 2>/dev/null")
    if h then
        for line in h:lines() do
            -- Match patterns like:  "mv0"="6" or mv0 = 6 or mv0(6)
            local name, idx = line:match("\"?(%S+)\"?[=:]%s*\"?(%d+)\"?")
            if name and idx and name == iface then
                h:close()
                return idx
            end
        end
        h:close()
    end
    -- Fallback: use interface name directly (may fail with esurfing)
    return iface
end

-- Redirect back to the CBI page (the only response method we trust)
local function redirect_back(msg)
    local http = require("luci.http")
    local url = "/cgi-bin/luci/admin/services/esurfing"
    if msg and msg ~= "" then
        url = url .. "?msg=" .. http.urlencode(msg)
    end
    http.redirect(url)
end

-- Extract form value (POST or QUERY_STRING)
local function formvalue(key)
    local http = require("luci.http")
    if http and http.formvalue then
        local v = http.formvalue(key)
        if v then return tostring(v) end
    end
    -- Fallback: parse QUERY_STRING
    local qs = nixio.getenv("QUERY_STRING") or ""
    for k, v in string.gmatch(qs, "([^&=]+)=([^&]*)") do
        if k == key then
            v = v:gsub("+", " ")
            v = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            return v
        end
    end
    return ""
end

-- ============ Action: dial a single account ============
function action_dial()
    local section = formvalue("section")
    if section == "" then
        redirect_back("dial_failed:no_section")
        return
    end

    local uci = require("luci.model.uci").cursor()
    local account = uci:get("esurfinggo", section, "account") or ""
    local password = uci:get("esurfinggo", section, "password") or ""

    if account == "" or password == "" then
        redirect_back("dial_failed:empty_account_or_password")
        return
    end

    if not nixio.fs.access("/usr/bin/esurfing") then
        redirect_back("dial_failed:no_binary")
        return
    end

    -- Kill any existing instance for this section first, then start new one
    local pidfile = "/tmp/esurfing_" .. section .. ".pid"
    local pf = io.open(pidfile, "r")
    if pf then
        local old_pid = pf:read("*l") or ""
        pf:close()
        if old_pid ~= "" then os.execute("kill " .. old_pid .. " 2>/dev/null; true") end
    end
    os.remove(pidfile)

    -- Build args (quoted for safety)
    local sms = uci:get("esurfinggo", section, "sms") or ""
    local iface = uci:get("esurfinggo", section, "interface") or ""
    local args = "-u " .. account .. " -p " .. password
    if sms ~= "" then args = args .. " -s " .. sms end
    if iface ~= "" then
        local idx = resolve_interface_index(iface)
        if idx then args = args .. " -n " .. idx end
    end

    -- Direct start-stop-daemon (reliable, immediate feedback)
    os.execute("start-stop-daemon -S -b -m -p " .. pidfile .. " -x /usr/bin/esurfing -- " .. args .. " >> /tmp/esurfing.log 2>&1; true")

    -- Clear one-time SMS code
    uci:set("esurfinggo", section, "sms", "")
    uci:save("esurfinggo")
    uci:commit("esurfinggo")

    -- Log
    local lf = io.open("/tmp/esurfing.log", "a")
    if lf then
        lf:write("[" .. os.date("%H:%M:%S") .. "] dial section=" .. section .. " account=" .. account .. " -> direct\n")
        lf:close()
    end

    redirect_back("dial_ok:" .. account)
end

-- ============ Action: dial primary (account #1 only) ============
function action_dial_primary()
    local uci = require("luci.model.uci").cursor()
    -- Find first account section that has both account+password filled
    local target = nil
    uci:foreach("esurfinggo", "account", function(sec)
        if not target then
            local a = uci:get("esurfinggo", sec['.name'], "account")
            local p = uci:get("esurfinggo", sec['.name'], "password")
            if a and a ~= "" and p and p ~= "" then
                target = sec['.name']
            end
        end
    end)
    if not target then
        redirect_back("dial_failed:no_account_with_credentials")
        return
    end

    if not nixio.fs.access("/usr/bin/esurfing") then
        redirect_back("dial_failed:no_binary")
        return
    end

    local sms = uci:get("esurfinggo", target, "sms") or ""
    local iface = uci:get("esurfinggo", target, "interface") or ""
    local a = uci:get("esurfinggo", target, "account") or ""
    local p = uci:get("esurfinggo", target, "password") or ""

    -- Kill old, start new with direct start-stop-daemon
    local pidfile = "/tmp/esurfing_" .. target .. ".pid"
    local pf = io.open(pidfile, "r")
    if pf then
        local old_pid = pf:read("*l") or ""
        pf:close()
        if old_pid ~= "" then os.execute("kill " .. old_pid .. " 2>/dev/null; true") end
    end
    os.remove(pidfile)

    local args = "-u " .. a .. " -p " .. p
    if sms ~= "" then args = args .. " -s " .. sms end
    if iface ~= "" then
        local idx = resolve_interface_index(iface)
        if idx then args = args .. " -n " .. idx end
    end
    os.execute("start-stop-daemon -S -b -m -p " .. pidfile .. " -x /usr/bin/esurfing -- " .. args .. " >> /tmp/esurfing.log 2>&1; true")

    -- Clear one-time SMS on the primary account
    uci:set("esurfinggo", target, "sms", "")
    uci:save("esurfinggo")
    uci:commit("esurfinggo")

    local lf = io.open("/tmp/esurfing.log", "a")
    if lf then
        lf:write("[" .. os.date("%H:%M:%S") .. "] dial_primary section=" .. target .. " -> direct\n")
        lf:close()
    end

    redirect_back("dial_ok_primary:" .. target)
end

-- ============ Action: restart primary (kill, then dial_primary) ============
function action_restart_primary()
    -- Kill all esurfing first
    os.execute("pidof esurfing 2>/dev/null | xargs kill 2>/dev/null; sleep 1; true; true")
    -- Re-dial primary
    local uci = require("luci.model.uci").cursor()
    local target = nil
    uci:foreach("esurfinggo", "account", function(sec)
        if not target then
            local a = uci:get("esurfinggo", sec['.name'], "account")
            local p = uci:get("esurfinggo", sec['.name'], "password")
            if a and a ~= "" and p and p ~= "" then
                target = sec['.name']
            end
        end
    end)
    if not target then
        redirect_back("restart_failed:no_account")
        return
    end
    local sms = uci:get("esurfinggo", target, "sms") or ""
    local iface = uci:get("esurfinggo", target, "interface") or ""
    local a = uci:get("esurfinggo", target, "account") or ""
    local p = uci:get("esurfinggo", target, "password") or ""

    local pidfile = "/tmp/esurfing_" .. target .. ".pid"
    os.remove(pidfile)
    local args = "-u " .. a .. " -p " .. p
    if sms ~= "" then args = args .. " -s " .. sms end
    if iface ~= "" then
        local idx = resolve_interface_index(iface)
        if idx then args = args .. " -n " .. idx end
    end
    os.execute("start-stop-daemon -S -b -m -p " .. pidfile .. " -x /usr/bin/esurfing -- " .. args .. " >> /tmp/esurfing.log 2>&1; true")
    local lf = io.open("/tmp/esurfing.log", "a")
    if lf then
        lf:write("[" .. os.date("%H:%M:%S") .. "] restart_primary section=" .. target .. "\n")
        lf:close()
    end
    redirect_back("restarted_primary:" .. target)
end

-- ============ Action: refresh (no-op, just redirect back) ============
function action_refresh()
    redirect_back("refreshed")
end

-- ============ Action: stop single account ============
function action_stop_one()
    local section = formvalue("section")
    if section ~= "" then
        local pidfile = "/tmp/esurfing_" .. section .. ".pid"
        local pf = io.open(pidfile, "r")
        if pf then
            local pid = pf:read("*l") or ""
            pf:close()
            if pid ~= "" then
                os.execute("kill " .. pid .. " 2>/dev/null; true")
            end
        end
        os.remove(pidfile)
        local lf = io.open("/tmp/esurfing.log", "a")
        if lf then
            lf:write("[" .. os.date("%H:%M:%S") .. "] stop section=" .. section .. "\n")
            lf:close()
        end
    end
    redirect_back("stopped:" .. section)
end

-- ============ Action: start all enabled accounts (uses /etc/init.d/esurfinggo) ============
function action_start_all()
    os.execute("/etc/init.d/esurfinggo start >/dev/null 2>&1; true")
    redirect_back("started_all")
end

-- ============ Action: restart all ============
function action_restart_all()
    os.execute("pidof esurfing 2>/dev/null | xargs kill 2>/dev/null; sleep 1; true; /etc/init.d/esurfinggo start >/dev/null 2>&1; true")
    redirect_back("restarted_all")
end

-- ============ Action: stop all ============
function action_stop_all()
    os.execute("pidof esurfing 2>/dev/null | xargs kill 2>/dev/null; true; rm -f /tmp/esurfing_*.pid; true")
    redirect_back("stopped_all")
end

-- ============ Action: log viewer (returns plain HTML with <pre>) ============
function action_log_view()
    local http = require("luci.http")
    local content = ""
    local f = io.open("/tmp/esurfing.log", "r")
    if f then
        content = f:read("*a") or ""
        f:close()
    end
    if content == "" then content = "鏆傛棤鏃ュ織" end
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    http.prepare_content("text/html; charset=utf-8")
    http.write("<!DOCTYPE html><html><head><meta charset='utf-8'>")
    http.write("<title>杩愯鏃ュ織 - 澶╃考鏍″洯缃戦潰鏉?/title>")
    http.write("<style>body{background:#1e1e1e;color:#d4d4d4;margin:0;padding:20px;font-family:Consolas,monospace;}")
    http.write("a{color:#28a745;}.top{margin-bottom:15px;}")
    http.write("pre{white-space:pre-wrap;word-wrap:break-word;font-size:13px;line-height:1.5;}</style>")
    http.write("</head><body>")
    http.write("<div class='top'><a href='/cgi-bin/luci/admin/services/esurfing'>&larr; 杩斿洖闈㈡澘</a></div>")
    http.write("<pre>" .. content .. "</pre>")
    http.write("</body></html>")
end

-- ============ Action: upload binary via raw POST body (bypasses multipart dispatcher bug) ============
function action_upload_bin()
    local http = require("luci.http")

    -- v1.4.11: multi-strategy upload to support both ucode (ImmortalWrt) and Lua LuCI
    --   Strategy 1: setfilehandler (intercepts multipart chunks before ucode temp-fd bridge)
    --   Strategy 2: multipart table.fd (Lua LuCI native)
    --   Strategy 3: legacy base64 URL-encoded (non-multipart LuCI)
    --   Strategy 4: raw http.content() (binary POST fallback)
    local chunks, total = {}, 0
    pcall(function()
        http.setfilehandler(function(meta, chunk, eof)
            if meta and meta.name == "esfg_file" then
                if chunk and #chunk > 0 then
                    total = total + #chunk
                    chunks[#chunks + 1] = chunk
                end
            end
        end)
    end)

    local file_data = http.formvalue("esfg_file")
    local data = nil

    -- Strategy 1: reassemble from setfilehandler chunks
    if total > 0 then
        data = table.concat(chunks)
    end

    -- Strategy 2: read from multipart table fd (Lua LuCI)
    if not data and type(file_data) == "table" and file_data.fd then
        pcall(function()
            local c = {}
            while true do
                local chunk = file_data.fd:read(65536)
                if not chunk or #chunk == 0 then break end
                c[#c + 1] = chunk
            end
            data = table.concat(c)
        end)
    end

    -- Strategy 3: legacy base64 URL-encoded
    if not data then
        local b64 = http.formvalue("data")
        if b64 and #b64 >= 100 then
            b64 = string.gsub(b64, '%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
            if nixio and nixio.bin and nixio.bin.b64decode then
                local okd, decoded = pcall(nixio.bin.b64decode, b64)
                if okd and decoded and #decoded >= 100 then data = decoded end
            end
        end
    end

    -- Strategy 4: raw POST body
    if not data then
        local raw = http.content()
        if raw and #raw >= 100 then data = raw end
    end

    if not data or #data < 100 then
        http.status(400, "Bad Request")
        http.write("ERR:no_data")
        return
    end

    -- Check ELF magic
    if data:sub(1,1) ~= string.char(127) or data:sub(2,4) ~= "ELF" then
        http.status(400, "Bad Request")
        http.write("ERR:not_elf")
        return
    end

    -- Detect arch from ELF header
    local hdr = data:sub(1, 64)
    local arch = "unknown"
    if hdr:find("AArch64") then arch = "aarch64"
    elseif hdr:find("ARM aarch32") or hdr:find("ARM,") then arch = "arm"
    elseif hdr:find("x86%-64") or hdr:find("x86_64") then arch = "x86_64"
    elseif hdr:find("80386") or hdr:find("i386") then arch = "x86"
    elseif hdr:find("MIPS") then arch = "mips"
    end

    -- Get router arch
    local router_short = "?"
    if nixio and nixio.uname then
        local u = nixio.uname()
        if u and u.machine then
            local m = u.machine
            if m:match("aarch64") then router_short = "aarch64"
            elseif m:match("arm") then router_short = "arm"
            elseif m:match("x86_64") then router_short = "x86_64"
            elseif m:match("i%d86") then router_short = "x86"
            elseif m:match("mips") then router_short = "mips"
            end
        end
    end

    -- Arch check (non-fatal warning but logged)
    if arch ~= "unknown" and arch ~= router_short then
        http.status(400, "Bad Request")
        http.write("ERR:arch_mismatch:" .. arch .. "_vs_" .. router_short)
        return
    end

    -- Stop existing process, replace binary
    os.execute("pidof esurfing 2>/dev/null | xargs kill 2>/dev/null; true")

    local f = io.open("/usr/bin/esurfing", "wb")
    if not f then
        http.status(500, "Internal Server Error")
        http.write("ERR:write_fail")
        return
    end
    f:write(data)
    f:close()
    os.execute("chmod 755 /usr/bin/esurfing")

    http.write("OK|size=" .. #data .. "|arch=" .. arch)
end

-- ============ Action: upload binary (legacy multipart, kept for compatibility) ============
function action_upload()
    redirect_back("redirect_to_upload_page")
end

-- ============ Action: add a new account ============
function action_add_account()
    local uci = require("luci.model.uci").cursor()
    local count = 0
    uci:foreach("esurfinggo", "account", function() count = count + 1 end)
    if count >= 10 then
        redirect_back("add_failed:max_10")
        return
    end
    uci:section("esurfinggo", "account", nil, { account = "", password = "", sms = "", interface = "" })
    uci:save("esurfinggo")
    uci:commit("esurfinggo")
    redirect_back("added")
end

-- ============ Action: delete an account ============
function action_delete_account()
    local section = formvalue("section")
    if section == "" then
        redirect_back("delete_failed:no_section")
        return
    end
    -- Stop instance if running
    local pidfile = "/tmp/esurfing_" .. section .. ".pid"
    local pf = io.open(pidfile, "r")
    if pf then
        local pid = pf:read("*l") or ""
        pf:close()
        if pid ~= "" then os.execute("kill " .. pid .. " 2>/dev/null; true") end
    end
    os.remove(pidfile)
    local uci = require("luci.model.uci").cursor()
    uci:delete("esurfinggo", section)
    uci:save("esurfinggo")
    uci:commit("esurfinggo")
    redirect_back("deleted:" .. section)
end

-- ============ Action: save all account fields ============
function action_save_accounts()
    local uci = require("luci.model.uci").cursor()
    local updated = 0
    uci:foreach("esurfinggo", "account", function(sec)
        local name = sec['.name']
        local acc = formvalue("account_" .. name)
        local pwd = formvalue("password_" .. name)
        local sms = formvalue("sms_" .. name)
        local iface = formvalue("interface_" .. name)
        if acc and acc ~= "" then
            uci:set("esurfinggo", name, "account", acc)
            updated = updated + 1
        end
        if pwd and pwd ~= "" then uci:set("esurfinggo", name, "password", pwd) end
        uci:set("esurfinggo", name, "sms", sms or "")
        uci:set("esurfinggo", name, "interface", iface or "")
    end)
    uci:save("esurfinggo")
    uci:commit("esurfinggo")
    redirect_back("saved:" .. updated)
end

-- ============ Action: toggle autostart (writes/removes esurfing -u line in /etc/rc.local) ============
function action_toggle_autostart()
    local current = formvalue("current")

    -- Verify at least one account with credentials exists before enabling
    if current == "0" then
        local uci = require("luci.model.uci").cursor()
        local has_account = false
        uci:foreach("esurfinggo", "account", function(sec)
            local a = uci:get("esurfinggo", sec['.name'], "account")
            local p = uci:get("esurfinggo", sec['.name'], "password")
            if a and a ~= "" and p and p ~= "" then has_account = true end
        end)
        if not has_account then
            redirect_back("autostart_failed:no_account")
            return
        end
        os.execute("/etc/init.d/esurfinggo enable >/dev/null 2>&1; true")
        redirect_back("autostart_enabled")
        return
    else
        os.execute("/etc/init.d/esurfinggo disable >/dev/null 2>&1; true")
        redirect_back("autostart_disabled")
        return
    end
end

-- ============ Action: import accounts from /etc/rc.local ============
function action_import_rclocal()
    local content = ""
    local f = io.open("/etc/rc.local", "r")
    if f then content = f:read("*a") or ""; f:close() end

    local imported = 0
    local uci = require("luci.model.uci").cursor()

    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed:sub(1, 1) ~= "#" and trimmed:find("esurfing%s") and trimmed:find("%-u") then
            local u = trimmed:match("%-u%s+(['\"]?)([^%s'\"]+)")
            local p = trimmed:match("%-p%s+(['\"]?)([^%s'\"]+)")
            local s_val = trimmed:match("%-s%s+(['\"]?)([^%s'\"]+)")
            local n_val = trimmed:match("%-n%s+(['\"]?)([^%s'\"]+)")
            if u and u ~= "" then
                -- Check max 10
                local count = 0
                uci:foreach("esurfinggo", "account", function() count = count + 1 end)
                if count >= 10 then break end
                uci:section("esurfinggo", "account", nil, {
                    account = u,
                    password = p or "",
                    sms = s_val or "",
                    interface = n_val or "",
                })
                imported = imported + 1
            end
        end
    end

    uci:save("esurfinggo")
    uci:commit("esurfinggo")
    redirect_back("imported:" .. imported)
end

-- ============ Action: import accounts from text document (txt/md/csv/json) ============
function action_import_text()
    local http = require("luci.http")
    local uci = require("luci.model.uci").cursor()

    -- LuCI's dispatcher already parsed the POST body 鈥?use formvalue()
    local count = tonumber(http.formvalue("count")) or 0
    if count == 0 then
        redirect_back("import_txt_failed:no_data")
        return
    end

    -- Check current + new won't exceed 10
    local existing = 0
    uci:foreach("esurfinggo", "account", function() existing = existing + 1 end)
    if existing + count > 10 then
        count = 10 - existing
        if count <= 0 then
            redirect_back("import_txt_failed:max_10")
            return
        end
    end

    local imported = 0
    for i = 0, count - 1 do
        local acc = http.formvalue("acc" .. i) or ""
        local pwd = http.formvalue("pwd" .. i) or ""
        local sms = http.formvalue("sms" .. i) or ""
        if acc ~= "" then
            uci:section("esurfinggo", "account", nil, {
                account = acc,
                password = pwd,
                sms = sms,
                interface = "",
            })
            imported = imported + 1
        end
    end

    uci:save("esurfinggo")
    uci:commit("esurfinggo")
    redirect_back("imported_txt:" .. imported)
end

-- ============ Action: view /etc/rc.local (returns HTML) ============
function action_view_rclocal()
    local http = require("luci.http")
    local content = ""
    local f = io.open("/etc/rc.local", "r")
    if f then
        content = f:read("*a") or ""
        f:close()
    end
    if content == "" then content = "(绌烘枃浠?" end
    content = content:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    http.prepare_content("text/html; charset=utf-8")
    http.write("<!DOCTYPE html><html><head><meta charset='utf-8'>")
    http.write("<title>/etc/rc.local - 澶╃考鏍″洯缃戦潰鏉?/title>")
    http.write("<style>body{background:#1e1e1e;color:#d4d4d4;margin:0;padding:20px;font-family:Consolas,monospace;}")
    http.write("a{color:#28a745;}.top{margin-bottom:15px;}")
    http.write("pre{white-space:pre-wrap;word-wrap:break-word;font-size:13px;line-height:1.5;}</style>")
    http.write("</head><body>")
    http.write("<div class='top'><a href='/cgi-bin/luci/admin/services/esurfing'>&larr; 杩斿洖闈㈡澘</a></div>")
    http.write("<pre>" .. content .. "</pre>")
    http.write("</body></html>")
end
