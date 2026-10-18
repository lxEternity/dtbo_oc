#!/system/bin/sh
PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:$PATH
export PATH
MODDIR=${0%/*}/..
TOOL="$MODDIR/arm64/dtbo_oc"
DTC="$MODDIR/arm64/dtc"
DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
CONFIG="$DATA_DIR/config"
STOCK="$DATA_DIR/dtbo_stock.img"
LOG="$DATA_DIR/last_run.log"
SF_LOCK=/data/local/tmp/dtbo_oc_switch.lock
SF_PIN="$DATA_DIR/sf_pin"
SF_OWNS_LOCK=0

json_string() {
    awk 'BEGIN{printf "\""} {if(NR>1) printf "\\n";
        gsub(/\\/,"\\\\"); gsub(/\"/,"\\\"");
        gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); printf "%s",$0}
        END{printf "\""}'
}

fail() {
    printf '{"ok":false,"message":'
    printf '%s' "$1" | json_string
    printf '}\n'
    exit 1
}

cleanup() {
    if [ "$SF_OWNS_LOCK" = 1 ]; then
        rm -f "$SF_LOCK/pid"
        rmdir "$SF_LOCK" 2>/dev/null
    fi
    return 0
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(id -u)" = "0" ] || fail "需要 root 权限"
mkdir -p "$DATA_DIR" "$WORK" "$WORK/ko"
chmod 755 "$TOOL" "$DTC" 2>/dev/null

SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/soc/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        [ -e "$d/$n" ] && DTBO="$d/$n" && break 2
    done
done
if [ -z "$DTBO" ]; then
    DTBO=$(ls -d /dev/block/platform/*/by-name/dtbo 2>/dev/null | head -n 1)
    [ -z "$DTBO" ] && DTBO=$(find /dev/block -maxdepth 4 -name 'dtbo*' 2>/dev/null | head -n 1)
fi

DEVICE=""
DEVNAME="未知机型"
MAXRATE=""
CHOICES=""
BATT_OK=0
OC_OK=1
if [ -f "$STOCK" ]; then
    rm -rf "$WORK"/ide* 2>/dev/null
    IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
    DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
    DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
    MAXRATE=$(echo "$IDINFO" | grep '^MAX_RATE=' | cut -d= -f2)
    BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
    OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
fi
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
expand_hz() {
    T=$1; L=""
    for t in 130 132 138 141 144 148 150 158 165 170 178 185 190 195 198; do
        [ "$t" -le "$T" ] || continue
        [ "$t" = "198" ] && [ "$T" -lt "195" ] && continue
        L="${L:+$L }$t"
    done
    echo "$L"
}
case "$DEVICE" in
    ace2pro)   CHOICES=$(expand_hz 185) ;;
    op13t)     CHOICES=$(expand_hz 144) ;;
    op15t)     CHOICES=$(expand_hz 195) ;;
    ace5)      CHOICES=$(expand_hz 144) ;;
    ace3)      CHOICES=$(expand_hz 144) ;;
    ace3pro)   CHOICES=$(expand_hz 144) ;;
    op12)      CHOICES=$(expand_hz 144) ;;
    op13)      CHOICES="130 141 144 150" ;;
    op15|ace6) CHOICES=$(expand_hz 195) ;;
    gt8)       CHOICES=$(expand_hz 195) ;;
    gt7p)      CHOICES="130 142 144" ;;
    gt7s)      CHOICES=$(expand_hz 185) ;;
    gt8p)      CHOICES=$(expand_hz 185) ;;
    ace6t)     CHOICES=$(expand_hz 185) ;;
    ace6u)     CHOICES="185" ;;
    ace5p)     CHOICES=$(expand_hz 144) ;;
    gt7p2)     CHOICES=$(expand_hz 144) ;;
    op11)      CHOICES="" ;;
esac

HZ=""
BATTERY=""
OC_MODE=""
LTPO_OFF=""
FLASH=""
if [ -f "$CONFIG" ]; then
    . "$CONFIG"
