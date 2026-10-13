#!/system/bin/sh
# Magisk 安装器脚本 — DTBO 刷新率超频 v2 (多机型, 音量键交互选择)
SKIPUNZIP=0

# 检查架构
ARCH64=$(getprop ro.product.cpu.abi)
if [ "$ARCH64" != "arm64-v8a" ]; then
    ui_print "! 本模块仅支持 arm64 设备 (当前: $ARCH64)"
    abort
fi

# 解锁提示 (仅警告, 不阻止安装)
LOCKED=$(getprop ro.boot.flash.locked)
VBS=$(getprop ro.boot.verifiedbootstate)
if [ "$LOCKED" = "1" ] || [ "$VBS" = "green" ]; then
    ui_print "*********************************************************"
    ui_print " !! 警告: Bootloader 处于锁定/校验状态 !!"
    ui_print " !! 未解锁 BL 刷入修改后的 DTBO 会导致无法开机(变砖) !!"
    ui_print " !! 请确认已解锁 Bootloader 后再使用本模块 !!"
    ui_print "*********************************************************"
fi

ui_print "*******************************"
ui_print " DTBO 刷新率超频 v2 (多机型)"
ui_print "*******************************"
ui_print "- 安装二进制: dtbo_oc + dtc (静态 arm64)"
chmod 755 "$MODPATH/arm64/dtbo_oc" "$MODPATH/arm64/dtc" \
    "$MODPATH/service.sh" "$MODPATH/menu.sh" 2>/dev/null

TOOL="$MODPATH/arm64/dtbo_oc"
DTC="$MODPATH/arm64/dtc"
DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
STOCK="$DATA_DIR/dtbo_stock.img"
CONFIG="$DATA_DIR/config"
mkdir -p "$DATA_DIR" "$WORK"

# ---------------- 定位 dtbo 分区并准备原始镜像 ----------------
SLOT=$(getprop ro.boot.slot_suffix)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        if [ -e "$d/$n" ]; then DTBO="$d/$n"; break 2; fi
    done
done
if [ -z "$DTBO" ]; then
    ui_print "! 未找到 dtbo 分区, 模块仍将安装, 开机后由 service.sh 重试"
else
    ui_print "- dtbo 分区: $DTBO"
    if [ ! -f "$STOCK" ]; then
        # 原始镜像优先级: 已有备份 > v1.0.0 的 /sdcard/dtbo_backup.img > 当前分区
        if [ -f /sdcard/dtbo_backup.img ]; then
            cp /sdcard/dtbo_backup.img "$STOCK"
            ui_print "- 已采用 /sdcard/dtbo_backup.img 作为原始镜像基准"
        else
            dd if="$DTBO" of="$STOCK" 2>/dev/null
            ui_print "- 已备份当前 dtbo 作为原始镜像基准"
        fi
    else
        ui_print "- 沿用已有原始镜像基准 (dtbo_stock.img)"
    fi
fi

# ---------------- 机型识别 ----------------
DEVICE=""; DEVNAME=""
if [ -f "$STOCK" ]; then
    IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
    DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
    DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
    BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
    OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
fi
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
# 菜单档位选项 (仅可超频机型)
CHOICES=""
case "$DEVICE" in
    ace2pro)   DEF_HZ=144; CHOICES="144/165/185" ;;
    op13t)     DEF_HZ=144; CHOICES="144" ;;
    op15t)     DEF_HZ=185; CHOICES="185/195" ;;
    ace5)      DEF_HZ=144; CHOICES="144" ;;
    ace3)      DEF_HZ=144; CHOICES="144" ;;
    ace3pro)   DEF_HZ=144; CHOICES="144" ;;
    op12)      DEF_HZ=144; CHOICES="144" ;;
    op13)      DEF_HZ=144; CHOICES="144" ;;
    op15|ace6) DEF_HZ=185; CHOICES="185/195" ;;
    gt8)       DEF_HZ=185; CHOICES="144/165/185/195" ;;
    gt7p)      DEF_HZ=144; CHOICES="130/142/144" ;;
    gt7s)      DEF_HZ=185; CHOICES="144/165/185" ;;
    gt8p)      DEF_HZ=185; CHOICES="165/185" ;;
    ace6t)     DEF_HZ=185; CHOICES="185" ;;
    op11)      DEF_HZ=0;   CHOICES="" ;;   # 一加11 不可超频
    *)
        ui_print "! 无法识别机型 (DEVICE=$DEVICE)"
        ui_print "! 模块仍将安装, 但开机 service.sh 会再次校验并中止"
        DEF_HZ=144; CHOICES=""; BATT_OK=0; DEVNAME="未知机型"
        ;;
esac
[ -n "$DEVNAME" ] && ui_print "- 机型识别: $DEVNAME ($DEVICE)"
if [ "$DEVICE" = "op11" ]; then
    ui_print "- 本机型不支持刷新率超频, 仅电池/充电方案可用"
fi

