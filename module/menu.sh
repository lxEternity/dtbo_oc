#!/system/bin/sh
# DTBO 刷新率超频 v2 — 交互菜单 (音量上/下切换选项, 电源键确认)
# 用法: adb shell su -c "sh /data/adb/modules/dtbo_oc/menu.sh"
# 无 getevent 的环境下自动退回数字输入: 1=上 2=下 3=确认
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

# ---------------- 机型识别 ----------------
IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
# 菜单档位选项 (仅可超频机型)
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
    op11)      CHOICES="" ;;   # 一加11 不可超频
    gt7) echo "[错误] 真我 GT7 Pro (标准版) 暂未适配"; exit 1 ;;
    *) echo "[错误] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac

# 读取当前配置
HZ_CHOICE=""; BATTERY=""
[ -f "$CONFIG" ] && . "$CONFIG"
[ -z "$HZ_CHOICE" ] && HZ_CHOICE=144
[ -z "$BATTERY" ] && BATTERY=0

# ---------------- 按键输入: 音量上=up 音量下=down 电源键=select ----------------
# 优先 dtbo_oc keys (EVIOCGRAB 内核级拦截, 电源键事件被独占消费, 不会触发系统息屏)
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

# 兜底亮屏: 电源键被拦截后系统不会自动亮屏, 确认时主动点亮
wake_screen() { command -v input >/dev/null 2>&1 && input keyevent 224 2>/dev/null; return 0; }

wait_key() {
    if [ "$HAVE_KEYS" = "1" ]; then
        K=$("$TOOL" keys 2>/dev/null) && { [ "$K" = "select" ] && wake_screen; echo "$K"; return 0; }
        HAVE_KEYS=0   # 失败 (无设备/权限), 本次会话降级
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
    if ! read K; then K=3; fi   # EOF 视为确认, 防止死循环
    case "$K" in
        1) echo up ;;
        2) echo down ;;
        *) wake_screen; echo select ;;
    esac
}

# choose 标题 "选项1|选项2|..." [初始索引]
# 结果: SEL=索引(0起), SEL_TEXT=选中文本
choose() {
    TITLE="$1"; OPTSTR="$2"; SEL="${3:-0}"
    OLDIFS="$IFS"; IFS='|'; set -- $OPTSTR; IFS="$OLDIFS"
    N=$#
    if [ "$N" -lt 1 ]; then SEL=0; SEL_TEXT=""; return; fi
    case "$SEL" in ''|*[!0-9]*) SEL=0 ;; esac
    [ "$SEL" -ge "$N" ] && SEL=0
    if [ -t 1 ]; then
        # 终端模式: 高亮光标 + 局部刷新
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
        # 非终端: 逐行追加
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

# ---------------- 档位选择 (仅可超频机型) ----------------
if [ -n "$CHOICES" ] && [ "$OC_OK" = "1" ]; then
    OPTSTR=""; INIT=0; i=0
    for c in $CHOICES; do
        OPTSTR="${OPTSTR:+$OPTSTR|}${c}Hz"
        [ "$c" = "$HZ_CHOICE" ] && INIT=$i
        i=$((i+1))
    done
    choose "选择超频目标档位 (仅生成 <= 所选的档位):" "$OPTSTR" "$INIT"
    i=0
    for c in $CHOICES; do [ "$i" = "$SEL" ] && HZ_CHOICE="$c"; i=$((i+1)); done
else
    echo " 本机型不支持刷新率超频 (仅电池/充电方案)"
    HZ_CHOICE=0
fi

# ---------------- 电池选择 ----------------
# BATTERY: 0=原版 1=解除限流 2=解除限流+关机2800(电池解容)
#          3=6100魔改 4=6100魔改+解除限流 5=原版+关机2800(电池解容)
#          6=GT7P竞速版解容 (满充4.55V/关机2.85V/解除限流, 仅 gt7p)
# 3/4/5 仅魔改电池机型 (BATT_OK=1)
if [ "$DEVICE" = "gt7p" ]; then
    GT_INIT=0
    [ "$BATTERY" = "6" ] && GT_INIT=1
    choose "电池/充电方案:" "保持原版电池|GT7P 竞速版解容 (满充4.55V/关机2.85V/解除充电限流)" "$GT_INIT"
    BATTERY=$([ "$SEL" = "1" ] && echo 6 || echo 0)
else
    BAT_MENU="保持原版电池|解除充电限流|解除充电限流 + 关机电压2800 (电池解容)"
    [ "$BATT_OK" = "1" ] && BAT_MENU="$BAT_MENU|6100mAh 魔改电池 (关机 3.0V / 1% 3.05V / 满充 4.54V)|6100mAh 魔改电池 + 解除充电限流|原版电池 + 关机电压2800 (电池解容)"
    choose "电池/充电方案:" "$BAT_MENU" "$BATTERY"
    BATTERY=$SEL
fi
if [ "$BATT_OK" = "1" ] && { [ "$BATTERY" = "3" ] || [ "$BATTERY" = "4" ]; }; then
    echo "  !! 非魔改电池勿选, 可能导致过充/鼓包 !!"
    choose "确认: 设备是否已更换 6100mAh 魔改电池?" "否, 改回原版电池|是, 确认已更换" 0
    [ "$SEL" = "0" ] && BATTERY=0
fi

# ---------------- 方案确认 ----------------
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

# ---------------- 写回配置 ----------------
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