fi
HZ="${HZ_CHOICE:-}"
[ -z "$HZ" ] && HZ=0
[ -z "$BATTERY" ] && BATTERY=0
[ -z "$OC_MODE" ] && OC_MODE=dtbo
[ -z "$LTPO_OFF" ] && LTPO_OFF=0
if [ "$DEVICE" = "ace6u" ] && [ "$OC_MODE" != "ko" ]; then OC_MODE=ko; fi
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac

KO_FILE=""
KO_AVAIL=0
KO_LOADED=0
KO_INSTALLED=0
KO_VERMATCH=""
if [ -n "$DEVICE" ]; then
    for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODDIR/ko/$DEVICE.ko"; do
        if [ -f "$p" ]; then KO_FILE="$p"; KO_AVAIL=1; break; fi
    done
fi
KO_MN=""
if [ -n "$KO_FILE" ]; then
    KO_MN=$(strings "$KO_FILE" 2>/dev/null | sed -n 's/^name=//p' | head -n 1)
fi
[ -z "$KO_MN" ] && KO_MN=$(ls /sys/module 2>/dev/null | grep -E '_185_mode$|_oc_mode$|_drm_modes$' | head -n 1)
if [ -n "$KO_FILE" ]; then
    KOVER=$(strings "$KO_FILE" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 | cut -d' ' -f1)
    if [ -n "$KOVER" ]; then
        if [ "$KOVER" = "$(uname -r)" ]; then KO_VERMATCH="1"; else KO_VERMATCH="0"; fi
    fi
fi
if [ -n "$KO_MN" ] && [ -d "/sys/module/$KO_MN" ]; then
    KO_LOADED=1
    case "$KO_MN" in
        *_drm_modes)
            AP=$(cat "/sys/module/$KO_MN/parameters/applied" 2>/dev/null)
            FC=$(cat "/sys/module/$KO_MN/parameters/failure_code" 2>/dev/null)
            { [ "$AP" = "Y" ] || [ "$AP" = "1" ]; } && [ "$FC" = "0" ] && KO_INSTALLED=1
            ;;
        *)
            KST=$(cat "/sys/module/$KO_MN/parameters/status" 2>/dev/null)
            case "$KST" in *installed=1*) KO_INSTALLED=1 ;; esac
            ;;
    esac
fi

DTBO_PATCHED=0
if [ -n "$DTBO" ] && [ -f "$STOCK" ]; then
    dd if="$DTBO" of="$WORK/web_cur.img" 2>/dev/null
    cmp -s "$WORK/web_cur.img" "$STOCK" || DTBO_PATCHED=1
fi

sf_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

sf_pin_active() {
    [ -f "$SF_PIN" ] || return 1
    PIN_BOOT=$(cut -d' ' -f1 "$SF_PIN" 2>/dev/null)
    [ "$PIN_BOOT" = "$(sf_boot_id)" ] || { rm -f "$SF_PIN"; return 1; }
    return 0
}

