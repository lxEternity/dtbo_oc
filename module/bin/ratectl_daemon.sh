#!/system/bin/sh
# ratectl_daemon: 星驰引擎 (Astra_MaxRefresh_Pro) 式刷新率守护
# 移植星驰核心机制: rates.conf 档位表 (id:w:h:fps:type:base:ord) +
# 全局档位锁定 + 按应用切换 + 超频档双向逐级步进 (50ms) + 亮屏自动恢复
# 配置 (/data/adb/dtbo_oc/):
#   rates.conf    档位表  id:w:h:fps:type(native|overclock):base(0|1):ord
#   rc_config.json {"globalRateId":id, "appSwitchEnabled":bool, "appSwitchInterval":sec}
#   apps.conf     按应用规则  pkg=id
DATA_DIR=/data/adb/dtbo_oc
RATES="$DATA_DIR/rates.conf"
CFG="$DATA_DIR/rc_config.json"
APPS="$DATA_DIR/apps.conf"
PIDF="$DATA_DIR/ratectl.pid"
LOG="$DATA_DIR/ratectl.log"

rclog() {
    echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && tail -n 200 "$LOG" > "$LOG.t" 2>/dev/null && mv -f "$LOG.t" "$LOG"
}

cleanup() { rm -f "$PIDF"; exit 0; }
trap cleanup INT TERM

wait_boot() {
    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 1; done
}

screen_on() {
    local s=$(dumpsys power 2>/dev/null | grep -oE "mWakefulness=[A-Za-z]+" | head -n1 | cut -d= -f2)
    [ "$s" = "Awake" ] && echo 1 || echo 0
}

jnum() {
    grep -o "\"$1\"[^0-9]*[0-9]*" "$2" 2>/dev/null | grep -o '[0-9]*$'
}

jbool() {
    grep -o "\"$1\"[^a-z]*[a-z]*" "$2" 2>/dev/null | grep -oE '(true|false)$'
}

is_num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

# 星驰: 拓宽系统刷新率上下限, 防止 settings 层把档位拉回 60/120
widen_rates() {
    settings put system peak_refresh_rate 240.0 2>/dev/null
    settings put system min_refresh_rate 10.0 2>/dev/null
}

cur_id=""
saved_id=""
app_sw="true"
app_intv="1"
last_app="__INIT__"
cfg_mt=0
apps_mt=0
rates_mt=0

load_cfg() {
    [ ! -f "$CFG" ] && return
    local v=$(jnum "globalRateId" "$CFG")
    # 0/空 = 未设置全局锁定
    if [ -n "$v" ] && [ "$v" != "0" ]; then saved_id="$v"; else saved_id=""; fi
    local e=$(jbool "appSwitchEnabled" "$CFG")
    if [ "$e" = "false" ]; then app_sw="false"; else app_sw="true"; fi
    local i=$(jnum "appSwitchInterval" "$CFG")
    [ -n "$i" ] && [ "$i" -ge 1 ] 2>/dev/null && app_intv="$i"
}

rate_line() {
    [ ! -f "$RATES" ] && return
    awk -F: -v id="$1" '$1==id {print; exit}' "$RATES" 2>/dev/null
}

rate_type() {
    local l=$(rate_line "$1")
    [ -z "$l" ] && return
    echo "$l" | awk -F: '{print $5}'
}

rate_res() {
    local l=$(rate_line "$1")
    [ -z "$l" ] && return
    echo "$l" | awk -F: '{print $2 "x" $3}'
}

rate_ord() {
    local l=$(rate_line "$1")
    [ -z "$l" ] && echo 0 && return
    local o=$(echo "$l" | awk -F: '{print $7}')
    [ -z "$o" ] && echo 0 || echo "$o"
}

native_base() {
    local res="$1"
    [ ! -f "$RATES" ] && echo 1 && return
    local w="${res%x*}"
    local h="${res#*x}"
    [ -z "$w" ] && echo 1 && return
    [ -z "$h" ] && echo 1 && return
    local id=$(awk -F: -v w="$w" -v h="$h" '$2==w && $3==h && $5=="native" && $6=="1" {print $1; exit}' "$RATES" 2>/dev/null)
    [ -z "$id" ] && echo 1 || echo "$id"
}

