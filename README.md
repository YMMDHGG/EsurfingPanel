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

| 平台 | 架构 | LuCI 类型 | 状态 |
|------|------|----------|:--:|
| OpenWrt | arm64 | Lua | ✅ |
| ImmortalWrt | aarch64 | ucode | ✅ |

## 安装

三种包，按需选择：

```bash
# 方式一：opkg 安装（推荐）
opkg install luci-app-esurfinggo_1.4.11_all.ipk

# 如果报 Malformed，用 clean 版
opkg install luci-app-esurfinggo_1.4.11_all_gzip.ipk

# 方式二：自解压脚本
sh luci-app-esurfinggo_1.4.11_run.run
```

安装后访问：`http://路由器IP/cgi-bin/luci/admin/services/esurfing`

## 使用

1. 打开面板，在「热更新模块」上传你的 esurfing 二进制
2. 在「拨号账号列表」添加账号密码
3. 点连接，完事

## 从源码构建

```bash
python3 build_packages.py
```

输出三种包：`.ipk`（标准）、`_gzip.ipk`（无 conffiles）、`.run`（自解压）

## 版本

当前 **v1.4.11**

| 版本 | 主要变更 |
|------|---------|
| v1.4.11 | 多策略上传，兼容 ucode 和 Lua LuCI |
| v1.4.10 | 移除 base64 命令依赖，改用 nixio |
| v1.4.9 | 架构匹配检测优化 |
| v1.4.8 | IPK 格式修复，多格式构建 |
| v1.4.6 | 编码修复，init.d 参数修正 |
| v1.4.4 | 稳定基线版本 |

## 致谢

- [xxmod/EsurfingGo](https://github.com/xxmod/EsurfingGo)

## License

MIT
