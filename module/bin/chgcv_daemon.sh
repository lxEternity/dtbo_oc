#!/system/bin/sh
# 充电恒压守护进程 (纯用户态, 复刻电池工具包恒压语义)
# 接口: /proc/oplus-votable/FV_MAX + WIRED_FCC (oplus_chg_v2 框架调试接口, 无授权门控)
# 配置: /data/adb/dtbo_oc/chgcv.conf (webuictl.sh chg save 管理)
# 状态: /data/adb/dtbo_oc/chgcv.state (守护运行时快照, UI 轮询)

CONF=/data/adb/dtbo_oc/chgcv.conf
STATE=/data/adb/dtbo_oc/chgcv.state
LOGF=/data/adb/dtbo_oc/chgcv.log
PIDF=/data/adb/dtbo_oc/chgcv.pid
VT=/proc/oplus-votable
BATT=/sys/class/power_supply/battery

# ---------------- 基础工具 ----------------

cfg() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1; }

int() { # int <val> <default>
    case "$1" in ''|*[!0-9-]*) echo "$2" ;; *) echo "$1" ;; esac
}

log() {
    L=$(date '+%m-%d %H:%M:%S')
    echo "[$L] $*" >> "$LOGF"
    # 环形: 超 512KB 截半
    SZ=$(stat -c %s "$LOGF" 2>/dev/null || echo 0)
    [ "$SZ" -gt 524288 ] && tail -c 262144 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv -f "$LOGF.tmp" "$LOGF"
}

vt_force() { # vt_force <votable> <val> <0|1>
    [ -d "$VT/$1" ] || return 1
    echo "$2" > "$VT/$1/force_val" 2>/dev/null
    echo "$3" > "$VT/$1/force_active" 2>/dev/null
}

vt_relax() { # 解除全部运行时强制 (FV/FCC), 协议开关独立管理
    vt_force FV_MAX 0 0
    vt_force WIRED_FCC 0 0
    vt_force FV_MIN 0 0
}

# ---------------- 电池读数 ----------------

read_vbat() { # -> mV
    V=$(cat "$BATT/voltage_now" 2>/dev/null)
    case "$V" in ''|*[!0-9-]*) echo 0; return ;; esac
    [ "$V" -gt 1000000 ] && V=$((V / 1000))
    echo "$V"
}

read_ichg() { # -> mA (绝对值, 充电电流)
    I=$(cat "$BATT/current_now" 2>/dev/null)
    case "$I" in ''|*[!0-9-]*) echo 0; return ;; esac
    [ "$I" -lt 0 ] && I=$((0 - I))
    [ "$I" -gt 100000 ] && I=$((I / 1000))
    echo "$I"
}

read_temp() { # -> 0.1°C
    T=$(cat "$BATT/temp" 2>/dev/null)
    case "$T" in ''|*[!0-9-]*) echo 0 ;; *) echo "$T" ;; esac
}

read_soc() {
    S=$(cat "$BATT/capacity" 2>/dev/null)
    case "$S" in ''|*[!0-9]*) echo 0 ;; *) echo "$S" ;; esac
}

read_status() { cat "$BATT/status" 2>/dev/null; }

charging_now() {
    ST=$(read_status)
    IC=$(read_ichg)
    [ "$ST" = "Charging" ] && return 0
    [ "$ST" = "Full" ] && [ "$IC" -gt 30 ] && return 0
    return 1
}

# ---------------- 温控降额 ----------------
# 复刻电池工具包补丁曲线: 超限后逐度递增降额
THERM_STEPS="500 1000 1500 2000 4000"