# ---------------- 按键输入: 音量上=up 音量下=down 电源键=select ----------------
# 优先 dtbo_oc keys (EVIOCGRAB 内核级拦截, 电源键事件被独占消费, 不会触发系统息屏)
HAVE_KEYS=0
[ -x "$TOOL" ] && HAVE_KEYS=1
HAVE_GETEVENT=0
command -v getevent >/dev/null 2>&1 && HAVE_GETEVENT=1

# 兜底亮屏: 电源键被拦截后系统不会自动亮屏, 确认时主动点亮
wake_screen() { command -v input >/dev/null 2>&1 && input keyevent 224 2>/dev/null; return 0; }

# 阻塞读取一次有效按键; keys/getevent 均不可用时返回 1 (调用方保持默认)
wait_key() {
    if [ "$HAVE_KEYS" = "1" ]; then
        K=$("$TOOL" keys 2>/dev/null) && { [ "$K" = "select" ] && wake_screen; echo "$K"; return 0; }
        HAVE_KEYS=0   # 失败 (无设备/权限), 本次会话降级
    fi
    while true; do
        EV=$(getevent -qlc 1 2>/dev/null | head -n 1)
        [ -z "$EV" ] && return 1
        case "$EV" in
            *KEY_VOLUMEUP*DOWN*)   echo up; return 0 ;;
            *KEY_VOLUMEDOWN*DOWN*) echo down; return 0 ;;
            *KEY_POWER*DOWN*)      wake_screen; echo select; return 0 ;;
        esac
    done
}

# ui_choose 标题 "选项1|选项2|..." [初始索引] -> SEL / SEL_TEXT
ui_choose() {
    TITLE="$1"; OPTSTR="$2"; SEL="${3:-0}"
    OLDIFS="$IFS"; IFS='|'; set -- $OPTSTR; IFS="$OLDIFS"
    N=$#
    if [ "$N" -lt 1 ]; then SEL=0; SEL_TEXT=""; return; fi
    case "$SEL" in ''|*[!0-9]*) SEL=0 ;; esac
    [ "$SEL" -ge "$N" ] && SEL=0
    ui_print " "
    ui_print "$TITLE"
    i=0
    for o in "$@"; do
        if [ "$i" = "$SEL" ]; then ui_print "  => $o"; else ui_print "     $o"; fi
        i=$((i+1))
    done
    ui_print "  [音量+/音量-] 切换   [电源键] 确认"
    while true; do
        if ! K=$(wait_key); then break; fi
        case "$K" in
            up)   SEL=$(( (SEL - 1 + N) % N )) ;;
            down) SEL=$(( (SEL + 1) % N )) ;;
            *)    break ;;
        esac
        CUR=""
        i=0
        for o in "$@"; do [ "$i" = "$SEL" ] && CUR="$o"; i=$((i+1)); done
        ui_print "  => $CUR"
    done
    SEL_TEXT=""
    i=0
    for o in "$@"; do [ "$i" = "$SEL" ] && SEL_TEXT="$o"; i=$((i+1)); done
    ui_print "  已选择: $SEL_TEXT"
}

# ---------------- 选择方案 ----------------
# 优先级: /sdcard/dtbo_oc.conf 预设 > 音量键交互(默认高亮旧配置) > 默认值
HZ_CHOICE=""; BATTERY=""
PRESET=0
if [ -f /sdcard/dtbo_oc.conf ]; then
    . /sdcard/dtbo_oc.conf
    PRESET=1
    ui_print "- 检测到 /sdcard/dtbo_oc.conf 预设, 跳过按键选择"
