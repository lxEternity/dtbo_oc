#!/system/bin/sh
DATA_DIR=/data/adb/dtbo_oc
STOCK="$DATA_DIR/dtbo_stock.img"
CONFIG="$DATA_DIR/config"
BACKUP="/sdcard/dtbo_backup.img"

LTPO_OFF=0
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null
if [ "$LTPO_OFF" = "1" ] && command -v resetprop >/dev/null 2>&1; then
    echo "[dtbo_oc] 正在释放 LTPO/VRR 相关属性..."
    resetprop --delete persist.oplus.display.vrr 2>/dev/null
    resetprop --delete persist.oplus.display.vrr.adfr 2>/dev/null
    resetprop --delete debug.oplus.display.dynamic_fps_switch 2>/dev/null
    resetprop --delete sys.display.vrr.vote.support 2>/dev/null
    resetprop --delete vendor.display.enable_dpps_dynamic_fps 2>/dev/null
    resetprop --delete ro.display.brightness.brightness.mode 2>/dev/null
    resetprop --delete debug.egl.swapinterval 2>/dev/null
    echo "[dtbo_oc] LTPO/VRR 属性已释放, 重启后恢复系统默认"
fi

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