sf_capture() {
    timeout -k 1 4 dumpsys -t 3 SurfaceFlinger --displays > "$WORK/sf_displays.txt" 2>&1 || return 1
    awk '
    function value(line, key, part) {
        part=line
        if (index(part,key "=")==0) return ""
        sub("^.*" key "=", "", part)
        sub(/[,} ].*$/, "", part)
        return part
    }
    function mode(line, tag, id, res, hzv, grp, n, xy) {
        id=value(line,"id"); res=value(line,"resolution")
        hzv=value(line,"vsyncRate"); grp=value(line,"group")
        n=split(res,xy,"x")
        if (id !~ /^[0-9]+$/ || n!=2 || xy[1] !~ /^[0-9]+$/ || xy[2] !~ /^[0-9]+$/ ||
            hzv !~ /^[0-9]+([.][0-9]+)?$/ || grp !~ /^[0-9]+$/ || hzv<=0) { bad=1; return }
        printf "%s|%s|%s|%s|%s|%s\n",tag,id,xy[1],xy[2],hzv,grp
    }
    /^Display [0-9]+$/ { displays++; display=$2 }
    /^[[:space:]]*connectionType=/ { internal=($0 ~ /connectionType=Internal/) }
    /^[[:space:]]*powerMode=/ { power=tolower(value($0,"powerMode")) }
    /^[[:space:]]*renderRate=/ { render=value($0,"renderRate") }
    /^[[:space:]]*activeMode=/ { active++; mode($0,"A") }
    /^[[:space:]]*\{id=/ { mode($0,"M") }
    END {
        if (bad || displays!=1 || active!=1 || !internal ||
            display !~ /^[0-9]+$/ || render !~ /^[0-9]+([.][0-9]+)?$/) exit 1
        if (power=="on") power="On"; else power="Off"
        printf "D|%s|%s|%s\n",display,power,render
    }
    ' "$WORK/sf_displays.txt" > "$WORK/sf_modes.txt" || return 1
    [ -s "$WORK/sf_modes.txt" ] || return 1
    SF_DISPLAY=$(awk -F'|' '$1=="D"{print $2}' "$WORK/sf_modes.txt")
    SF_POWER=$(awk -F'|' '$1=="D"{print $3}' "$WORK/sf_modes.txt")
    SF_RENDER=$(awk -F'|' '$1=="D"{print $4}' "$WORK/sf_modes.txt")
    SF_AID=$(awk -F'|' '$1=="A"{print $2}' "$WORK/sf_modes.txt")
    [ -n "$SF_DISPLAY" ] && [ -n "$SF_AID" ] || return 1
    return 0
}

sf_send() {
    timeout -k 1 4 service call SurfaceFlinger 1035 i32 "$1" i64 "$SF_DISPLAY" >/dev/null 2>&1
}

sf_lock() {
    if ! mkdir "$SF_LOCK" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$$" > "$SF_LOCK/pid" 2>/dev/null || { rmdir "$SF_LOCK" 2>/dev/null; return 1; }
    SF_OWNS_LOCK=1
    return 0
}

sf_release_quiet() {
    if sf_pin_active; then
        sf_capture 2>/dev/null && sf_send -1
        rm -f "$SF_PIN"
    fi
}

emit_display_json() {
    AG=$(awk -F'|' '$1=="A"{print $6}' "$WORK/sf_modes.txt")
    AW=$(awk -F'|' '$1=="A"{print $3}' "$WORK/sf_modes.txt")
    AH=$(awk -F'|' '$1=="A"{print $4}' "$WORK/sf_modes.txt")
    AHZ=$(awk -F'|' '$1=="A"{print $5}' "$WORK/sf_modes.txt")
    RR=$(awk -v v="$SF_RENDER" 'BEGIN{printf "%.2f", v+0}')
    AHZI=$(awk -v v="$AHZ" 'BEGIN{printf "%d", int(v+0.5)}')
    if sf_pin_active; then PINNED=1; else PINNED=0; fi
    printf '"sf":{"ok":true,"power":"%s","render_hz":%s,"pinned":%s,' "$SF_POWER" "$RR" "$PINNED"
    printf '"active":{"id":%s,"w":%s,"h":%s,"hz":%s,"group":%s},' "$SF_AID" "$AW" "$AH" "$AHZI" "$AG"
    awk -F'|' -v agr="$AG" '
    $1=="M" {
        key=$3"x"$4"@"int($5+0.5)
        if (!(key in best)) { best[key]=$0; keys[++n]=key; next }
        split(best[key], b, "|")
        if ($6==agr && b[6]!=agr) best[key]=$0
    }
    END { for (i=1;i<=n;i++) print best[keys[i]] }
    ' "$WORK/sf_modes.txt" > "$WORK/sf_dedup.txt"
    printf '"modes":['
    awk -F'|' '{ if (n++) printf ","; printf "{\"id\":%s,\"w\":%s,\"h\":%s,\"hz\":%d,\"group\":%s}", $2,$3,$4,int($5+0.5),$6 }' "$WORK/sf_dedup.txt"
    printf ']}'
}

