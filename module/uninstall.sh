#!/system/bin/sh
# 卸载模块时, 若存在原始 DTBO 备份则自动恢复, 保证卸载后回到未超频状态
DATA_DIR=/data/adb/dtbo_oc
STOCK="$DATA_DIR/dtbo_stock.img"
BACKUP="/sdcard/dtbo_backup.img"

SLOT=$(getprop ro.boot.slot_suffix)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        if [ -e "$d/$n" ]; then DTBO="$d/$n"; break 2; fi
    done
done

SRC=""
[ -f "$STOCK" ] && SRC="$STOCK"
[ -z "$SRC" ] && [ -f "$BACKUP" ] && SRC="$BACKUP"

if [ -n "$DTBO" ] && [ -n "$SRC" ]; then
    echo "[dtbo_oc] 正在恢复原始 DTBO ($SRC -> $DTBO)"
    if dd if="$SRC" of="$DTBO" 2>/dev/null; then
        sync
        echo "[dtbo_oc] 已恢复原始 DTBO, 重启后回到原刷新率档位"
    else
        echo "[dtbo_oc] 恢复失败, 请手动执行: dd if=$SRC of=$DTBO"
    fi
else
    echo "[dtbo_oc] 未找到原始备份, 保持当前 DTBO 不变"
    echo "[dtbo_oc] 如需恢复请查看 /sdcard/dtbo_backup.img"
fi
# 保留 /data/adb/dtbo_oc 下的备份与日志, 便于手动恢复; 确认不再需要后可手动删除
