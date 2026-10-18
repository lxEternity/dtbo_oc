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

mkdir -p "$DATA_DIR" "$WORK" "$WORK/ko"
: > "$LOG"
chmod 755 "$TOOL" "$DTC" 2>/dev/null

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'EOF'
HZ_CHOICE=144
BATTERY=0
OC_MODE=dtbo
LTPO_OFF=0
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
    log "已生成默认配置 $CONFIG"
fi
. "$CONFIG"
sed -i '/^AVB_OFF=/d' "$CONFIG" 2>/dev/null
[ -z "${OC_MODE:-}" ] && OC_MODE=dtbo
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac

LOCKED=$(getprop ro.boot.flash.locked)
VBS=$(getprop ro.boot.verifiedbootstate)
if [ "$LOCKED" = "1" ] || [ "$VBS" = "green" ]; then
    log "[警告] Bootloader 检测为锁定/校验状态 (flash.locked=$LOCKED verifiedbootstate=$VBS)"
    log "[警告] 未解锁 BL 刷入修改后的 DTBO 会导致无法开机(变砖)!"
    log "[警告] 请确认已解锁 Bootloader, 否则请卸载本模块并恢复原始 DTBO"
fi

SLOT=$(getprop ro.boot.slot_suffix)
DTBO="${DTBO_PATH:-}"
if [ -z "$DTBO" ]; then
    for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/soc/by-name; do
        for n in dtbo "dtbo$SLOT"; do
            [ -e "$d/$n" ] && DTBO="$d/$n" && break 2
        done
    done
