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
chmod 755 "$TOOL" "$DTC" "$MODDIR/bin/ratectl_daemon.sh" 2>/dev/null


if [ -f "$DATA_DIR/chgcv.pid" ]; then
    kill "$(cat "$DATA_DIR/chgcv.pid" 2>/dev/null)" 2>/dev/null
    rm -f "$DATA_DIR/chgcv.pid"
fi
pkill -f chgcv_daemon.sh 2>/dev/null
if [ -d /proc/oplus-votable ]; then
    for VT in FV_MAX WIRED_FCC FV_MIN UFCS_NOT_ALLOW PPS_NOT_ALLOW VOOC_DISABLE VOOC_NOT_ALLOW PLC_FORCE_BUCK; do
        [ -d "/proc/oplus-votable/$VT" ] || continue
        echo 0 > "/proc/oplus-votable/$VT/force_val" 2>/dev/null
        echo 0 > "/proc/oplus-votable/$VT/force_active" 2>/dev/null
    done
fi
rm -f "$DATA_DIR/chgcv.conf" "$DATA_DIR/chgcv.state" "$DATA_DIR/chgcv.log" 2>/dev/null


(
    i=0
    while [ "$i" -lt 45 ]; do
        [ "$(getprop sys.boot_completed)" = "1" ] && break
        sleep 2
        i=$((i+1))
    done
    [ -f "$DATA_DIR/rates.conf" ] || exit 0
    _GID=$(grep -o '"globalRateId"[^0-9]*[0-9]*' "$DATA_DIR/rc_config.json" 2>/dev/null | grep -o '[0-9]*$')
    _ASW=$(grep -o '"appSwitchEnabled"[^a-z]*[a-z]*' "$DATA_DIR/rc_config.json" 2>/dev/null | grep -oE '(true|false)$')
    _NA=0
    [ -f "$DATA_DIR/apps.conf" ] && _NA=$(grep -c '=' "$DATA_DIR/apps.conf" 2>/dev/null)
    _RUN=0
    { [ -n "$_GID" ] && [ "$_GID" != "0" ]; } && _RUN=1
    { [ "$_ASW" != "false" ] && [ "${_NA:-0}" -gt 0 ]; } && _RUN=1
    [ "$_RUN" = "1" ] || exit 0
    if [ -f "$DATA_DIR/ratectl.pid" ]; then
        kill -0 "$(cat "$DATA_DIR/ratectl.pid" 2>/dev/null)" 2>/dev/null && exit 0
    fi
    nohup sh "$MODDIR/bin/ratectl_daemon.sh" >/dev/null 2>&1 &
) &

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'EOF'
HZ_CHOICE=144
BATT_LIMIT=0
BATT_UNCAP=0
BATT_VOFF=2800
BATT_MOD=0
OC_MODE=dtbo
LTPO_OFF=0
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
    log "已生成默认配置 $CONFIG"
fi
. "$CONFIG"

if grep -q '^BATTERY=' "$CONFIG" 2>/dev/null; then
    _OB=$(sed -n 's/^BATTERY=//p' "$CONFIG" | head -n 1)
    case "$_OB" in
        1) BATT_LIMIT=1 ;;
        2) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2800 ;;
        3) BATT_MOD=1 ;;
        4) BATT_MOD=1; BATT_LIMIT=1 ;;
        5) BATT_UNCAP=1; BATT_VOFF=2800 ;;
        6) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2850 ;;
    esac
    sed -i '/^BATTERY=/d' "$CONFIG"
    { echo "BATT_LIMIT=${BATT_LIMIT:-0}"; echo "BATT_UNCAP=${BATT_UNCAP:-0}"
      echo "BATT_VOFF=${BATT_VOFF:-2800}"; echo "BATT_MOD=${BATT_MOD:-0}"; } >> "$CONFIG"
    log "已迁移旧版电池方案 BATTERY=$_OB 到充电相关自定义参数"
