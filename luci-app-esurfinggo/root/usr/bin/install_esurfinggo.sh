#!/bin/sh
# EsurfingGo installer helper
# Used by the web UI to install/upgrade the esurfinggo binary

BIN_PATH="/usr/bin/esurfinggo"
TMP_PATH="/tmp/esurfinggo_upload"

# Check architecture
check_arch() {
	local file_info=$(file "$1" 2>/dev/null)
	local router_arch=$(uname -m)
	
	if echo "$file_info" | grep -q "ELF"; then
		if echo "$router_arch" | grep -q "aarch64"; then
			echo "$file_info" | grep -q "ARM aarch64" && return 0
			echo "$file_info" | grep -q "ELF 64-bit.*ARM" && return 0
			return 1
		elif echo "$router_arch" | grep -q "x86_64"; then
			echo "$file_info" | grep -q "x86-64" && return 0
			return 1
		elif echo "$router_arch" | grep -q "mips"; then
			echo "$file_info" | grep -q "MIPS" && return 0
			return 1
		fi
	fi
	return 0
}

# Install binary
install_bin() {
	if [ ! -f "$TMP_PATH" ]; then
		echo '{"success":false,"message":"文件不存在"}'
		return 1
	fi

	if ! check_arch "$TMP_PATH"; then
		rm -f "$TMP_PATH"
		echo '{"success":false,"message":"架构不匹配"}'
		return 1
	fi

	cp "$TMP_PATH" "$BIN_PATH"
	chmod 755 "$BIN_PATH"
	rm -f "$TMP_PATH"
	echo '{"success":true,"message":"安装成功"}'
	return 0
}

case "$1" in
	install)
		install_bin
		;;
	check)
		if [ -f "$BIN_PATH" ]; then
			echo '{"installed":true,"arch":"'$(uname -m)'"}'
		else
			echo '{"installed":false,"arch":"'$(uname -m)'"}'
		fi
		;;
	*)
		echo "Usage: $0 {install|check}"
		exit 1
		;;
esac
