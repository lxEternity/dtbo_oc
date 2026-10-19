#!/system/bin/sh
# machineid.sh - 主板唯一ID查询, 结果保存到内置存储
# 用法: sh machineid.sh [输出文件]   (默认 /sdcard/dtbo_oc_machine_id.txt)

OUT="${1:-/sdcard/dtbo_oc_machine_id.txt}"
TOOL="/data/adb/modules/dtbo_oc/arm64/dtbo_oc"

read_id() {
    for p in /proc/device-tree/serial-number \
             /sys/firmware/devicetree/base/serial-number \
             /sys/devices/soc0/serial_number; do
        [ -r "$p" ] || continue
        ID=$(tr -cd 'A-Za-z0-9' < "$p" | cut -c1-16)
        [ -n "$ID" ] && return 0
    done
    ID="0"
    return 0
}

read_id

echo "===================================="
echo " 主板唯一ID: $ID"
echo "===================================="

if [ -x "$TOOL" ]; then
    TOOLID=$("$TOOL" machineid 2>/dev/null | sed -n 's/^MACHINE=//p')
    if [ -n "$TOOLID" ] && [ "$TOOLID" != "$ID" ]; then
        echo " 提示: 模块授权使用的ID为 $TOOLID (以此为准)"
        ID="$TOOLID"
    fi
fi

SAVED=""
mkdir -p "$(dirname "$OUT")" 2>/dev/null
if printf '%s\n' "$ID" > "$OUT" 2>/dev/null; then
    SAVED="$OUT"
elif printf '%s\n' "$ID" > "/data/local/tmp/dtbo_oc_machine_id.txt" 2>/dev/null; then
    SAVED="/data/local/tmp/dtbo_oc_machine_id.txt"
    echo " 内置存储不可写, 已改存备用位置"
elif printf '%s\n' "$ID" > "/data/adb/dtbo_oc/machine_id.txt" 2>/dev/null; then
    SAVED="/data/adb/dtbo_oc/machine_id.txt"
fi

if [ -n "$SAVED" ]; then
    echo " 已保存: $SAVED"
else
    echo " 保存失败, 请手动记录上面的ID"
fi