fi
# 旧配置作为按键选择的默认高亮项
if [ -z "$HZ_CHOICE" ] && [ -f "$CONFIG" ]; then
    OLD_HZ=$(grep '^HZ_CHOICE=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -n "$OLD_HZ" ] && HZ_CHOICE="$OLD_HZ"
fi
if [ -z "$BATTERY" ] && [ -f "$CONFIG" ]; then
    OLD_BATT=$(grep '^BATTERY=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -n "$OLD_BATT" ] && BATTERY="$OLD_BATT"
fi

if [ "$PRESET" != "1" ] && { [ "$HAVE_KEYS" = "1" ] || [ "$HAVE_GETEVENT" = "1" ]; }; then
    ui_print " "
    ui_print "- 请用 [音量+/音量-] 切换选项, [电源键] 确认"
    ui_print "  (按键事件已被拦截: 电源键确认不会息屏, 音量键不会弹音量条)"
    # 档位选择 (仅可超频机型)
    if [ -n "$CHOICES" ] && [ "$OC_OK" = "1" ]; then
        OPTSTR=""; INIT=0; i=0
        for c in $(echo "$CHOICES" | tr '/' ' '); do
            OPTSTR="${OPTSTR:+$OPTSTR|}${c}Hz"
            [ "$c" = "$HZ_CHOICE" ] && INIT=$i
            i=$((i+1))
        done
        ui_choose "选择超频目标档位 (仅生成 <= 所选的档位):" "$OPTSTR" "$INIT"
        i=0
        for c in $(echo "$CHOICES" | tr '/' ' '); do
            [ "$i" = "$SEL" ] && HZ_CHOICE="$c"
            i=$((i+1))
        done
    else
        ui_print "- 本机型不支持刷新率超频, 跳过档位选择"
        HZ_CHOICE=0
    fi
    # 电池选择
    if [ "$DEVICE" = "gt7p" ]; then
        GT_INIT=0
        [ "${BATTERY:-0}" = "6" ] && GT_INIT=1
        ui_choose "电池/充电方案:" "保持原版电池|GT7P 竞速版解容 (满充4.55V/关机2.85V/解除充电限流)" "$GT_INIT"
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
            [ "$m" = "${BATTERY:-0}" ] && INIT=$i
            i=$((i+1))
        done
        ui_choose "电池/充电方案:" "$BAT_MENU" "$INIT"
        i=0
        for m in $BAT_MODES; do
            [ "$i" = "$SEL" ] && BATTERY=$m
            i=$((i+1))
        done
    fi
    if [ "$BATT_OK" = "1" ] && { [ "$BATTERY" = "3" ] || [ "$BATTERY" = "4" ]; }; then
        ui_print "  !! 非魔改电池勿选, 可能导致过充/鼓包 !!"
        ui_choose "确认: 设备是否已更换 6100mAh 魔改电池?" "否, 改回原版电池|是, 确认已更换" 0
        [ "$SEL" = "0" ] && { BATTERY=0; ui_print "- 已改回原版电池"; }
    fi
elif [ "$PRESET" != "1" ]; then
    ui_print "- 当前环境不支持按键交互 (无输入设备/权限), 使用默认/已有配置"
    if [ -z "$CHOICES" ] || [ "$OC_OK" != "1" ]; then HZ_CHOICE=0; fi
fi

# 校验档位
if [ "$OC_OK" = "1" ] && [ -n "$CHOICES" ]; then
    VALID=0
    for c in $(echo "$CHOICES" | tr '/' ' '); do [ "$HZ_CHOICE" = "$c" ] && VALID=1; done
    if [ "$VALID" != "1" ]; then
        HZ_CHOICE="$DEF_HZ"
        ui_print "- 档位未指定/不适用, 使用默认 ${DEF_HZ}Hz"
    fi
else
    HZ_CHOICE=0
fi

# 校验电池选项
# BATTERY: 0=原版 1=解除限流 2=解除限流+关机2800 3=6100魔改 4=魔改+解除限流 5=原版+关机2800 6=GT7P解容
[ -z "$BATTERY" ] && BATTERY=0
case "$BATTERY" in 0|1|2|3|4|5|6) ;; *) BATTERY=0 ;; esac
if [ "$BATT_OK" != "1" ]; then
    case "$BATTERY" in
        3|4)
            ui_print "- 魔改电池选项仅 ACE2Pro/一加11/一加12 支持, 已重置为原版"
            BATTERY=0
            ;;
    esac
fi
if [ "$DEVICE" = "gt7p" ]; then
    case "$BATTERY" in
        1|2|3|4|5)
            ui_print "- gt7p 请使用 GT7P 专属解容选项, 其他电池选项已重置为原版"
            BATTERY=0
            ;;
    esac
elif [ "$BATTERY" = "6" ]; then
    ui_print "- 电池选项 6 仅 GT7 Pro 竞速版支持, 已重置为原版"
    BATTERY=0
fi
case "$BATTERY" in
    3|4)
        ui_print "*********************************************************"
        ui_print " !! 已选择 6100mAh 魔改电池选项 (BATTERY=$BATTERY) !!"
        ui_print " !! 含: 关机电压 3.0V / 1% 3.05V / 满充 4.54V !!"
        ui_print " !! 仅适用于已更换 6100mAh 魔改电池的设备 !!"
        ui_print " !! 非魔改电池请勿使用, 否则可能过充/鼓包 !!"
        ui_print "*********************************************************"
        ;;
    2|5)
        ui_print "- 已选择: 关机电压 2800 电池解容方案 (BATTERY=$BATTERY)"
        ;;
    6)
        ui_print "- 已选择: GT7P 竞速版解容 (满充 4.55V / 关机 2.85V / 解除充电限流)"
        ;;
    1)
        ui_print "- 已选择: 解除充电限流 (电池参数保持原版)"
        ;;
esac

# ---------------- 写入配置 ----------------
cat > "$CONFIG" <<EOF
# DTBO 刷新率超频 v2 配置 (修改后重启生效; 也可运行 menu.sh 音量键交互修改)
# 机型: $DEVNAME ($DEVICE)
HZ_CHOICE=$HZ_CHOICE
BATTERY=$BATTERY
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF

if [ "$HZ_CHOICE" != "0" ]; then
    ui_print "- 方案: 档位 ${HZ_CHOICE}Hz, 电池选项 $BATTERY"
else
    ui_print "- 方案: 不超频, 电池选项 $BATTERY"
fi
ui_print ""
ui_print "安装完成! 重启后自动生成并刷入补丁 DTBO"
ui_print "(档位在第二次重启后可用; 电池方案同步生效)"
ui_print ""
ui_print "修改方案: adb shell su -c \"sh /data/adb/modules/dtbo_oc/menu.sh\""
ui_print "          (音量键切换, 电源键确认)"
ui_print "恢复原版: 卸载模块 (自动恢复原始 DTBO)"
