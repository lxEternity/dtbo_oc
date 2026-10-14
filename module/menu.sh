#!/system/bin/sh
# usage: adb shell su -c "sh /data/adb/modules/dtbo_oc/menu.sh"
# fallback to numeric input without getevent: 1=up 2=down 3=confirm
MODDIR=${0%/*}
[ -d "$MODDIR/arm64" ] || MODDIR=/data/adb/modules/dtbo_oc
TOOL="$MODDIR/arm64/dtbo_oc"
DTC="$MODDIR/arm64/dtc"
DATA_DIR=/data/adb/dtbo_oc
CONFIG="$DATA_DIR/config"
STOCK="$DATA_DIR/dtbo_stock.img"
WORK="$DATA_DIR/work"

chmod 755 "$TOOL" "$DTC" 2>/dev/null
mkdir -p "$DATA_DIR" "$WORK"

if [ "$(id -u)" != "0" ]; then
    echo "请以 root 运行: su -c sh $0"
    exit 1
fi
if [ ! -f "$STOCK" ]; then
    echo "[错误] 未找到原始镜像 $STOCK"
    echo "       请先安装模块并重启一次 (开机自动生成)"
    exit 1
fi

IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
CHOICES=""
case "$DEVICE" in
    ace2pro)   CHOICES="144 165 185" ;;
    op13t)     CHOICES="144" ;;
    op15t)     CHOICES="185 195" ;;
    ace5)      CHOICES="144" ;;
    ace3)      CHOICES="144" ;;
    ace3pro)   CHOICES="144" ;;
    op12)      CHOICES="144" ;;
    op13)      CHOICES="144" ;;
    op15|ace6) CHOICES="185 195" ;;
    gt8)       CHOICES="144 165 185 195" ;;
    gt7p)      CHOICES="130 142 144" ;;
    gt7s)      CHOICES="144 165 185" ;;
    gt8p)      CHOICES="165 185" ;;
    ace6t)     CHOICES="185" ;;
    ace6u)     CHOICES="185 195" ;;
    ace5p)     CHOICES="144" ;;
    op11)      CHOICES="" ;;
    *) echo "[错误] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac

HZ_CHOICE=""; BATTERY=""
[ -f "$CONFIG" ] && . "$CONFIG"
[ -z "$HZ_CHOICE" ] && HZ_CHOICE=144
[ -z "$BATTERY" ] && BATTERY=0

# ---------------- key input: vol+ = up, vol- = down, power = select ----------------
HAVE_KEYS=0
[ -x "$TOOL" ] && HAVE_KEYS=1
HAVE_GETEVENT=0
command -v getevent >/dev/null 2>&1 && HAVE_GETEVENT=1
if [ "$HAVE_KEYS" = "1" ] || [ "$HAVE_GETEVENT" = "1" ]; then
    FOOT="  [音量+/音量-] 切换   [电源键] 确认"
    TIPS=" 操作: [音量+/音量-] 切换选项, [电源键] 确认"
else
    FOOT="  [1]上  [2]下  [3]确认"
    TIPS=" 操作: [1]上 [2]下 [3]确认 (本机不支持按键监听, 数字键模式)"
fi

wake_screen() { command -v input >/dev/null 2>&1 && input keyevent 224 2>/dev/null; return 0; }

wait_key() {
    if [ "$HAVE_KEYS" = "1" ]; then
        K=$("$TOOL" keys 2>/dev/null) && { [ "$K" = "select" ] && wake_screen; echo "$K"; return 0; }
        HAVE_KEYS=0
    fi
    if [ "$HAVE_GETEVENT" = "1" ]; then
        SPIN=0
        while [ "$SPIN" -lt 50 ]; do
            EV=$(getevent -qlc 1 2>/dev/null | head -n 1)
            if [ -z "$EV" ]; then SPIN=$((SPIN+1)); continue; fi
            SPIN=0
            case "$EV" in
                *KEY_VOLUMEUP*DOWN*)   echo up; return ;;
                *KEY_VOLUMEDOWN*DOWN*) echo down; return ;;
                *KEY_POWER*DOWN*)      wake_screen; echo select; return ;;
            esac
        done
    fi
    printf "[1]上 [2]下 [3]确认 > " >&2
    if ! read K; then K=3; fi
    case "$K" in
        1) echo up ;;
        2) echo down ;;
        *) wake_screen; echo select ;;
    esac
}

# choose TITLE "opt1|opt2|..." [init_index] -> SEL / SEL_TEXT
choose() {
    TITLE="$1"; OPTSTR="$2"; SEL="${3:-0}"
    OLDIFS="$IFS"; IFS='|'; set -- $OPTSTR; IFS="$OLDIFS"
    N=$#
    if [ "$N" -lt 1 ]; then SEL=0; SEL_TEXT=""; return; fi
    case "$SEL" in ''|*[!0-9]*) SEL=0 ;; esac
    [ "$SEL" -ge "$N" ] && SEL=0
    if [ -t 1 ]; then
        printf "\n%s\n" "$TITLE"
        i=0
        for o in "$@"; do
            if [ "$i" = "$SEL" ]; then printf "  => %s\n" "$o"; else printf "     %s\n" "$o"; fi
            i=$((i+1))
        done
        printf "%s\n" "$FOOT"
        while true; do
            K=$(wait_key)
            case "$K" in
                up)   SEL=$(( (SEL - 1 + N) % N )) ;;
                down) SEL=$(( (SEL + 1) % N )) ;;
                *)    break ;;
            esac
            printf "\033[%dA" $((N + 1))
            i=0
            for o in "$@"; do
                if [ "$i" = "$SEL" ]; then printf "  => %s\n" "$o"; else printf "     %s\n" "$o"; fi
                i=$((i+1))
            done
            printf "%s\n" "$FOOT"
        done
    else
        printf "\n%s\n" "$TITLE"
        i=0
        for o in "$@"; do
            printf "  %d) %s\n" $((i+1)) "$o"
            i=$((i+1))
        done
        while true; do
            K=$(wait_key)
            case "$K" in
                up)   SEL=$(( (SEL - 1 + N) % N )) ;;
                down) SEL=$(( (SEL + 1) % N )) ;;
                *)    break ;;
            esac
            CUR=""; i=0
            for o in "$@"; do [ "$i" = "$SEL" ] && CUR="$o"; i=$((i+1)); done
            printf "  当前: %s\n" "$CUR"
        done
    fi
    SEL_TEXT=""
    i=0
    for o in "$@"; do [ "$i" = "$SEL" ] && SEL_TEXT="$o"; i=$((i+1)); done
    printf "  已选择: %s\n" "$SEL_TEXT"
}

echo "=============================================="
echo " DTBO 刷新率超频 v2 — 配置菜单"
echo " 机型: $DEVNAME ($DEVICE)"
echo "$TIPS"
echo "=============================================="

if [ -n "$CHOICES" ] && [ "$OC_OK" = "1" ]; then
    OPTSTR=""; INIT=0; i=0
    for c in $CHOICES; do
        OPTSTR="${OPTSTR:+$OPTSTR|}${c}Hz"
        [ "$c" = "$HZ_CHOICE" ] && INIT=$i
        i=$((i+1))
    done
    OPTSTR="$OPTSTR|不超频 (仅电池/充电方案)"
    [ "$HZ_CHOICE" = "0" ] && INIT=$i
    choose "选择超频目标档位 (仅生成 <= 所选的档位):" "$OPTSTR" "$INIT"
    HZ_CHOICE=0
    i=0
    for c in $CHOICES; do [ "$i" = "$SEL" ] && HZ_CHOICE="$c"; i=$((i+1)); done
else
    echo " 本机型不支持刷新率超频 (仅电池/充电方案)"
    HZ_CHOICE=0
fi

if [ "$DEVICE" = "gt7p" ]; then
    GT_INIT=0
    [ "$BATTERY" = "6" ] && GT_INIT=1
    choose "电池/充电方案:" "保持原版电池|GT7P 竞速版解容 (满充4.55V/关机2.85V/解除充电限流)" "$GT_INIT"
    BATTERY=$([ "$SEL" = "1" ] && echo 6 || echo 0)
else
    BAT_MENU="保持原版电池|解除充电限流|解除充电限流 + 关机电压2800 (电池解容)|原版电池 + 关机电压2800 (电池解容)"
    BAT_MODES="0 1 2 5"
    if [ "$BATT_OK" = "1" ]; then
        BAT_MENU="$BAT_MENU|6100mAh 魔改电池 (关机 3.0V / 1% 3.05V / 满充 4.54V)|6100mAh 魔改电池 + 解除充电限流"
        BAT_MODES="$BAT_MODES 3 4"
    fi
    INIT=0; i=0
    for m in $BAT_MODES; do
        [ "$m" = "$BATTERY" ] && INIT=$i
        i=$((i+1))
    done
    choose "电池/充电方案:" "$BAT_MENU" "$INIT"
    i=0
    for m in $BAT_MODES; do
        [ "$i" = "$SEL" ] && BATTERY=$m
        i=$((i+1))
    done
fi
if [ "$BATT_OK" = "1" ] && { [ "$BATTERY" = "3" ] || [ "$BATTERY" = "4" ]; }; then
    echo "  !! 非魔改电池勿选, 可能导致过充/鼓包 !!"
    choose "确认: 设备是否已更换 6100mAh 魔改电池?" "否, 改回原版电池|是, 确认已更换" 0
    [ "$SEL" = "0" ] && BATTERY=0
fi

echo ""
echo "=============================================="
echo " 方案确认"
echo "  机型: $DEVNAME ($DEVICE)"
if [ "$HZ_CHOICE" != "0" ]; then
    echo "  档位: ${HZ_CHOICE}Hz"
else
    echo "  档位: 不超频"
fi
case "$BATTERY" in
    0) echo "  电池: 原版" ;;
    1) echo "  电池: 解除充电限流" ;;
    2) echo "  电池: 解除充电限流 + 关机电压2800 (电池解容)" ;;
    3) echo "  电池: 6100mAh 魔改电池 (关机 3.0V / 1% 3.05V / 满充 4.54V)" ;;
    4) echo "  电池: 6100mAh 魔改电池 + 解除充电限流 (关机 3.0V / 1% 3.05V / 满充 4.54V)" ;;
    5) echo "  电池: 原版电池 + 关机电压2800 (电池解容)" ;;
    6) echo "  电池: GT7P 竞速版解容 (满充 4.55V / 关机 2.85V / 解除充电限流)" ;;
esac
echo "=============================================="
choose "应用方式:" "稍后 (下次开机自动处理)|立即刷入 (重启后生效)" 0
APPLY=$SEL

if [ -f "$CONFIG" ]; then
    sed -i "s/^HZ_CHOICE=.*/HZ_CHOICE=$HZ_CHOICE/;s/^BATTERY=.*/BATTERY=$BATTERY/" "$CONFIG" 2>/dev/null || {
        cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATTERY=$BATTERY
EOF
    }
else
    cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATTERY=$BATTERY
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
fi

echo ""
echo "配置已保存: HZ_CHOICE=$HZ_CHOICE BATTERY=$BATTERY"
echo ""
if [ "$APPLY" = "1" ]; then
    echo "正在执行 service.sh ..."
    sh "$MODDIR/service.sh"
    echo "完成。重启后生效。"
else
    echo "下次开机时自动应用"
fi