oc_range() {
    local res="$1"
    local from="$2"
    local to="$3"
    local w="${res%x*}"
    local h="${res#*x}"
    [ ! -f "$RATES" ] && return
    if [ "$from" -lt "$to" ]; then
        awk -F: -v w="$w" -v h="$h" -v f="$from" -v t="$to" '$2==w && $3==h && $5=="overclock" && $7>f && $7<=t {print $7":"$1}' "$RATES" 2>/dev/null | sort -t: -k1 -n | cut -d: -f2
    else
        awk -F: -v w="$w" -v h="$h" -v f="$from" -v t="$to" '$2==w && $3==h && $5=="overclock" && $7<f && $7>=t {print $7":"$1}' "$RATES" 2>/dev/null | sort -t: -k1 -rn | cut -d: -f2
    fi
}

oc_up() {
    local res="$1"
    local to="$2"
    local w="${res%x*}"
    local h="${res#*x}"
    [ ! -f "$RATES" ] && return
    awk -F: -v w="$w" -v h="$h" -v t="$to" '$2==w && $3==h && $5=="overclock" && $7>0 && $7<=t {print $7":"$1}' "$RATES" 2>/dev/null | sort -t: -k1 -n | cut -d: -f2
}

oc_down() {
    local res="$1"
    local from="$2"
    local w="${res%x*}"
    local h="${res#*x}"
    [ ! -f "$RATES" ] && return
    awk -F: -v w="$w" -v h="$h" -v f="$from" '$2==w && $3==h && $5=="overclock" && $7>0 && $7<f {print $7":"$1}' "$RATES" 2>/dev/null | sort -t: -k1 -rn | cut -d: -f2
}

oc_step_down() {
    local res="$1"
    local from_ord="$2"
    local i
    for i in $(oc_down "$res" "$from_ord"); do
        usleep 50000 2>/dev/null || sleep 0.05
        service call SurfaceFlinger 1035 i32 "$i" >/dev/null 2>&1
    done
    usleep 50000 2>/dev/null || sleep 0.05
    local base=$(native_base "$res")
    is_num "$base" && service call SurfaceFlinger 1035 i32 "$base" >/dev/null 2>&1
}

has_apps() {
    [ ! -f "$APPS" ] && echo 0 && return
    local c=$(grep -c '=' "$APPS" 2>/dev/null)
    [ "$c" -gt 0 ] && echo 1 || echo 0
}

# 星驰切换链: 原生档直接切; 超频档经原生基准逐级上行 / 逐级下行回原生
apply() {
    local tid="$1"
    is_num "$tid" || return 1
    [ "$tid" = "$cur_id" ] && return 0

    widen_rates

    local tt=$(rate_type "$tid")
    local tr=$(rate_res "$tid")
    local to=$(rate_ord "$tid")
    local ct=$(rate_type "$cur_id")
    local cr=$(rate_res "$cur_id")
    local co=$(rate_ord "$cur_id")

    if [ -z "$tt" ] || [ "$tt" = "native" ] || [ "$tt" = "unknown" ]; then
        if [ "$ct" = "overclock" ] && [ -n "$cur_id" ]; then
            oc_step_down "$cr" "$co"
        fi
        usleep 50000 2>/dev/null || sleep 0.05
        service call SurfaceFlinger 1035 i32 "$tid" >/dev/null 2>&1
        cur_id="$tid"
        return 0
    fi

    if [ "$tt" = "overclock" ]; then
        local tn=$(native_base "$tr")
        if [ "$ct" = "overclock" ] && [ "$cr" = "$tr" ] && [ -n "$cur_id" ]; then
            local i
            for i in $(oc_range "$tr" "$co" "$to"); do
                usleep 50000 2>/dev/null || sleep 0.05
                service call SurfaceFlinger 1035 i32 "$i" >/dev/null 2>&1
            done
        else
            if [ "$ct" = "overclock" ] && [ -n "$cur_id" ]; then
                oc_step_down "$cr" "$co"
            fi
            usleep 50000 2>/dev/null || sleep 0.05
            service call SurfaceFlinger 1035 i32 "$tn" >/dev/null 2>&1
            local i
            for i in $(oc_up "$tr" "$to"); do
                usleep 50000 2>/dev/null || sleep 0.05
                service call SurfaceFlinger 1035 i32 "$i" >/dev/null 2>&1
            done
        fi
    fi

    cur_id="$tid"
    return 0
}