fi
sed -i '/^AVB_OFF=/d' "$CONFIG" 2>/dev/null
[ -z "${OC_MODE:-}" ] && OC_MODE=dtbo
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac

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
    local p kv fb=""
    for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODDIR/ko/$DEVICE.ko"; do
        [ -f "$p" ] || continue
        [ -z "$fb" ] && fb="$p"
        kv=$(strings "$p" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 | cut -d' ' -f1)
        if [ -n "$kv" ] && [ "$kv" = "$(uname -r)" ]; then
            echo "$p"; return 0
        fi
    done
    [ -n "$fb" ] && echo "$fb"
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
        MODCHK=$("$TOOL" identify --img "$CUR" --dtc "$DTC" --workdir "$WORK/curid" 2>/dev/null)
        if [ "$(echo "$MODCHK" | grep '^MODIFIED=' | cut -d= -f2)" = "1" ]; then
            log "[警告] 当前 DTBO 已被修改 (档位/关机电压与原厂不一致), 以当前状态作为基准"
        fi
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
    
    ace2pro)   CHOICES="132 138 141 144 150 158 165 170 178 185"; DEF_HZ=144 ;;
    op13)      CHOICES="130 141 144 150"; DEF_HZ=144 ;;
  
    op12|op13t|ace5|ace5p|ace3|ace3pro|gt7p2) CHOICES="130 132 138 141 144 148 150"; DEF_HZ=144 ;;
 
    gt7s)      CHOICES="130 132 138 141 144 148 150 158 165 170 178 185"; DEF_HZ=185 ;;
   
    gt7p)      CHOICES="130 142 144"; DEF_HZ=144 ;;
    
    gt8p)      CHOICES="148 150 158 165 170 178 185 190"; DEF_HZ=185 ;;
    
    gt8)       CHOICES="148 150 158 165 170 178 185 190 195 198 205"; DEF_HZ=185 ;;
   
    ace6t)     CHOICES="170 178 185 190"; DEF_HZ=185 ;;
  
    op15|op15t|ace6) CHOICES="170 178 185 190 195 198 205"; DEF_HZ=185 ;;
    
    ace6u)     CHOICES="185"; DEF_HZ=185 ;;
    op11)      CHOICES=""; DEF_HZ=0 ;;
    *) log "[中止] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac
log "机型识别: $DEVNAME ($DEVICE)"


PLANS=""
case "$DEVICE" in
    ace2pro)     PLANS="144 165 185" ;;
    op13)        PLANS="144 150" ;;
    op12|op13t|ace5|ace5p|ace3|ace3pro|gt7p2) PLANS="144" ;;
    op15|op15t|ace6) PLANS="185 188 190 195 198" ;;
    gt8)         PLANS="144 165 185 188 190 195 198" ;;
    gt7p)        PLANS="130 142 144" ;;
    gt7s)        PLANS="144 165 185" ;;
    gt8p)        PLANS="165 185" ;;
    ace6t|ace6u) PLANS="185" ;;
esac

if [ "$OC_OK" != "1" ] || [ -z "$CHOICES" ]; then
    if [ "${HZ_CHOICE:-0}" != "0" ]; then
        log "[提示] 本机型不支持刷新率超频, 已忽略档位设置 (HZ_CHOICE=$HZ_CHOICE)"
    fi
    HZ_CHOICE=0
else
    VALID=0
    [ "$HZ_CHOICE" = "0" ] && VALID=1
    for c in $CHOICES $PLANS; do [ "$HZ_CHOICE" = "$c" ] && VALID=1; done
    if [ "$VALID" != "1" ]; then
        log "[提示] HZ_CHOICE=$HZ_CHOICE 不适用于本机型, 可选: $CHOICES 或 0(不超频), 使用默认 $DEF_HZ"
        HZ_CHOICE=$DEF_HZ
    fi
fi


[ -z "$BATT_LIMIT" ] && BATT_LIMIT=0
[ -z "$BATT_UNCAP" ] && BATT_UNCAP=0
[ -z "$BATT_MOD" ] && BATT_MOD=0
[ -z "$BATT_VOFF" ] && BATT_VOFF=2800
sed -i '/^BATT_FULL_ON=/d;/^BATT_FULL=/d' "$CONFIG" 2>/dev/null
case "$BATT_LIMIT" in 0|1) ;; *) BATT_LIMIT=0 ;; esac
case "$BATT_UNCAP" in 0|1) ;; *) BATT_UNCAP=0 ;; esac
case "$BATT_MOD" in 0|1) ;; *) BATT_MOD=0 ;; esac
case "$BATT_VOFF" in ''|*[!0-9]*) BATT_VOFF=2800 ;; esac
[ "$BATT_VOFF" -lt 2650 ] && BATT_VOFF=2650
[ "$BATT_VOFF" -gt 3150 ] && BATT_VOFF=3150
if [ "$BATT_MOD" = "1" ] && [ "$BATT_OK" != "1" ]; then
    log "[提示] 魔改电池仅 ACE2Pro/一加11/一加12 支持, 已重置为关闭"
    BATT_MOD=0
fi
BATT_ACTIVE=0
[ "$BATT_LIMIT" = "1" ] || [ "$BATT_UNCAP" = "1" ] || [ "$BATT_MOD" = "1" ] && BATT_ACTIVE=1
if [ "$OC_MODE" = "ko" ] && [ "$BATT_ACTIVE" = "1" ]; then
    log "[提示] KO 方案不修改 DTBO, 充电相关功能不可用 (已全部重置为关闭)"
    BATT_LIMIT=0; BATT_UNCAP=0; BATT_MOD=0; BATT_ACTIVE=0
