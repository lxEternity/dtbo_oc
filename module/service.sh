#!/system/bin/sh
# DTBO 刷新率超频 v2 — 开机自动执行 (多机型)
# 流程: 定位 dtbo -> 首次备份原始镜像 -> 读取 config(机型/档位/电池)
#       -> 始终以原始镜像为基准重建补丁 -> 与当前分区比对 -> 需要时刷入
# 始终从原始镜像重建 => 切换档位/电池方案时自动移除旧的超频节点, 天然幂等
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

# ---------------- 默认配置 ----------------
if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'EOF'
# DTBO 刷新率超频 v2 配置 (修改后重启生效; 也可运行 /data/adb/modules/dtbo_oc/menu.sh 交互修改)
#
# HZ_CHOICE: 超频目标档位 (仅生成 <= 此值的档位, 更高的不生成; 0 = 不超频)
#   ace2pro/gt7s 可选: 144/165/185     gt8 可选: 144/165/185/195
#   op12/op13/op13t/ace5/ace3/ace3pro 可选: 144
#   op15/ace6/op15t/ace6t 可选: 185    gt8p 可选: 165/185
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

# ---------------- 安全提示 (仅警告, 不阻止执行) ----------------
LOCKED=$(getprop ro.boot.flash.locked)
VBS=$(getprop ro.boot.verifiedbootstate)
if [ "$LOCKED" = "1" ] || [ "$VBS" = "green" ]; then
    log "[警告] Bootloader 处于锁定/校验状态 (flash.locked=$LOCKED verifiedbootstate=$VBS)"
    log "[警告] 未解锁 BL 刷入修改后的 DTBO 会导致无法开机(变砖)!"
    log "[警告] 请确认已解锁 Bootloader, 否则请立即卸载本模块并恢复原始 DTBO"
fi

# ---------------- 定位 dtbo 分区 ----------------
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

# ---------------- 原始镜像基准 ----------------
CUR="$WORK/current.img"
dd if="$DTBO" of="$CUR" 2>>"$LOG" || { log "[错误] 读取 $DTBO 失败"; exit 1; }
log "已提取当前 DTBO: $(wc -c < "$CUR") 字节"

if [ ! -f "$STOCK" ]; then
    # 首次运行: 当前分区视为原始镜像并备份
    # (若之前用过 v1.0.0 并留有 /sdcard/dtbo_backup.img, 优先使用该备份)
    if [ -f /sdcard/dtbo_backup.img ]; then
        cp /sdcard/dtbo_backup.img "$STOCK"
        log "已从 /sdcard/dtbo_backup.img 恢复原始镜像基准"
    else
        cp "$CUR" "$STOCK"
        log "首次运行: 当前分区已保存为原始镜像基准"
    fi
fi

# ---------------- 机型识别 ----------------
rm -rf "$WORK"/ide* 2>/dev/null
IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>>"$LOG")
DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
# 菜单档位选项
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
    op11)      CHOICES="";            DEF_HZ=0 ;;   # 一加11 不可超频
    *) log "[中止] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac
log "机型识别: $DEVNAME ($DEVICE)"

# 校正档位选择
if [ "$OC_OK" != "1" ] || [ -z "$CHOICES" ]; then
    if [ "${HZ_CHOICE:-0}" != "0" ]; then
        log "[提示] 本机型不支持刷新率超频, 已忽略档位设置 (HZ_CHOICE=$HZ_CHOICE)"
    fi
    HZ_CHOICE=0
else
    VALID=0
    for c in $CHOICES; do [ "$HZ_CHOICE" = "$c" ] && VALID=1; done
    if [ "$VALID" != "1" ]; then
        log "[提示] HZ_CHOICE=$HZ_CHOICE 不适用于本机型, 可选: $CHOICES, 使用默认 $DEF_HZ"
        HZ_CHOICE=$DEF_HZ
    fi
fi

# 校正电池选项
# BATTERY: 0=原版 1=解除限流 2=解除限流+关机2800 3=6100魔改 4=魔改+解除限流 5=原版+关机2800
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

# ---------------- 展开档位列表 ----------------
# 120Hz 面板机型 (ace2pro/op13/op13t/ace5/ace3/ace3pro) 144 档列表含 132/150:
#   130,132,138,141,144,150
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
    gt7p)
        # GT7P 竞速版实测档位: 130/142/144 (仅生成 <= HZ_CHOICE 的档位)
        case "$HZ_CHOICE" in
            130) HZ=130 ;;
            142) HZ=130,142 ;;
            144) HZ=130,142,144 ;;
        esac ;;
    op11) HZ="" ;;   # 一加11 不可超频
esac
if [ "$HZ_CHOICE" = "0" ]; then
    HZ=""
    log "本机型不超频, 仅应用电池/充电方案 (BATTERY=$BATTERY)"
    [ "$BATTERY" = "0" ] && { log "电池方案也为原版, 无需任何修改"; exit 0; }
else
    [ -z "$HZ" ] && { log "[错误] 档位展开失败"; exit 1; }
    log "生成档位列表: $HZ (电池模式 $BATTERY)"
fi

# ---------------- 从原始镜像重建补丁 ----------------
NEW="$WORK/patched.img"
rm -rf "$WORK"/e*_* 2>/dev/null
PATCH_ARGS="--img $STOCK --out $NEW --dtc $DTC --battery $BATTERY --workdir $WORK"
[ -n "$HZ" ] && PATCH_ARGS="$PATCH_ARGS --hz $HZ"
[ "$DEVICE" = "gt7p" ] && PATCH_ARGS="$PATCH_ARGS --gt7p"
"$TOOL" patch $PATCH_ARGS >> "$LOG" 2>&1
RC=$?
[ "$RC" != "0" ] && [ "$RC" != "3" ] && { log "[错误] 补丁生成失败 (exit=$RC), 详情见 $LOG, 未做任何写入"; exit 1; }

# ---------------- 幂等检查 ----------------
if cmp -s "$CUR" "$NEW"; then
    log "当前 DTBO 已是目标状态, 无需刷入"
    exit 0
fi

# 备份原始镜像到内置存储 (仅首次)
if [ -n "$BACKUP_PATH" ] && [ ! -f "$BACKUP_PATH" ]; then
    cp "$STOCK" "$BACKUP_PATH" && log "原始镜像已备份到 $BACKUP_PATH"
fi

if [ "${FLASH:-1}" != "1" ]; then
    cp "$NEW" /sdcard/dtbo_oc_patched.img
    log "FLASH=0: 已生成 /sdcard/dtbo_oc_patched.img (手动刷入: dd if=/sdcard/dtbo_oc_patched.img of=$DTBO)"
    exit 0
fi

# ---------------- 刷入并校验 ----------------
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