app_rate() {
    local pkg="$1"
    [ -z "$pkg" ] && return
    [ ! -f "$APPS" ] && return
    awk -F= -v p="$pkg" '$1==p {gsub(/[[:space:]]+/, "", $2); print $2; exit}' "$APPS" 2>/dev/null
}

focus_app() {
    dumpsys activity activities 2>/dev/null | grep "topResumedActivity=" | tail -n 1 | cut -d '{' -f2 | cut -d '/' -f1 | cut -d ' ' -f3
}

check_files() {
    local chg=0
    if [ -f "$CFG" ]; then
        local mt=$(stat -c %Y "$CFG" 2>/dev/null)
        if [ "$mt" != "$cfg_mt" ]; then
            load_cfg
            cfg_mt="$mt"
            chg=1
            cur_id=""
        fi
    fi
    if [ -f "$APPS" ]; then
        local mt=$(stat -c %Y "$APPS" 2>/dev/null)
        [ "$mt" != "$apps_mt" ] && { apps_mt="$mt"; chg=1; }
    fi
    if [ -f "$RATES" ]; then
        local mt=$(stat -c %Y "$RATES" 2>/dev/null)
        [ "$mt" != "$rates_mt" ] && { rates_mt="$mt"; chg=1; }
    fi
    return 0
}

on_wake() {
    if [ -z "$saved_id" ]; then
        cur_id=""
        last_app="__WAKEUP__"
        return
    fi

    local tt=$(rate_type "$saved_id")

    if [ -z "$tt" ] || [ "$tt" = "native" ]; then
        widen_rates
        service call SurfaceFlinger 1035 i32 "$saved_id" >/dev/null 2>&1
        cur_id="$saved_id"
        last_app="__WAKEUP__"
        return
    fi

    last_app="__WAKEUP__"

    widen_rates

    local tr=$(rate_res "$saved_id")
    local to=$(rate_ord "$saved_id")
    local base=$(native_base "$tr")

    usleep 50000 2>/dev/null || sleep 0.05
    service call SurfaceFlinger 1035 i32 "$base" >/dev/null 2>&1

    local i
    for i in $(oc_up "$tr" "$to"); do
        usleep 50000 2>/dev/null || sleep 0.05
        service call SurfaceFlinger 1035 i32 "$i" >/dev/null 2>&1
    done

    cur_id="$saved_id"
}

load_cfg
rclog "守护启动 (global=${saved_id:-无} appsw=$app_sw intv=$app_intv)"
wait_boot

[ -f "$CFG" ] && cfg_mt=$(stat -c %Y "$CFG" 2>/dev/null)
[ -f "$APPS" ] && apps_mt=$(stat -c %Y "$APPS" 2>/dev/null)
[ -f "$RATES" ] && rates_mt=$(stat -c %Y "$RATES" 2>/dev/null)

[ -n "$saved_id" ] && apply "$saved_id"

last_scr=$(screen_on)

while true; do
    scr=$(screen_on)

    [ "$scr" = "1" ] && [ "$last_scr" = "0" ] && on_wake
    last_scr="$scr"

    if [ "$scr" = "0" ]; then
        sleep 1
        continue
    fi

    check_files

    # 配置全空 (无全局锁定且按应用关闭/无规则): 退出释放
    if [ -z "$saved_id" ] && { [ "$app_sw" != "true" ] || [ "$(has_apps)" != "1" ]; }; then
        rclog "全局锁定未设置且按应用未启用, 守护退出"
        cleanup
    fi

    if [ "$app_sw" = "true" ] && [ "$(has_apps)" = "1" ]; then
        fapp=$(focus_app)
        if [ -n "$fapp" ] && [ "$fapp" != "$last_app" ]; then
            last_app="$fapp"
            ar=$(app_rate "$fapp")
            if [ -n "$ar" ]; then
                apply "$ar"
            elif [ -n "$saved_id" ]; then
                apply "$saved_id"
            fi
        fi
        sleep "$app_intv"
    else
        sleep 2
    fi
done
