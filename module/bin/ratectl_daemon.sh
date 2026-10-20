#!/system/bin/sh
DATA_DIR=/data/adb/dtbo_oc
RC_CONF="$DATA_DIR/ratectl"
RC_PID="$DATA_DIR/ratectl.pid"
RC_LOG="$DATA_DIR/ratectl.log"
WORK="$DATA_DIR/work"
SF_LOCK=/data/local/tmp/dtbo_oc_switch.lock
SF_PIN="$DATA_DIR/sf_pin"
RC_SF="$WORK/rc_sf_modes.txt"
RC_DISP="$WORK/rc_sf_displays.txt"
rclog() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$RC_LOG"
    [ -f "$RC_LOG" ] && [ "$(wc -c < "$RC_LOG")" -gt 65536 ] && tail -n 200 "$RC_LOG" > "$RC_LOG.tmp" 2>/dev/null && mv -f "$RC_LOG.tmp" "$RC_LOG"
}
cleanup() {
    rm -f "$RC_PID"
    if [ -f "$SF_LOCK/pid" ] && [ "$(cat "$SF_LOCK/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$SF_LOCK/pid"
        rmdir "$SF_LOCK" 2>/dev/null
    fi
    exit 0
}
trap cleanup INT TERM
RC_BASE=""; RC_LADDER=""; RC_PERAPP=0; RC_LOCKBOOT=0
rc_load() {
    RC_BASE=""; RC_LADDER=""; RC_PERAPP=0; RC_LOCKBOOT=0
    [ -f "$RC_CONF" ] || return 0
    RC_BASE=$(sed -n 's/^BASE=//p' "$RC_CONF" | tail -n 1)
    RC_LADDER=$(sed -n 's/^LADDER=//p' "$RC_CONF" | tail -n 1)
    RC_PERAPP=$(sed -n 's/^PERAPP=//p' "$RC_CONF" | tail -n 1)
    RC_LOCKBOOT=$(sed -n 's/^LOCKBOOT=//p' "$RC_CONF" | tail -n 1)
    [ "$RC_PERAPP" = "1" ] || RC_PERAPP=0
    [ "$RC_LOCKBOOT" = "1" ] || RC_LOCKBOOT=0
    return 0
}
rc_app_hz() {
    [ -f "$RC_CONF" ] || return 1
    H=$(sed -n "s|^APP:$1=||p" "$RC_CONF" | tail -n 1)
    [ -n "$H" ] || return 1
    echo "$H"
    return 0
}
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
pin_active() {
    [ -f "$SF_PIN" ] || return 1
    [ "$(cut -d' ' -f1 "$SF_PIN" 2>/dev/null)" = "$(boot_id)" ] || { rm -f "$SF_PIN"; return 1; }
    return 0
}
sf_capture() {
    timeout -k 1 4 dumpsys -t 3 SurfaceFlinger --displays > "$RC_DISP" 2>&1 || return 1
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
    ' "$RC_DISP" > "$RC_SF" || return 1
    [ -s "$RC_SF" ] || return 1
    RC_DISPLAY=$(awk -F'|' '$1=="D"{print $2}' "$RC_SF")
    RC_POWER=$(awk -F'|' '$1=="D"{print $3}' "$RC_SF")
    RC_AID=$(awk -F'|' '$1=="A"{print $2}' "$RC_SF")
    [ -n "$RC_DISPLAY" ] && [ -n "$RC_AID" ] || return 1
    return 0
}
sf_send() {
    timeout -k 1 4 service call SurfaceFlinger 1035 i32 "$1" i64 "$RC_DISPLAY" >/dev/null 2>&1
}
try_lock() {
    mkdir "$SF_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$SF_LOCK/pid" 2>/dev/null || { rmdir "$SF_LOCK" 2>/dev/null; return 1; }
    return 0
}
do_unlock() {
    [ -f "$SF_LOCK/pid" ] && [ "$(cat "$SF_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$SF_LOCK/pid"
    rmdir "$SF_LOCK" 2>/dev/null
}
hz_to_id() {
    awk -F'|' -v hz="$1" -v g="$RC_AGRP" '$1=="M" && int($5+0.5)==hz && $6==g {print $2; exit}' "$RC_SF"
}
active_hz() {
    awk -F'|' '$1=="A"{print int($5+0.5); exit}' "$RC_SF"
}
send_hz() {
    HID=$(hz_to_id "$1")
    [ -n "$HID" ] || return 1
    try_lock || return 1
    OK=1
    sf_send "$HID" || OK=0
    do_unlock
    [ "$OK" = "1" ] || return 1
    printf '%s %s\n' "$(boot_id)" "$HID" > "$SF_PIN"
    return 0
}
front_pkg() {
    FP=$(dumpsys activity activities 2>/dev/null | grep -m1 'ResumedActivity' | sed -n 's/.* u0 \([^ /]*\)\/.*/\1/p')
    [ -n "$FP" ] && { echo "$FP"; return 0; }
    FP=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed -n 's/.* u0 \([^ /]*\)\/.*/\1/p')
    [ -n "$FP" ] && { echo "$FP"; return 0; }
    return 1
}
screen_awake() {
    [ "$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | cut -d= -f2)" = "Awake" ]
}
ladder_to() {
    CUR_HZ=$1; TGT=$2
    for L in $RC_LADDER_COMMA; do
        case "$L" in ''|*[!0-9]*) continue ;; esac
        [ "$L" -le "$CUR_HZ" ] && continue
        [ "$L" -lt "$TGT" ] || continue
        send_hz "$L" || return 1
        sleep 0.35
    done
    send_hz "$TGT" || return 1
    return 0
}
rc_load
[ -n "$RC_BASE" ] || { rclog "无基准档位配置, 退出"; exit 0; }
[ "$RC_PERAPP" = "1" ] || [ "$RC_LOCKBOOT" = "1" ] || { rclog "按应用切换与开机锁定均未开启, 退出"; exit 0; }
printf '%s\n' "$$" > "$RC_PID"
rclog "服务启动 (base=${RC_BASE}Hz ladder=${RC_LADDER:-无} perapp=$RC_PERAPP lockboot=$RC_LOCKBOOT)"
AWAKE=1
LAST_PKG=""; LAST_TGT=""
while :; do
    sleep 0.7
    rc_load
    if [ "$RC_PERAPP" != "1" ] && [ "$RC_LOCKBOOT" != "1" ] && ! pin_active; then
        rclog "功能均已关闭, 服务退出"
        cleanup
    fi
    [ -n "$RC_BASE" ] || continue
    if screen_awake; then
        JUST_AWAKE=0
        [ "$AWAKE" = "0" ] && JUST_AWAKE=1
        AWAKE=1
    else
        AWAKE=0
        continue
    fi
    sf_capture || continue
    [ "$RC_POWER" = "On" ] || continue
    RC_AGRP=$(awk -F'|' '$1=="A"{print $6}' "$RC_SF")
    RC_LADDER_COMMA=$(echo "$RC_LADDER" | tr ',' ' ')
    CUR_HZ=$(active_hz)
    [ -n "$CUR_HZ" ] || continue
    PINNED=0
    pin_active && PINNED=1
    if [ "$PINNED" != "1" ]; then
        [ "$RC_LOCKBOOT" = "1" ] || continue
        send_hz "$RC_BASE" || continue
        rclog "锁定基准 ${RC_BASE}Hz (开机/未锁定状态)"
        continue
    fi
    TGT="$RC_BASE"
    PKG="-"
    if [ "$RC_PERAPP" = "1" ]; then
        PKG=$(front_pkg || echo "-")
        APH=$(rc_app_hz "$PKG" 2>/dev/null)
        [ -n "$APH" ] && TGT="$APH"
    fi
    [ "$TGT" = "$LAST_TGT" ] && [ "$PKG" = "$LAST_PKG" ] && [ "$JUST_AWAKE" = "0" ] && [ "$CUR_HZ" = "$LAST_CUR" ] && continue
    if [ "$CUR_HZ" != "$TGT" ]; then
        if [ "$CUR_HZ" -lt "$TGT" ] 2>/dev/null; then
            ladder_to "$CUR_HZ" "$TGT" || { rclog "升挡 ${CUR_HZ}->${TGT}Hz 失败"; continue; }
            rclog "升挡 ${CUR_HZ} -> ${TGT}Hz (${PKG})"
        else
            send_hz "$TGT" || { rclog "回落 ${TGT}Hz 失败"; continue; }
            rclog "回落 ${CUR_HZ} -> ${TGT}Hz (${PKG})"
        fi
    elif [ "$JUST_AWAKE" = "1" ]; then
        send_hz "$TGT" || continue
        rclog "亮屏恢复 ${TGT}Hz (${PKG})"
    fi
    LAST_TGT=$TGT
    LAST_PKG=$PKG
    LAST_CUR=$TGT
done
