#!/system/bin/sh
# machineid.sh - 主板唯一ID查询

OUT="${1:-/storage/emulated/0/主板唯一ID.txt}"
TOOL="/data/adb/modules/dtbo_oc/arm64/dtbo_oc"

read_id() {
    for p in /proc/device-tree/serial-number \
             /sys/firmware/devicetree/base/serial-number \
             /sys/devices/soc0/serial_number; do
        [ -r "$p" ] || continue
        ID=$(tr -cd 'A-Za-z0-9' < "$p" | cut -c1-16)
        [ -n "$ID" ] && return 0
    done
    # 天机平台 (ACE6至尊版等): 回退读 cmdline 的 oplusboot.serialno
    ID=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n 's/^oplusboot\.serialno=//p' | tr -cd 'A-Za-z0-9' | cut -c1-16)
    [ -n "$ID" ] && return 0
    ID="0"
    return 0
}

read_id

echo "===================================="
echo " 主板唯一ID: $ID"
echo "===================================="

if [ -x "$TOOL" ]; then
    TOOLID=$("$TOOL" machineid 2>/dev/null | sed -n 's/^MACHINE=//p')
    # 仅当模块ID有效(非0)或本脚本未取到ID时才采用模块结果, 防止旧版二进制的0覆盖
    if [ -n "$TOOLID" ] && [ "$TOOLID" != "$ID" ]; then
        if [ "$TOOLID" != "0" ] || [ "$ID" = "0" ]; then
            echo " 提示: 模块授权使用的ID为 $TOOLID (以此为准)"
            ID="$TOOLID"
        fi
    fi
fi

if printf '%s\n' "$ID" > "$OUT" 2>/dev/null; then
    echo " 已保存: $OUT"
else
    echo " 保存失败, 请手动记录上面的ID"
fi