emit_status() {
    CHOICES_JSON=$(echo "$CHOICES" | tr ' ' ',' | sed 's/^,$//;s/,$//')
    OC_ACTIVE=0
    if [ "$OC_MODE" = "ko" ]; then
        [ "$KO_LOADED" = "1" ] && OC_ACTIVE=1
    elif [ "$HZ" != "0" ] && [ -n "$HZ" ] && [ "$DTBO_PATCHED" = "1" ]; then
        OC_ACTIVE=1
    fi
    KO_BUILTIN=0
    [ -n "$DEVICE" ] && [ -f "$MODDIR/ko/$DEVICE.ko" ] && KO_BUILTIN=1
    printf '{"ok":true,"device":"%s","name":' "$DEVICE"
    printf '%s' "$DEVNAME" | json_string
    printf ',"maxrate":"%s","choices":[%s],"oc_capable":%s,"batt_capable":%s,' "$MAXRATE" "$CHOICES_JSON" "$OC_OK" "$BATT_OK"
    printf '"hz":%s,"battery":%s,"oc_mode":"%s","ltpo_off":%s,"ko_only":%s,' "$HZ" "$BATTERY" "$OC_MODE" "$LTPO_OFF" "$([ "$DEVICE" = "ace6u" ] && echo true || echo false)"
    printf '"oc_active":%s,' "$OC_ACTIVE"
    printf '"ko":{"available":%s,"builtin":%s,"loaded":%s,"installed":%s,"vermatch":%s,"file":' "$KO_AVAIL" "$KO_BUILTIN" "$KO_LOADED" "$KO_INSTALLED" "${KO_VERMATCH:-null}"
    printf '%s' "${KO_FILE:-}" | json_string
    printf '},"dtbo_patched":%s,"stock_ok":%s,"version":"v2.35"' "$DTBO_PATCHED" "$([ -f "$STOCK" ] && echo 1 || echo 0)"
    if sf_capture 2>/dev/null; then
        printf ','
        emit_display_json
    else
        printf ',"sf":{"ok":false}'
    fi
    printf '}\n'
}

batt_valid() {
    case "$1" in
        0|1|2|5) return 0 ;;
        3|4) [ "$BATT_OK" = "1" ] && return 0; return 1 ;;
        6) [ "$DEVICE" = "gt7p" ] && return 0; return 1 ;;
    esac
    return 1
}

set_config_val() {
    sed -i "s|^$1=.*|$1=$2|" "$CONFIG" 2>/dev/null
    grep -q "^$1=" "$CONFIG" || echo "$1=$2" >> "$CONFIG"
}

ltpo_apply() {
    command -v resetprop >/dev/null 2>&1 || return 1
    if [ "$LTPO_OFF" = "1" ]; then
        resetprop -n persist.oplus.display.vrr 0
        resetprop -n persist.oplus.display.vrr.adfr 0
        resetprop -n debug.oplus.display.dynamic_fps_switch 0
        resetprop -n sys.display.vrr.vote.support 0
        resetprop -n vendor.display.enable_dpps_dynamic_fps 0
        resetprop -n ro.display.brightness.brightness.mode 1
        resetprop -n debug.egl.swapinterval 1
    else
        resetprop --delete persist.oplus.display.vrr 2>/dev/null
        resetprop --delete persist.oplus.display.vrr.adfr 2>/dev/null
        resetprop --delete debug.oplus.display.dynamic_fps_switch 2>/dev/null
        resetprop --delete sys.display.vrr.vote.support 2>/dev/null
        resetprop --delete vendor.display.enable_dpps_dynamic_fps 2>/dev/null
        resetprop --delete ro.display.brightness.brightness.mode 2>/dev/null
        resetprop --delete debug.egl.swapinterval 2>/dev/null
    fi
    return 0
}

emit_result_with_sf() {
    printf '{"ok":true,"message":'
    printf '%s' "$1" | json_string
    printf ','
    emit_display_json
    printf '}\n'
}