thermal_cap_ma() { # -> 0=不限额
    T=$(read_temp)                        # 0.1°C
    MODE=$(cfg thermal_mode); MODE=${MODE:-comfort}
    # 夜间时间段内强制舒适模式
    if [ "$(int "$(cfg night_comfort)" 0)" = "1" ]; then
        NOW_MIN=$(( $(date '+%H' 2>/dev/null || echo 0) * 60 + $(date '+%M' 2>/dev/null || echo 0) ))
        NS=$(int "$(cfg night_start_min)" 1320)
        NE=$(int "$(cfg night_end_min)" 420)
        if [ "$NS" -le "$NE" ]; then
            [ "$NOW_MIN" -ge "$NS" ] && [ "$NOW_MIN" -lt "$NE" ] && MODE=comfort
        else
            { [ "$NOW_MIN" -ge "$NS" ] || [ "$NOW_MIN" -lt "$NE" ]; } && MODE=comfort
        fi
    fi
    if [ "$MODE" = "comfort" ]; then
        LIMIT=$(int "$(cfg comfort_temp_decic)" 420)   # 0.1°C
    else
        LIMIT=$(int "$(cfg batt_temp_high_decic)" 550)
    fi
    [ "$T" -le "$LIMIT" ] && { echo 0; return; }
    OVER=$(( (T - LIMIT + 9) / 10 ))                    # 超限整度数
    CAP=0
    IDX=1
    for S in $THERM_STEPS; do
        if [ "$OVER" -ge "$IDX" ]; then CAP=$((CAP + S)); fi
        IDX=$((IDX + 1))
    done
    # 积极温控 (大电流 >9A 时直接按 2 倍曲线降额)
    IC=$(read_ichg)
    if [ "$(int "$(cfg thermal_glide_cap)" 0)" = "1" ] && [ "$IC" -gt 9000 ]; then
        CAP=$((CAP * 2))
    fi
    echo "$CAP"
}

# ---------------- 协议开关 ----------------
# UFCS/PPS: NOT_ALLOW 投票器 1=禁用; SVOOC: VOOC_DISABLE/VOOC_NOT_ALLOW

apply_protocols() {
    [ "$(int "$(cfg ufcs)" 1)" = "1" ] && vt_force UFCS_NOT_ALLOW 0 0 || vt_force UFCS_NOT_ALLOW 1 1
    [ "$(int "$(cfg pps)" 1)" = "1" ] && vt_force PPS_NOT_ALLOW 0 0 || vt_force PPS_NOT_ALLOW 1 1
    if [ "$(int "$(cfg svooc)" 1)" = "1" ]; then
        vt_force VOOC_DISABLE 0 0
        vt_force VOOC_NOT_ALLOW 0 0
    else
        vt_force VOOC_DISABLE 1 1
        vt_force VOOC_NOT_ALLOW 1 1
    fi
    # 忽略旁路充电: 强制 buck 路径, 不走 PLC 旁路
    if [ "$(int "$(cfg ignore_plc)" 0)" = "1" ]; then
        vt_force PLC_FORCE_BUCK 1 1
    else
        vt_force PLC_FORCE_BUCK 0 0
    fi
}

relax_protocols() {
    vt_force UFCS_NOT_ALLOW 0 0
    vt_force PPS_NOT_ALLOW 0 0
    vt_force VOOC_DISABLE 0 0
    vt_force VOOC_NOT_ALLOW 0 0
    vt_force PLC_FORCE_BUCK 0 0
}

# 解除软件限流 (bcc_current, 单位 0.1A; cable_override / fast_max 大电流需要)
apply_bcc() {
    BCC=/sys/class/oplus_chg/battery/bcc_current
    [ -w "$BCC" ] || return 0
    FM=$(int "$(cfg fast_max)" 10900)
    WANT=$((FM / 100 + 20))   # mA -> 0.1A, 留裕量
    CUR=$(cat "$BCC" 2>/dev/null)
    [ "$CUR" = "$WANT" ] && return 0
    chmod 0644 "$BCC" 2>/dev/null
    echo "$WANT" > "$BCC" 2>/dev/null
}

# ---------------- 温度伪装 (可选, 内核支持 /proc/shell-temp 时) ----------------