fi
if [ -z "$DTBO" ]; then
    DTBO=$(ls -d /dev/block/platform/*/by-name/dtbo 2>/dev/null | head -n 1)
    [ -z "$DTBO" ] && DTBO=$(find /dev/block -maxdepth 4 -name 'dtbo*' 2>/dev/null | head -n 1)
fi
[ -z "$DTBO" ] && { log "[错误] 未找到 dtbo 分区; 可在 config 设置 DTBO_PATH"; exit 1; }
log "dtbo 分区: $DTBO (slot=$SLOT)"

ko_find() {
    if [ -f "$DATA_DIR/ko/$DEVICE.ko" ]; then
        echo "$DATA_DIR/ko/$DEVICE.ko"
    elif [ -f "$MODDIR/ko/$DEVICE.ko" ]; then
        echo "$MODDIR/ko/$DEVICE.ko"
    fi
}

ko_modname() {
    strings "$1" 2>/dev/null | sed -n 's/^name=//p' | head -n 1
}

ko_loaded_modname() {
    if [ -f "$DATA_DIR/ko_loaded" ]; then
        cat "$DATA_DIR/ko_loaded"
    else
        ls /sys/module 2>/dev/null | grep -E '_185_mode$|_oc_mode$|_drm_modes$' | head -n 1
    fi
}

ko_unload() {
    local MN=$(ko_loaded_modname)
    [ -z "$MN" ] && return 0
    [ -d "/sys/module/$MN" ] || { rm -f "$DATA_DIR/ko_loaded"; return 0; }
    case "$MN" in
        *_drm_modes)
            log "DRM-KO ($MN) 不支持在线卸载, 已停止加载, 重启后自动恢复原厂"
            return 0
            ;;
    esac
    echo 0 > "/sys/module/$MN/parameters/fake_mode" 2>/dev/null
    if rmmod "$MN" 2>>"$LOG"; then
        rm -f "$DATA_DIR/ko_loaded"
        log "已卸载 KO ($MN), 恢复挂载前原厂档位"
    else
        log "[警告] KO 卸载失败 ($MN)"
        return 1
    fi
    return 0
}

ko_status_report() {
    local KO=$(ko_find)
    if [ -z "$KO" ]; then
        log "[提示] KO方案: 本机型无内置 KO, 可自行放入 /data/adb/dtbo_oc/ko/$DEVICE.ko"
        return 0
    fi
    local MN=$(ko_modname "$KO")
    [ -n "$MN" ] && [ -d "/sys/module/$MN" ] || { log "[警告] KO 未加载 (详见 $DATA_DIR/ko_boot.log)"; return 0; }
    case "$MN" in
        *_drm_modes)
            local AP CA FC
            AP=$(cat "/sys/module/$MN/parameters/applied" 2>/dev/null)
            CA=$(cat "/sys/module/$MN/parameters/cache_applied" 2>/dev/null)
            FC=$(cat "/sys/module/$MN/parameters/failure_code" 2>/dev/null)
            if { [ "$AP" = "Y" ] || [ "$AP" = "1" ]; } && [ "$FC" = "0" ]; then
                log "DRM-KO 运行中 ($MN, applied=$AP cache=$CA failure=$FC)"
            else
                log "[警告] DRM-KO 状态异常 (applied=$AP cache=$CA failure=$FC)"
            fi
            ;;
        *)
            local ST=$(cat "/sys/module/$MN/parameters/status" 2>/dev/null)
            log "KO 运行中 ($MN, $ST)"
            ;;
    esac
    return 0
}

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
STRIP=$(echo "$IDINFO" | grep '^STRIP_ABOVE=' | cut -d= -f2)
[ -z "$STRIP" ] && STRIP=0
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
    ace6u)     CHOICES="185";             DEF_HZ=185 ;;
    ace5p)     CHOICES="144";         DEF_HZ=144 ;;
    gt7p2)     CHOICES="144";         DEF_HZ=144 ;;
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
if [ "$DEVICE" = "ace6u" ] && [ "$OC_MODE" != "ko" ]; then
    log "[提示] 一加ACE6至尊版仅支持 KO 内核挂载方案, 已自动切换 (DTBO 方案已移除)"
    OC_MODE=ko
    set_config_val() { sed -i "s/^$1=.*/$1=$2/" "$CONFIG"; }
    set_config_val OC_MODE ko
fi
case "$BATTERY" in 0|1|2|3|4|5|6) ;; *) BATTERY=0 ;; esac
if [ "$OC_MODE" = "ko" ] && [ "$BATTERY" != "0" ]; then
    log "[提示] KO 方案不修改 DTBO, 电池选项已忽略 (BATTERY=$BATTERY -> 0)"
    BATTERY=0
fi
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
log "方案: 档位 ${HZ_CHOICE:-0}, 电池模式 $BATTERY, 超频方案 $OC_MODE, LTPO禁用 ${LTPO_OFF:-0}"

expand_hz() {
    T=$1; L=""
    for t in 130 132 138 141 144 148 150 158 165 170 178 185 190 195 198; do
        [ "$t" -le "$T" ] || continue
        [ "$t" = "198" ] && [ "$T" -lt "195" ] && continue
        L="${L:+$L,}$t"
    done
    echo "$L"
}

if [ "$OC_MODE" = "ko" ]; then
    if [ "$HZ_CHOICE" = "0" ]; then
        log "KO 方案: 不超频, 仅确保原厂 DTBO 状态"
        ko_unload
        if ! cmp -s "$CUR" "$STOCK"; then
            log "正在恢复原厂 DTBO..."
            dd if="$STOCK" of="$DTBO" 2>>"$LOG" && sync
            rm -f "$DATA_DIR/.flash_fp" "$DATA_DIR/.rescue_lock"
            log "已恢复原厂 DTBO (KO 方案不修改分区)"
        fi
        exit 0
    fi
    if [ "$OC_OK" != "1" ]; then
        log "[错误] 本机型不支持超频, KO 方案退出"
        exit 1
    fi
    if ! cmp -s "$CUR" "$STOCK"; then
        log "KO 方案基于原厂 DTBO, 正在恢复原厂 DTBO..."
        if ! dd if="$STOCK" of="$DTBO" 2>>"$LOG"; then
            log "[错误] 恢复原厂 DTBO 失败, 停止 KO 加载"
            exit 1
        fi
        sync
        rm -f "$DATA_DIR/.flash_fp" "$DATA_DIR/.rescue_lock"
        log "已恢复原厂 DTBO"
    fi
    log "KO 内核超频方案 (post-fs-data 阶段加载, 不修改任何分区)"
    ko_status_report
    exit 0