fi
log "方案: 档位 ${HZ_CHOICE:-0}, 超频方案 $OC_MODE, LTPO禁用 ${LTPO_OFF:-0}, 充电相关: 限流=$BATT_LIMIT 解容=$BATT_UNCAP(${BATT_VOFF}mV) 魔改=$BATT_MOD"

NEED_OC=0
[ "${HZ_CHOICE:-0}" != "0" ] && NEED_OC=1
[ "$BATT_ACTIVE" = "1" ] && NEED_OC=1
if [ "$NEED_OC" = "1" ]; then
    LICOUT=$("$TOOL" license 2>/dev/null)
    case "$LICOUT" in
        LICENSE=ok*) : ;;
        *)
            "$TOOL" verify --auto >>"$LOG" 2>&1
            LICOUT=$("$TOOL" license 2>/dev/null)
            case "$LICOUT" in
                LICENSE=ok*) log "  授权过期, 自动重新验证通过" ;;
                *)
                    log "  QQ群验证未通过 ($LICOUT), 拒绝修改 DTBO / 挂载 KO"
                    log "  请通过 WebUI 或终端菜单完成QQ群验证 (联网验证, 授权30天)"
                    ko_unload
                    if ! cmp -s "$CUR" "$STOCK"; then
                        if dd if="$STOCK" of="$DTBO" 2>>"$LOG"; then
                            sync
                            log "  已恢复原厂 DTBO (撤销此前刷入的超频补丁)"
                        else
                            log "[警告] 恢复原厂 DTBO 失败, 建议手动恢复或重新验证"
                        fi
                    fi
                    exit 0
                    ;;
            esac
            ;;
    esac
fi

if [ "$OC_MODE" = "ko" ]; then
    if [ "$HZ_CHOICE" = "0" ]; then
        log "KO 方案: 不超频, 仅确保原厂 DTBO 状态"
        ko_unload
        if ! cmp -s "$CUR" "$STOCK"; then
            log "正在恢复原厂 DTBO..."
            dd if="$STOCK" of="$DTBO" 2>>"$LOG" && sync
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
        log "已恢复原厂 DTBO"
    fi
    log "KO 内核超频方案 (post-fs-data 阶段加载, 不修改任何分区)"
    ko_status_report
    exit 0
fi

if [ "$HZ_CHOICE" = "0" ]; then
    HZ=""
    log "本机型不超频, 仅应用充电相关方案"
    [ "$BATT_ACTIVE" = "0" ] && { log "充电相关功能全部关闭, 无需任何修改"; exit 0; }
else
   
    if [ "$DEVICE" = "gt7p" ]; then
        HZ="130,142,144"
    else
        HZ=$(echo "$CHOICES" | tr ' ' ',')
    fi
    [ -z "$HZ" ] && { log "[错误] 档位展开失败"; exit 1; }
    log "生成档位列表 (完整): $HZ (原厂已有档位自动跳过)"
fi

ko_unload

NEW="$WORK/patched.img"
rm -rf "$WORK"/e*_* 2>/dev/null
PATCH_ARGS="--img $STOCK --out $NEW --dtc $DTC --workdir $WORK"

[ "$BATT_LIMIT" = "1" ] && PATCH_ARGS="$PATCH_ARGS --batt-limit"
[ "$BATT_UNCAP" = "1" ] && PATCH_ARGS="$PATCH_ARGS --batt-uncap --batt-voff $BATT_VOFF"
[ "$BATT_MOD" = "1" ] && PATCH_ARGS="$PATCH_ARGS --batt-mod"
[ -n "$HZ" ] && PATCH_ARGS="$PATCH_ARGS --hz $HZ"
[ "$DEVICE" = "gt7p" ] && PATCH_ARGS="$PATCH_ARGS --gt7p"
[ "$DEVICE" = "gt7p2" ] && PATCH_ARGS="$PATCH_ARGS --gt7p2 --min-clone"
[ "$STRIP" != "0" ] && PATCH_ARGS="$PATCH_ARGS --strip-above $STRIP"
[ "$DEVICE" = "op13" ] && PATCH_ARGS="$PATCH_ARGS --include-family wqhd_sdc --ref-clone --include-panel AA569_P_3_A0019_dsc_cmd --include-project 0x5d0d"

case "$DEVICE" in
    ace3|ace3pro|ace5|ace5p|op13t|op12) PATCH_ARGS="$PATCH_ARGS --multifam --min-clone" ;;
    op15|op15t|ace6|ace6t|ace6u|gt8|gt8p|gt7s) PATCH_ARGS="$PATCH_ARGS --min-clone" ;;
esac
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

if [ -f "$DATA_DIR/.rescue_lock" ] || [ -f "$DATA_DIR/.flash_fp" ]; then
    rm -f "$DATA_DIR/.rescue_lock" "$DATA_DIR/.flash_fp"
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