case "${1:-}" in
    status)
        emit_status
        ;;
    save)
        shift
        MSG=""
        for kv in "$@"; do
            K=${kv%%=*}
            V=${kv#*=}
            case "$K" in
                hz)
                    OK=0
                    [ "$V" = "0" ] && OK=1
                    for c in $CHOICES; do [ "$V" = "$c" ] && OK=1; done
                    [ "$OK" = "1" ] || fail "档位 $V 不适用于本机型"
                    HZ="$V"
                    ;;
                battery)
                    batt_valid "$V" || fail "电池选项 $V 不适用于本机型"
                    BATTERY="$V"
                    ;;
                oc_mode)
                    case "$V" in dtbo|ko) OC_MODE="$V" ;; *) fail "未知超频方案 $V" ;; esac
                    ;;
                ltpo_off)
                    case "$V" in 0|1) LTPO_OFF="$V" ;; *) fail "LTPO 参数无效" ;; esac
                    ;;
            esac
        done
        if [ "$DEVICE" = "ace6u" ] && [ "$OC_MODE" != "ko" ]; then
            fail "一加ACE6至尊版仅支持 KO 方案 (DTBO 方案已移除)"
        fi
        if [ "$OC_MODE" = "ko" ] && [ "$KO_AVAIL" != "1" ]; then
            fail "本机型未找到 KO ($DEVICE.ko), 无法使用 KO 方案"
        fi
        if [ "$OC_MODE" = "ko" ]; then
            if [ "$BATTERY" != "0" ]; then
                BATTERY=0
                MSG="KO 方案不修改 DTBO, 电池选项已重置为原版; "
            fi
        fi
        if [ ! -f "$CONFIG" ]; then
            cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ
BATTERY=$BATTERY
OC_MODE=$OC_MODE
LTPO_OFF=$LTPO_OFF
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
        else
            set_config_val HZ_CHOICE "$HZ"
            set_config_val BATTERY "$BATTERY"
            set_config_val OC_MODE "$OC_MODE"
            set_config_val LTPO_OFF "$LTPO_OFF"
        fi
        if [ "$OC_MODE" = "dtbo" ] && { [ "$HZ" != "0" ] || [ "$BATTERY" != "0" ]; }; then
            rm -f "$DATA_DIR/.flash_fp" "$DATA_DIR/.rescue_lock"
        fi
        if ltpo_apply; then
            if [ "$LTPO_OFF" = "1" ]; then
                MSG="${MSG}LTPO 已禁用 (已即时应用); "
            else
                MSG="${MSG}LTPO 已恢复默认 (已即时应用); "
            fi
        fi
        printf '{"ok":true,"message":'
        printf '%s' "${MSG}配置已保存" | json_string
        printf '}\n'
        ;;
    apply)
        sf_release_quiet
        sh "$MODDIR/service.sh" > "$WORK/webui_apply.log" 2>&1
        RC=$?
        TAIL=$(tail -n 6 "$WORK/webui_apply.log" 2>/dev/null | tr '\n' ' ' | cut -c1-400)
        printf '{"ok":%s,"rc":%s,"message":' "$([ $RC -eq 0 ] && echo true || echo false)" "$RC"
        printf '%s' "$TAIL" | json_string
        printf '}\n'
        ;;
    restore)
        sf_release_quiet
        MODNM=""
        if [ -f "$DATA_DIR/ko_loaded" ]; then
            MODNM=$(cat "$DATA_DIR/ko_loaded" 2>/dev/null)
        fi
        [ -z "$MODNM" ] && MODNM=$(ls /sys/module 2>/dev/null | grep -E '_185_mode$|_oc_mode$' | head -n 1)
        if [ -n "$MODNM" ] && [ -d "/sys/module/$MODNM" ]; then
            case "$MODNM" in
                *_drm_modes) ;;
                *)
                    echo 0 > "/sys/module/$MODNM/parameters/fake_mode" 2>/dev/null
                    rmmod "$MODNM" 2>/dev/null
                    ;;
            esac
        fi
        rm -f "$DATA_DIR/ko_loaded" "$DATA_DIR/.flash_fp" "$DATA_DIR/.rescue_lock"
        RESTORED=0
        if [ -n "$DTBO" ] && [ -f "$STOCK" ]; then
            if dd if="$STOCK" of="$DTBO" 2>/dev/null; then
                sync
                RESTORED=1
            fi
        fi
        if [ -f "$CONFIG" ]; then
            sed -i 's/^HZ_CHOICE=.*/HZ_CHOICE=0/;s/^BATTERY=.*/BATTERY=0/;s/^LTPO_OFF=.*/LTPO_OFF=0/' "$CONFIG"
        fi
        LTPO_OFF=0
        ltpo_apply 2>/dev/null
        printf '{"ok":%s,"message":' "$([ $RESTORED -eq 1 ] && echo true || echo false)"
        printf '%s' "已恢复原厂 DTBO, KO 停止加载 (重启后完全移除), LTPO 已恢复默认, 配置已重置为不超频" | json_string
        printf '}\n'
        ;;
    switch)
        ID="${2:-}"
        case "$ID" in ''|*[!0-9]*) fail "档位 ID 无效" ;; esac
        sf_capture || fail "无法读取当前显示状态 (若连接了外接显示请断开后重试)"
        [ "$SF_POWER" = "On" ] || fail "请先点亮并解锁屏幕"
        sf_lock || fail "已有切换任务进行中, 请稍后重试"
        awk -F'|' -v id="$ID" '$1=="M" && $2==id {f=1} END{exit !f}' "$WORK/sf_modes.txt" || fail "所选档位不存在, 请刷新后重试"
        OLD="$SF_AID"
        if [ "$ID" = "$OLD" ]; then
            emit_result_with_sf "系统已处于所选档位"
            exit 0
        fi
        TW=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print $3}' "$WORK/sf_modes.txt")
        TH=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print $4}' "$WORK/sf_modes.txt")
        THZ=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print int($5+0.5)}' "$WORK/sf_modes.txt")
        sf_send "$ID" || fail "切换指令发送失败 (本机系统可能不支持在线切换)"
        OK=0
        TRY=0
        while [ "$TRY" -lt 3 ]; do
            sleep 0.4
            if sf_capture && [ "$SF_POWER" = "On" ] && [ "$SF_AID" = "$ID" ]; then
                AW2=$(awk -F'|' '$1=="A"{print $3}' "$WORK/sf_modes.txt")
                AH2=$(awk -F'|' '$1=="A"{print $4}' "$WORK/sf_modes.txt")
                AHZ2=$(awk -F'|' '$1=="A"{print int($5+0.5)}' "$WORK/sf_modes.txt")
                if [ "$AW2" = "$TW" ] && [ "$AH2" = "$TH" ] && [ "$AHZ2" = "$THZ" ]; then OK=1; break; fi
            fi
            TRY=$((TRY+1))
        done
        if [ "$OK" != "1" ]; then
            sf_capture 2>/dev/null && sf_send "$OLD"
            sf_capture 2>/dev/null && sf_send -1
            fail "系统未确认所选档位, 已请求还原并交还系统自动切换"
        fi
        printf '%s %s\n' "$(sf_boot_id)" "$ID" > "$SF_PIN"
        emit_result_with_sf "已切换并经系统确认; 系统自动调频已暂停, 点交还可恢复"
        ;;
    release)
        sf_capture || fail "无法读取当前显示状态"
        sf_lock || fail "已有切换任务进行中, 请稍后重试"
        sf_send -1 || fail "交还指令发送失败 (本机系统可能不支持)"
        rm -f "$SF_PIN"
        sleep 0.4
        sf_capture 2>/dev/null
        emit_result_with_sf "已交还系统自动切换; 若停留在低档位, 亮屏点按屏幕即可恢复调频"
        ;;
    log)
        printf '{"ok":true,"log":'
        { tail -n 30 "$LOG" 2>/dev/null; echo "--- ko_boot.log ---"; tail -n 20 "$DATA_DIR/ko_boot.log" 2>/dev/null; } | json_string
        printf '}\n'
        ;;
    *)
        fail "未知操作"
        ;;
esac
