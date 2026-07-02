# EsurfingPanel

天翼校园网 OpenWrt LuCI 面板，配合 [xxmod/EsurfingGo](https://github.com/xxmod/EsurfingGo) 使用。

全 Web 界面操作，无需 SSH：上传/更新拨号模块、管理账号、一键拨号。

## 功能

- 📤 **热更新** — 浏览器直接上传二进制模块，不用 SSH
- 👤 **账号管理** — 最多 10 个账号，一键切换
- 🚀 **拨号控制** — 单播/多播，开机自启
- 📋 **日志查看** — 实时状态，历史日志
- 🔄 **rc.local 导入** — 老配置一键迁移

## 支持平台

| 平台 | LuCI 类型 | 状态 |
|------|----------|:--:|
| OpenWrt | arm64 | Lua | ✅ |
| ImmortalWrt | arm64 | ucode | ✅ |

## 安装

三种包，按需选择：

```bash
# 方式一：opkg 安装（推荐）
opkg install luci-app-esurfinggo_1.0.0_all.ipk

# 如果报 Malformed，用 clean 版
opkg install luci-app-esurfinggo_1.0.0_all_gzip.ipk

# 方式二：自解压脚本
sh luci-app-esurfinggo_1.0.0_run.run
```

安装后访问：`http://路由器IP/cgi-bin/luci/admin/services/esurfing`

## 使用

1. 打开面板，在「热更新模块」上传你的 esurfing 二进制
2. 在「拨号账号列表」添加账号密码，保存账号密码
3. 点拨号，完事

## 从源码构建

```bash
python3 build_packages.py
```

输出三种包：`.ipk`（标准）、`_gzip.ipk`（无 conffiles）、`.run`（自解压）

## 致谢

- [xxmod/EsurfingGo](https://github.com/xxmod/EsurfingGo)

## License

MIT
