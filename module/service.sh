#!/system/bin/sh
MODDIR=${0%/*}
TOOL="$MODDIR/arm64/dtbo_oc"
DTC="$MODDIR/arm64/dtc"
DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
LOG="$DATA_DIR/last_run.log"
CONFIG="$DATA_DIR/config"
STOCK="$DATA_DIR/dtbo_stock.img"

log() { echo "$@" >> "$LOG"; echo "[dtbo_oc] $@"; }

mkdir -p "$DATA_DIR" "$WORK"
: > "$LOG"
chmod 755 "$TOOL" "$DTC" 2>/dev/null

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'EOF'
# DTBO 刷新率超频 v2 配置 (修改后重启生效; 也可运行 /data/adb/modules/dtbo_oc/menu.sh 交互修改)
#
# HZ_CHOICE: 超频目标档位 (仅生成 <= 此值的档位, 更高的不生成; 0 = 不超频)
#   ace2pro/gt7s 可选: 144/165/185     gt8 可选: 144/165/185/195
#   op12/op13/op13t/ace5/ace3/ace3pro/ace5p 可选: 144
#   op15/ace6/op15t 可选: 185/195      ace6t 可选: 185    ace6u 可选: 185/195
#   gt8p 可选: 165/185
#   gt7p 可选: 130/142/144
#   op11: 不可超频 (自动忽略)
HZ_CHOICE=144
#
# BATTERY: 电池/充电选项
#   0 = 保持原版 (默认)
#   1 = 解除充电限流 (全机型, 电池参数保持原版:
#       老平台删 qcom 限流节点, 新平台 oplus 策略表电流位 x2 cap 8000mA)
#   2 = 解除充电限流 + 关机电压2800 电池解容 (全机型)
#   3 = 6100mAh 魔改电池 (容量 6100, 关机 3.0V, 1% 3.05V, 满充 4.54V) !! 非魔改电池勿选 !!
#   4 = 6100mAh 魔改电池 + 解除充电限流 (同 3 并删限流节点) !! 非魔改电池勿选 !!
#   5 = 原版电池 + 关机电压2800 电池解容 (全机型)
#   6 = GT7 Pro 竞速版解容: 满充4.55V + 关机2.85V + 解除充电限流 (仅 gt7p)
#   3/4 仅 ACE2Pro/一加11/一加12 支持 (带电池容量节点的机型), 其他机型忽略
BATTERY=0
#
# FLASH: 1 = 自动刷入 dtbo 分区 (默认); 0 = 仅生成镜像到 /sdcard/dtbo_oc_patched.img
FLASH=1
# BACKUP_PATH: 原始镜像备份位置
BACKUP_PATH=/sdcard/dtbo_backup.img
# DTBO_PATH: 手动指定 dtbo 分区路径 (留空 = 自动检测)
DTBO_PATH=
EOF
    log "已生成默认配置 $CONFIG"
fi
. "$CONFIG"

LOCKED=$(getprop ro.boot.flash.locked)
VBS=$(getprop ro.boot.verifiedbootstate)
if [ "$LOCKED" = "1" ] || [ "$VBS" = "green" ]; then
    log "[警告] Bootloader 处于锁定/校验状态 (flash.locked=$LOCKED verifiedbootstate=$VBS)"
    log "[警告] 未解锁 BL 刷入修改后的 DTBO 会导致无法开机(变砖)!"
    log "[警告] 请确认已解锁 Bootloader, 否则请立即卸载本模块并恢复原始 DTBO"
fi

SLOT=$(getprop ro.boot.slot_suffix)
DTBO="${DTBO_PATH:-}"
if [ -z "$DTBO" ]; then
    for d in /dev/block/by-name /dev/block/bootdevice/by-name; do
        for n in dtbo "dtbo$SLOT"; do
            [ -e "$d/$n" ] && DTBO="$d/$n" && break 2
        done
    done
fi
[ -z "$DTBO" ] && { log "[错误] 未找到 dtbo 分区; 可在 config 设置 DTBO_PATH"; exit 1; }
log "dtbo 分区: $DTBO (slot=$SLOT)"

CUR="$WORK/current.img"
dd if="$DTBO" of="$CUR" 2>>"$LOG" || { log "[错误] 读取 $DTBO 失败"; exit 1; }
log "已提取当前 DTBO: $(wc -c < "$CUR") 字节"

if [ ! -f "$STOCK" ]; then
    if [ -f /sdcard/dtbo_backup.img ]; then
        cp /sdcard/dtbo_backup.img "$STOCK"
        log "已从 /sdcard/dtbo_backup.img 恢复原始镜像基准"
    else
        cp "$CUR" "$STOCK"
        log "首次运行: 当前分区已保存为原始镜像基准"
    fi
fi

rm -rf "$WORK"/ide* 2>/dev/null
IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>>"$LOG")
DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
CHOICES=""
case "$DEVICE" in
    ace2pro)   CHOICES="144 165 185"; DEF_HZ=144 ;;
    op13t)     CHOICES="144";         DEF_HZ=144 ;;
    op15t)     CHOICES="185 195";     DEF_HZ=185 ;;
    ace5)      CHOICES="144";         DEF_HZ=144 ;;
    ace3)      CHOICES="144";         DEF_HZ=144 ;;
    ace3pro)   CHOICES="144";         DEF_HZ=144 ;;
    op12)      CHOICES="144";         DEF_HZ=144 ;;
    op13)      CHOICES="144";         DEF_HZ=144 ;;
    op15|ace6) CHOICES="185 195";     DEF_HZ=185 ;;
    gt8)       CHOICES="144 165 185 195"; DEF_HZ=185 ;;
    gt7p)      CHOICES="130 142 144";     DEF_HZ=144 ;;
    gt7s)      CHOICES="144 165 185";     DEF_HZ=185 ;;
    gt8p)      CHOICES="165 185";         DEF_HZ=185 ;;
    ace6t)     CHOICES="185";             DEF_HZ=185 ;;
    ace6u)     CHOICES="185 195";         DEF_HZ=195 ;;
    ace5p)     CHOICES="144";             DEF_HZ=144 ;;
    op11)      CHOICES="";            DEF_HZ=0 ;;
    *) log "[中止] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac
log "机型识别: $DEVNAME ($DEVICE)"

if [ "$OC_OK" != "1" ] || [ -z "$CHOICES" ]; then
    if [ "${HZ_CHOICE:-0}" != "0" ]; then
        log "[提示] 本机型不支持刷新率超频, 已忽略档位设置 (HZ_CHOICE=$HZ_CHOICE)"
    fi
    HZ_CHOICE=0
else
    VALID=0
    [ "$HZ_CHOICE" = "0" ] && VALID=1
    for c in $CHOICES; do [ "$HZ_CHOICE" = "$c" ] && VALID=1; done
    if [ "$VALID" != "1" ]; then
        log "[提示] HZ_CHOICE=$HZ_CHOICE 不适用于本机型, 可选: $CHOICES 或 0(不超频), 使用默认 $DEF_HZ"
        HZ_CHOICE=$DEF_HZ
    fi
fi

[ -z "$BATTERY" ] && BATTERY=0
case "$BATTERY" in 0|1|2|3|4|5|6) ;; *) BATTERY=0 ;; esac
if [ "$BATT_OK" != "1" ]; then
    case "$BATTERY" in
        3|4)
            log "[提示] 电池选项 $BATTERY 仅 ACE2Pro/一加11/一加12 支持, 已重置为原版"
            BATTERY=0
            ;;
    esac
fi
if [ "$DEVICE" = "gt7p" ]; then
    case "$BATTERY" in
        1|2|3|4|5)
            log "[提示] gt7p 请使用电池选项 6 (GT7P 专属解容), 其他电池选项已重置为原版"
            BATTERY=0
            ;;
    esac
elif [ "$BATTERY" = "6" ]; then
    log "[提示] 电池选项 6 仅 GT7 Pro 竞速版支持, 已重置为原版"
    BATTERY=0
fi
log "方案: 档位 ${HZ_CHOICE:-0}, 电池模式 $BATTERY"

HZ=""
case "$DEVICE" in
    ace2pro)
        case "$HZ_CHOICE" in
            144) HZ=130,132,138,141,144,150 ;;
            165) HZ=130,132,138,141,144,150,158,165 ;;
            185) HZ=130,132,138,141,144,150,158,165,170,185 ;;
        esac ;;
    op13|op13t|ace5|ace3|ace3pro|op12)
        HZ=130,132,138,141,144,150 ;;
    op15|ace6|op15t)
        case "$HZ_CHOICE" in
            185) HZ=170,178,185 ;;
            195) HZ=170,178,185,188,195 ;;
        esac ;;
    gt8)
        case "$HZ_CHOICE" in
            144) HZ=130,138,141,144 ;;
            165) HZ=130,138,141,144,150,158,165 ;;
            185) HZ=130,138,141,144,150,158,165,170,178,185 ;;
            195) HZ=130,138,141,144,150,158,165,170,178,185,188,195 ;;
        esac ;;
    gt7s)
        case "$HZ_CHOICE" in
            144) HZ=130,132,138,141,144,150 ;;
            165) HZ=130,132,138,141,144,150,158,165 ;;
            185) HZ=130,132,138,141,144,150,158,165,170,185 ;;
        esac ;;
    gt8p)
        case "$HZ_CHOICE" in
            165) HZ=150,158,165 ;;
            185) HZ=150,158,165,170,178,185 ;;
        esac ;;
    ace6t)
        HZ=170,178,185 ;;
    ace6u)
        case "$HZ_CHOICE" in
            185) HZ=170,178,185 ;;
            195) HZ=170,178,185,188,195 ;;
        esac ;;
    ace5p)
        HZ=130,132,138,141,144,150 ;;
    gt7p)
        case "$HZ_CHOICE" in
            130) HZ=130 ;;
            142) HZ=130,142 ;;
            144) HZ=130,142,144 ;;
        esac ;;
    op11) HZ="" ;;
esac
if [ "$HZ_CHOICE" = "0" ]; then
    HZ=""
    log "本机型不超频, 仅应用电池/充电方案 (BATTERY=$BATTERY)"
    [ "$BATTERY" = "0" ] && { log "电池方案也为原版, 无需任何修改"; exit 0; }
else
    [ -z "$HZ" ] && { log "[错误] 档位展开失败"; exit 1; }
    log "生成档位列表: $HZ (电池模式 $BATTERY)"
fi

NEW="$WORK/patched.img"
rm -rf "$WORK"/e*_* 2>/dev/null
PATCH_ARGS="--img $STOCK --out $NEW --dtc $DTC --battery $BATTERY --workdir $WORK"
[ -n "$HZ" ] && PATCH_ARGS="$PATCH_ARGS --hz $HZ"
[ "$DEVICE" = "gt7p" ] && PATCH_ARGS="$PATCH_ARGS --gt7p"
"$TOOL" patch $PATCH_ARGS >> "$LOG" 2>&1
RC=$?
[ "$RC" != "0" ] && [ "$RC" != "3" ] && { log "[错误] 补丁生成失败 (exit=$RC), 详情见 $LOG, 未做任何写入"; exit 1; }

if cmp -s "$CUR" "$NEW"; then
    log "当前 DTBO 已是目标状态, 无需刷入"
    exit 0
fi

rm -rf "$WORK"/c*_* 2>/dev/null
CKOUT=$("$TOOL" checkoc --img "$CUR" --stock-img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>>"$LOG")
NOC=$(echo "$CKOUT" | grep '^NOC=' | cut -d= -f2)
MISSING=$(echo "$CKOUT" | grep '^MISSING=' | cut -d= -f2)
FOREIGN=$(echo "$CKOUT" | grep '^FOREIGN=' | cut -d= -f2)
[ -z "$MISSING" ] && MISSING=0
[ -z "$FOREIGN" ] && FOREIGN=0
if { [ "$NOC" = "0" ] || [ "$MISSING" != "0" ] || [ "$FOREIGN" != "0" ]; } && ! cmp -s "$CUR" "$STOCK"; then
    log "检测到 dtbo 分区被系统更新 (OTA, NOC=$NOC MISSING=$MISSING FOREIGN=$FOREIGN), 重新备份原厂基准并生成补丁"
    cp "$CUR" "$STOCK"
    [ -n "$BACKUP_PATH" ] && cp "$STOCK" "$BACKUP_PATH"
    rm -rf "$WORK"/e*_* 2>/dev/null
    "$TOOL" patch $PATCH_ARGS >> "$LOG" 2>&1
    RC=$?
    [ "$RC" != "0" ] && [ "$RC" != "3" ] && { log "[错误] 新基准补丁生成失败 (exit=$RC), 未做任何写入"; exit 1; }
    if cmp -s "$CUR" "$NEW"; then
        log "新基准下当前 DTBO 已是目标状态, 无需刷入"
        exit 0
    fi
fi

if [ -n "$BACKUP_PATH" ] && [ ! -f "$BACKUP_PATH" ]; then
    cp "$STOCK" "$BACKUP_PATH" && log "原始镜像已备份到 $BACKUP_PATH"
fi

if [ "${FLASH:-1}" != "1" ]; then
    cp "$NEW" /sdcard/dtbo_oc_patched.img
    log "FLASH=0: 已生成 /sdcard/dtbo_oc_patched.img (手动刷入: dd if=/sdcard/dtbo_oc_patched.img of=$DTBO)"
    exit 0
fi

log "正在刷入 $NEW -> $DTBO"
if ! dd if="$NEW" of="$DTBO" 2>>"$LOG"; then
    log "[错误] 刷入失败"
    exit 1
fi
sync
VRF="$WORK/verify.img"
dd if="$DTBO" of="$VRF" 2>>"$LOG"
if cmp -s "$VRF" "$NEW"; then
    log "刷入成功且校验一致, 重启后新档位/电池方案生效"
else
    log "[警告] 刷入后回读不一致! 建议检查分区或手动恢复备份"
    exit 1
fi