fi

if [ "$HZ_CHOICE" = "0" ]; then
    HZ=""
    log "本机型不超频, 仅应用电池/充电方案 (BATTERY=$BATTERY)"
    [ "$BATTERY" = "0" ] && { log "电池方案也为原版, 无需任何修改"; exit 0; }
else
    if [ "$DEVICE" = "gt7p" ]; then
        case "$HZ_CHOICE" in
            130) HZ="130" ;;
            142) HZ="130,142" ;;
            *)   HZ="130,142,144" ;;
        esac
    elif [ "$DEVICE" = "op13" ]; then
        case "$HZ_CHOICE" in
            144) HZ="130,141,144" ;;
            *)   HZ="130,141,144,150" ;;
        esac
    else
        HZ=$(expand_hz "$HZ_CHOICE")
    fi
    [ -z "$HZ" ] && { log "[错误] 档位展开失败"; exit 1; }
    log "生成档位列表: $HZ (电池模式 $BATTERY, 原厂已有档位自动跳过)"
fi

ko_unload

NEW="$WORK/patched.img"
rm -rf "$WORK"/e*_* 2>/dev/null
PATCH_ARGS="--img $STOCK --out $NEW --dtc $DTC --battery $BATTERY --workdir $WORK"
[ -n "$HZ" ] && PATCH_ARGS="$PATCH_ARGS --hz $HZ"
[ "$DEVICE" = "gt7p" ] && PATCH_ARGS="$PATCH_ARGS --gt7p"
[ "$DEVICE" = "op13t" ] && PATCH_ARGS="$PATCH_ARGS --multifam"
[ "$STRIP" != "0" ] && PATCH_ARGS="$PATCH_ARGS --strip-above $STRIP"
[ "$DEVICE" = "op12" ] && PATCH_ARGS="$PATCH_ARGS --multifam"
[ "$DEVICE" = "op13" ] && PATCH_ARGS="$PATCH_ARGS --include-family wqhd_sdc"
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

# ---- v2.34 救援保护: 防止"fastboot 救回后又被自动刷入"的循环变砖 ----
if [ -f "$DATA_DIR/.rescue_lock" ]; then
    log "[保护] 自动刷入已锁定 (此前检测到补丁 DTBO 被还原为原厂镜像)"
    log "[保护] 这通常表示设备经 fastboot/手动救援恢复, 已停止写入以防再次变砖"
    log "[保护] 解除: WebUI 重新保存配置 / menu 菜单重新应用 / 重装模块"
    exit 0
fi
if [ -f "$DATA_DIR/.flash_fp" ] && cmp -s "$CUR" "$STOCK"; then
    if [ "$(cat "$DATA_DIR/.flash_fp" 2>/dev/null)" = "$(getprop ro.build.fingerprint)" ]; then
        log "[保护] 上次刷入的补丁 DTBO 已被还原为原厂 (系统版本未变, 非OTA)"
        log "[保护] 判定为救援恢复, 已锁定自动刷入, 防止救回的设备再次写入"
        log "[保护] 解除: WebUI 重新保存配置 / menu 菜单重新应用 / 重装模块"
        touch "$DATA_DIR/.rescue_lock"
        exit 0
    fi
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
    getprop ro.build.fingerprint > "$DATA_DIR/.flash_fp" 2>/dev/null
else
    log "[警告] 刷入后回读不一致! 建议检查分区或手动恢复备份"
    exit 1
fi