apply_faket() {
    [ -e /proc/shell-temp ] || return 0
    if [ "$(int "$(cfg faket)" 0)" = "1" ]; then
        chmod 0644 /proc/shell-temp 2>/dev/null
        echo "0 36000" > /proc/shell-temp 2>/dev/null
        echo "1 36000" > /proc/shell-temp 2>/dev/null
        echo "2 36000" > /proc/shell-temp 2>/dev/null
        chmod 0000 /proc/shell-temp 2>/dev/null
    else
        chmod 0666 /proc/shell-temp 2>/dev/null
    fi
}

# ---------------- 状态输出 ----------------

emit_state() { # emit_state <stage> <extra: "fv=..\nfcc=..">
    {
        printf 'daemon=1\nstage=%s\nvbat=%s\nichg=%s\ntemp=%s\nsoc=%s\nstatus=%s\nts=%s\n' \
            "$1" "$(read_vbat)" "$(read_ichg)" "$(read_temp)" "$(read_soc)" "$(read_status)" \
            "$(date +%s)"
        [ -n "$2" ] && printf '%b\n' "$2"
    } > "$STATE.tmp"
    mv -f "$STATE.tmp" "$STATE"
}

# ---------------- 主循环 ----------------

main() {
    # 防重复启动
    if [ -f "$PIDF" ]; then
        OP=$(cat "$PIDF" 2>/dev/null)
        if [ -n "$OP" ] && [ "$OP" != "$$" ] && kill -0 "$OP" 2>/dev/null; then
            exit 0
        fi
    fi
    # 支持性检测: 必须有 votable 调试接口
    if [ ! -d "$VT/FV_MAX" ] && [ ! -d "$VT/WIRED_FCC" ]; then
        printf 'daemon=0\nerror=novotable\nts=%s\n' "$(date +%s)" > "$STATE"
        exit 1
    fi
    echo $$ > "$PIDF"

    log "守护启动 (pid $$)"
    apply_protocols
    apply_faket

    LAST_STAGE=""
    BOOT_CYCLES=0     # 插入后跟随周期 (curr_convergence: 让协商先完成)
    RESET_COUNT=0     # 充电器重协商次数 (max_ufcs_chg_reset_cc)
    LAST_RESET=0
    ANOM_CNT=0

    while [ -f "$PIDF" ] && [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ]; do
        INTERVAL=$(int "$(cfg loop_interval_ms)" 2000)
        [ "$INTERVAL" -lt 500 ] && INTERVAL=500

        if [ "$(int "$(cfg enabled)" 1)" != "1" ]; then
            vt_relax
            if [ "$LAST_STAGE" != "off" ]; then
                log "恒压关闭, 使用官方充电曲线"
                LAST_STAGE="off"
            fi
            emit_state off
            sleep 2
            continue
        fi

        if ! charging_now; then
            vt_relax
            if [ "$LAST_STAGE" != "idle" ] && [ "$LAST_STAGE" != "" ]; then
                log "充电停止, 解除运行时强制"
                LAST_STAGE="idle"
            fi
            emit_state idle
            BOOT_CYCLES=0
            sleep 2
            continue
        fi

        # 充电中: 启动前几个周期只跟随 (curr_convergence, 防协商异常)
        if [ "$LAST_STAGE" != "chg" ] && [ "$LAST_STAGE" != "cv" ] && [ "$LAST_STAGE" != "tail" ]; then
            BOOT_CYCLES=3
        fi
        if [ "$BOOT_CYCLES" -gt 0 ]; then
            BOOT_CYCLES=$((BOOT_CYCLES - 1))
            emit_state boot
            sleep 1
            continue
        fi

        VBAT=$(read_vbat)
        SOC=$(read_soc)
        CV=$(int "$(cfg cv_vol_mv)" 4565)
        TCV=$(int "$(cfg tc_vol_thr_mv)" 4500)
        TCS=$(int "$(cfg tc_thr_soc)" 98)
        TCFV=$(int "$(cfg tc_vol_full_mv)" 4485)
        TCFM=$(int "$(cfg tc_full_ma)" 400)
        CVM=$(int "$(cfg cv_max_ma)" 5000)
        FULLMV=$(int "$(cfg batt_full_thr_mv)" 4470)
        FM=$(int "$(cfg fast_max)" 10900)
        PM=$(int "$(cfg pps_max)" 5000)

        # 协议电流上限: UFCS/SVOOC 用 fast_max, PPS 用 pps_max, 取小
        PFM=$FM
        [ "$PM" -lt "$PFM" ] && PFM=$PM

        # 阶段决策
        if [ "$SOC" -ge "$TCS" ] && [ "$VBAT" -ge "$TCV" ]; then
            STAGE=tail; FV=$TCFV; FCC=$TCFM
        elif [ "$VBAT" -ge "$CV" ]; then
            STAGE=cv; FV=$CV; FCC=$CVM
        else
            STAGE=chg; FV=$FULLMV; FCC=$PFM
        fi

        # 温控降额
        TCAP=$(thermal_cap_ma)
        if [ "$TCAP" -gt 0 ] && [ "$TCAP" -lt "$FCC" ]; then
            FCC=$TCAP
            STAGE="${STAGE}/th"
        fi
        [ "$FCC" -lt 200 ] && FCC=200

        # 应用: FV_MAX 限电压, WIRED_FCC 限电流
        vt_force FV_MAX "$FV" 1
        vt_force WIRED_FCC "$FCC" 1
        # cable_override: 解除 bcc 软件限流
        [ "$(int "$(cfg cable_override)" 0)" = "1" ] && apply_bcc

        # 异常检测与充电器重协商 (电压超 FV 过多持续 2 周期; 0=关闭)
        RESET_MAX=$(int "$(cfg max_ufcs_chg_reset_cc)" 2)
        RESET_DELAY=$(int "$(cfg ufcs_reset_delay)" 180)
        if [ "$RESET_MAX" -gt 0 ] && [ "$RESET_COUNT" -lt "$RESET_MAX" ]; then
            NOW=$(date +%s)
            if [ $(( NOW - LAST_RESET )) -ge "$RESET_DELAY" ]; then
                ANOM=0
                [ "$VBAT" -gt $(( FV + 60 )) ] && ANOM=1
                ICUR=$(read_ichg)
                if [ "$STAGE" = "cv" ] && [ "$FCC" -gt 500 ] && [ "$ICUR" -gt $(( FCC * 2 )) ]; then
                    ANOM=1
                fi
                if [ "$ANOM" = "1" ]; then
                    ANOM_CNT=$((ANOM_CNT + 1))
                    if [ "$ANOM_CNT" -ge 2 ]; then
                        ANOM_CNT=0
                        RESET_COUNT=$((RESET_COUNT + 1))
                        LAST_RESET=$NOW
                        log "充电异常 (vbat=${VBAT}mV fv=${FV}mV ichg=${ICUR}mA), 第 ${RESET_COUNT}/${RESET_MAX} 次重协商充电器"
                        # 瞬间禁用 UFCS/PPS 促使适配器重新协商
                        vt_force UFCS_NOT_ALLOW 1 1
                        vt_force PPS_NOT_ALLOW 1 1
                        sleep 2
                        apply_protocols
                        BOOT_CYCLES=3
                    fi
                else
                    ANOM_CNT=0
                fi
            fi
        fi

        if [ "$STAGE" != "$LAST_STAGE" ]; then
            log "阶段 $LAST_STAGE -> $STAGE (vbat=${VBAT}mV soc=${SOC}% fcc=${FCC}mA fv=${FV}mV)"
            LAST_STAGE=$STAGE
        fi
        emit_state "$STAGE" "fv=$FV\nfcc=$FCC"
        # ms 级 sleep 分片 (busybox 支持)
        SLEEP_S=$((INTERVAL / 1000))
        SLEEP_MS=$((INTERVAL % 1000))
        [ "$SLEEP_S" -gt 0 ] && sleep "$SLEEP_S"
        [ "$SLEEP_MS" -gt 0 ] && sleep 0.2 2>/dev/null
    done

    log "守护退出"
    rm -f "$PIDF"
}

main "$@"
