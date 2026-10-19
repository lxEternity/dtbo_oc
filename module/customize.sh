#!/system/bin/sh
SKIPUNZIP=0

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort >/dev/null 2>&1 || abort() { ui_print "$1"; exit 1; }
command -v getprop >/dev/null 2>&1 || getprop() {
    case "$1" in
        ro.product.cpu.abi) echo arm64-v8a ;;
        *) return 0 ;;
    esac
}

ARCH64=$(getprop ro.product.cpu.abi)
if [ "$ARCH64" != "arm64-v8a" ]; then
    ui_print "! 本模块仅支持 arm64 设备 (当前: $ARCH64)"
    abort
fi

LOCKED=$(getprop ro.boot.flash.locked)
VBS=$(getprop ro.boot.verifiedbootstate)
if [ "$LOCKED" = "1" ] || [ "$VBS" = "green" ]; then
    ui_print "*********************************************************"
    ui_print " !! 警告: Bootloader 检测为锁定/校验状态 !!"
    ui_print " !! 未解锁 BL 刷入修改后的 DTBO 会导致无法开机(变砖) !!"
    ui_print " !! (Recovery 环境下该检测可能误报, 请以实际解锁状态为准) !!"
    ui_print "*********************************************************"
fi

ui_print "*******************************"
ui_print " 超频解容模块 (多机型) v2.37"
ui_print "*******************************"
ui_print "- 安全架构: 安装零分区写入, 不碰校验分区"
ui_print "- 安装二进制: dtbo_oc + dtc (静态 arm64)"
TOOL="$MODPATH/arm64/dtbo_oc"
DTC="$MODPATH/arm64/dtc"
chmod 755 "$TOOL" "$DTC" \
    "$MODPATH/service.sh" "$MODPATH/menu.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/bin/webuictl.sh" 2>/dev/null
mkdir -p "$MODPATH/bin" "$MODPATH/ko" 2>/dev/null

"$TOOL" >/dev/null 2>&1; BINRC=$?
if [ "$BINRC" -ge 126 ]; then
    ui_print "! dtbo_oc 二进制无法执行 (rc=$BINRC)"
    ui_print "! 无法进行QQ群验证, 中止安装"
    abort
fi

DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
STOCK="$DATA_DIR/dtbo_stock.img"
CONFIG="$DATA_DIR/config"
LOG="$DATA_DIR/install.log"
mkdir -p "$DATA_DIR" "$WORK" "$DATA_DIR/ko"

# ---- v2.37 QQ群验证: 安装时自动检测本机QQ并联网核对群名单 ----
LICOUT=$("$TOOL" license 2>/dev/null)
case "$LICOUT" in
    LICENSE=ok*)
        LIC_QQ=$(printf '%s\n' "$LICOUT" | sed -n 's/^LICENSE=ok QQ=\([0-9]*\) .*/\1/p')
        LIC_EXP=$(printf '%s\n' "$LICOUT" | sed -n 's/.*EXPIRY_DATE=//p')
        ui_print "- QQ群验证: 已通过 (QQ $LIC_QQ, 有效期至 $LIC_EXP), 跳过"
        ;;
    *)
        ui_print "- QQ群验证: 自动检测本机QQ并联网核对群名单..."
        VOUT=$("$TOOL" verify --auto 2>&1)
        VRC=$?
        VREASON=$(printf '%s\n' "$VOUT" | sed -n 's/.*REASON=//p')
        if [ "$VRC" = "0" ]; then
            VQQ=$(printf '%s\n' "$VOUT" | sed -n 's/^VERIFIED=1 QQ=\([0-9]*\).*/\1/p')
            VEXP=$(printf '%s\n' "$VOUT" | sed -n 's/.*EXPIRY_DATE=//p')
            ui_print "  验证通过: 本机QQ $VQQ 在群内, 授权30天 (至 $VEXP)"
        elif [ "$VREASON" = "not_in_group" ]; then
            ui_print "*********************************************************"
            ui_print " !! 本机QQ未加入指定QQ群, 禁止刷入 !!"
            ui_print " !! 正在打开QQ群卡片, 请申请加群       !!"
            ui_print " !! 加群并经群主同步名单后, 重新安装本模块即可 !!"
            ui_print "*********************************************************"
            "$TOOL" joingroup 2>/dev/null
            abort
        else
            case "$VREASON" in
                no_local_qq)     ui_print "  未检测到本机QQ账号, 安装后可在 WebUI/菜单手动验证" ;;
                download_failed) ui_print "  无法联网拉取群名单, 安装后可在 WebUI/菜单重新验证" ;;
                list_invalid)    ui_print "  云端群名单无效, 请联系群主" ;;
                *)               ui_print "  自动验证未完成, 安装后可在 WebUI/菜单验证" ;;
            esac
            ui_print "  (模块可安装; 未验证前不会修改DTBO/不会挂载KO)"
        fi
        ;;
esac

SLOT=$(getprop ro.boot.slot_suffix)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/soc/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        if [ -e "$d/$n" ]; then DTBO="$d/$n"; break 2; fi
    done
done
if [ -z "$DTBO" ]; then
    DTBO=$(ls -d /dev/block/platform/*/by-name/dtbo 2>/dev/null | head -n 1)
    [ -z "$DTBO" ] && DTBO=$(find /dev/block -maxdepth 4 -name 'dtbo*' 2>/dev/null | head -n 1)
fi
if [ -z "$DTBO" ]; then
    ui_print "! 未找到 dtbo 分区, 模块仍将安装, 开机后由 service.sh 重试"
else
    ui_print "- dtbo 分区: $DTBO"
    if [ ! -f "$STOCK" ]; then
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

DEVICE=""; DEVNAME=""
if [ -f "$STOCK" ]; then
    IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
    DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
    DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
    MAXRATE=$(echo "$IDINFO" | grep '^MAX_RATE=' | cut -d= -f2)
    BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
    OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
    STRIP=$(echo "$IDINFO" | grep '^STRIP_ABOVE=' | cut -d= -f2)
fi
[ -z "$STRIP" ] && STRIP=0

[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
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
    ace6u)     DEF_HZ=185; CHOICES="185" ;;
    ace5p)     DEF_HZ=144; CHOICES="144" ;;
    gt7p2)     DEF_HZ=144; CHOICES="144" ;;
    op11)      DEF_HZ=0;   CHOICES="" ;;
    *)
        ui_print "! 无法识别机型 (DEVICE=$DEVICE)"
        ui_print "! 模块仍将安装, 但开机 service.sh 会再次校验并中止"
        DEF_HZ=144; CHOICES=""; BATT_OK=0; DEVNAME="未知机型"
        ;;
esac
[ -n "$DEVNAME" ] && ui_print "- 机型识别: $DEVNAME ($DEVICE) 原厂最高档 ${MAXRATE:-?}Hz"
if [ "$DEVICE" = "op11" ]; then
    ui_print "- 本机型不支持刷新率超频, 仅电池/充电方案可用"
fi
if [ "$DEVICE" = "gt7p2" ]; then
    ui_print "- 本机型 AC180 面板原厂 120Hz, 可超频至 144"
fi

KO_AVAIL=0
if [ -n "$DEVICE" ]; then
    for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODPATH/ko/$DEVICE.ko"; do
        [ -f "$p" ] && KO_AVAIL=1 && break
    done
fi
if [ "$KO_AVAIL" = "1" ]; then
    ui_print "- 已找到本机型 KO 内核模块 ($DEVICE.ko)"
else
    ui_print "- 未找到本机型 KO ($DEVICE.ko), KO 挂载方案暂不可用"
    ui_print "  (放入 /data/adb/dtbo_oc/ko/ 后即可在 WebUI 选择)"
fi

HAVE_KEYS=0
[ -x "$TOOL" ] && HAVE_KEYS=1
HAVE_GETEVENT=0
command -v getevent >/dev/null 2>&1 && HAVE_GETEVENT=1
KEY_TIMEOUT=60
command -v timeout >/dev/null 2>&1 || KEY_TIMEOUT=0

wake_screen() { command -v input >/dev/null 2>&1 && input keyevent 224 2>/dev/null; return 0; }

wait_key() {
    if [ "$HAVE_KEYS" = "1" ]; then
        if [ "$KEY_TIMEOUT" -gt 0 ] 2>/dev/null; then
            K=$(timeout "$KEY_TIMEOUT" "$TOOL" keys 2>/dev/null)
        else
            K=$("$TOOL" keys 2>/dev/null)
        fi
        [ -n "$K" ] && { [ "$K" = "select" ] && wake_screen; echo "$K"; return 0; }
        [ "$K" = "timeout" ] && return 2
        HAVE_KEYS=0
    fi
    while true; do
        if [ "$KEY_TIMEOUT" -gt 0 ] 2>/dev/null; then
            EV=$(timeout "$KEY_TIMEOUT" getevent -qlc 1 2>/dev/null | head -n 1)
        else
            EV=$(getevent -qlc 1 2>/dev/null | head -n 1)
        fi
        [ -z "$EV" ] && return 1
        case "$EV" in
            *KEY_VOLUMEUP*DOWN*)   echo up; return 0 ;;
            *KEY_VOLUMEDOWN*DOWN*) echo down; return 0 ;;
            *KEY_POWER*DOWN*)      wake_screen; echo select; return 0 ;;
        esac
    done
}

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
    ui_print "  (${KEY_TIMEOUT}秒无按键将自动采用当前选择)"
    while true; do
        if ! K=$(wait_key); then
            ui_print "  (未检测到按键, 采用当前选择)"
            break
        fi
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

HZ_CHOICE=""; BATTERY=""; OC_MODE=""; LTPO_OFF=""
PRESET=0
if [ -f /sdcard/dtbo_oc.conf ]; then
    . /sdcard/dtbo_oc.conf
    PRESET=1
    ui_print "- 检测到 /sdcard/dtbo_oc.conf 预设, 跳过按键选择"
fi
if [ -f "$CONFIG" ]; then
    [ -z "$HZ_CHOICE" ] && HZ_CHOICE=$(grep '^HZ_CHOICE=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATTERY" ] && BATTERY=$(grep '^BATTERY=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$OC_MODE" ] && OC_MODE=$(grep '^OC_MODE=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$LTPO_OFF" ] && LTPO_OFF=$(grep '^LTPO_OFF=' "$CONFIG" 2>/dev/null | cut -d= -f2)
fi

if [ "$PRESET" != "1" ] && { [ "$HAVE_KEYS" = "1" ] || [ "$HAVE_GETEVENT" = "1" ]; }; then
    ui_print " "
    ui_print "- 请用 [音量+/音量-] 切换选项, [电源键] 确认"
    ui_print "  (按键事件已被拦截: 电源键确认不会息屏, 音量键不会弹音量条)"

    MODE_INIT=0
    [ "${OC_MODE:-dtbo}" = "ko" ] && MODE_INIT=1
    if [ "$KO_AVAIL" != "1" ]; then MODE_INIT=0; fi
    if [ "$DEVICE" = "ace6u" ]; then
        OC_MODE=ko
        ui_print "- 一加ACE6至尊版: 仅支持 KO 内核挂载方案 (DTBO 方案已移除)"
    elif [ "$KO_AVAIL" = "1" ]; then
        ui_choose "选择超频方案:" "DTBO 补丁 (重启生效)|KO 内核挂载 (不改DTBO, 重启生效)" "$MODE_INIT"
        OC_MODE=$([ "$SEL" = "1" ] && echo ko || echo dtbo)
        if [ "$OC_MODE" = "ko" ] && [ "$DEVICE" = "ace6" ]; then
            ui_print " "
            ui_print "*********************************************************"
            ui_print " !! 一加ACE6 (PLQ110) KO 风险警告 !!"
            ui_print " !! 该 KO 未经真机验证, 且本机内核为 !!"
            ui_print " !! PANIC_ON_OOPS + KASAN 配置 !!"
            ui_print " !! 若加载异常将直接无法开机, 需进 Recovery !!"
            ui_print " !! 移除本模块才能恢复 !!"
            ui_print "*********************************************************"
            ui_choose "确认: 仍要在 ACE6 上启用 KO 方案?" "否, 改用 DTBO 补丁 (推荐)|是, 我已知晓无法开机风险" 0
            [ "$SEL" = "0" ] && { OC_MODE=dtbo; ui_print "- 已改用 DTBO 补丁"; }
        fi
    else
        OC_MODE=dtbo
        ui_print "- 本机型暂无可用 KO, 超频方案: DTBO 补丁"
    fi

    if [ -n "$CHOICES" ] && [ "$OC_OK" = "1" ]; then
        OPTSTR=""; INIT=0; i=0
        for c in $(echo "$CHOICES" | tr '/' ' '); do
            OPTSTR="${OPTSTR:+$OPTSTR|}${c}Hz"
            [ "$c" = "$HZ_CHOICE" ] && INIT=$i
            i=$((i+1))
        done
        OPTSTR="$OPTSTR|不超频 (仅电池/充电方案)"
        [ "$HZ_CHOICE" = "0" ] && INIT=$i
        ui_choose "选择超频目标档位 (仅生成 <= 所选的档位):" "$OPTSTR" "$INIT"
        HZ_CHOICE=0
        i=0
        for c in $(echo "$CHOICES" | tr '/' ' '); do
            [ "$i" = "$SEL" ] && HZ_CHOICE="$c"
            i=$((i+1))
        done
    else
        ui_print "- 本机型不支持刷新率超频, 跳过档位选择"
        HZ_CHOICE=0
    fi

    if [ "$OC_MODE" = "ko" ]; then
        BATTERY=0
        ui_print "- KO 方案不修改 DTBO, 电池/充电方案不可用"
    elif [ "$DEVICE" = "gt7p" ]; then
        GT_INIT=0
        [ "${BATTERY:-0}" = "6" ] && GT_INIT=1
        ui_choose "电池/充电方案:" "保持原版电池|GT7P 竞速版解容 (满充4.55V/关机2.85V/解除充电限流)" "$GT_INIT"
        BATTERY=$([ "$SEL" = "1" ] && echo 6 || echo 0)
    else
        BAT_MENU="保持原版电池|解除充电限流|解除充电限流 + 电池解容 (关机2.8V/1%2.85V/充电欠压2.7V)|原版电池 + 电池解容 (关机2.8V/1%2.85V/充电欠压2.7V)"
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

    LTPO_INIT=0
    [ "${LTPO_OFF:-0}" = "1" ] && LTPO_INIT=1
    ui_choose "禁用 LTPO 动态刷新率 (防止系统自动降档锁 60Hz):" "保持默认 (保留 LTPO/VRR 自适应)|禁用 (超频档位更稳定, 可能略增耗电)" "$LTPO_INIT"
    LTPO_OFF=$([ "$SEL" = "1" ] && echo 1 || echo 0)
elif [ "$PRESET" != "1" ]; then
    ui_print "- 当前环境不支持按键交互 (无输入设备/权限), 使用默认/已有配置"
    if [ -z "$CHOICES" ] || [ "$OC_OK" != "1" ]; then HZ_CHOICE=0; fi
    [ "$KO_AVAIL" != "1" ] && [ "${OC_MODE:-dtbo}" = "ko" ] && OC_MODE=dtbo
fi

if [ "$OC_OK" = "1" ] && [ -n "$CHOICES" ]; then
    VALID=0
    [ "$HZ_CHOICE" = "0" ] && VALID=1
    for c in $(echo "$CHOICES" | tr '/' ' '); do [ "$HZ_CHOICE" = "$c" ] && VALID=1; done
    if [ "$VALID" != "1" ]; then
        HZ_CHOICE="$DEF_HZ"
        ui_print "- 档位未指定/不适用, 使用默认 ${DEF_HZ}Hz"
    fi
else
    HZ_CHOICE=0
fi

[ -z "$BATTERY" ] && BATTERY=0
case "$BATTERY" in 0|1|2|3|4|5|6) ;; *) BATTERY=0 ;; esac
[ -z "$OC_MODE" ] && OC_MODE=dtbo
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac
if [ "$DEVICE" = "ace6u" ] && [ "$OC_MODE" != "ko" ]; then
    OC_MODE=ko
    ui_print "- 一加ACE6至尊版: 仅支持 KO 方案, 已自动切换"
fi
if [ "$DEVICE" = "ace6u" ] && [ "$KO_AVAIL" != "1" ]; then
    ui_print "! 未找到 ace6u.ko, 请侧载 KO 后重装: /data/adb/dtbo_oc/ko/ace6u.ko"
elif [ "$KO_AVAIL" != "1" ] && [ "$OC_MODE" = "ko" ]; then
    ui_print "! 未找到本机型 KO, 方案回退为 DTBO 补丁"
    OC_MODE=dtbo
fi
if [ "$OC_MODE" = "ko" ] && [ "$BATTERY" != "0" ]; then
    BATTERY=0
    ui_print "- KO 方案不修改 DTBO, 电池选项已重置为原版"
fi
[ -z "$LTPO_OFF" ] && LTPO_OFF=0
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac

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
        ui_print "- 已选择: 电池解容 (关机 2.8V / 1% 2.85V / 充电欠压 2.7V)"
        [ "$BATTERY" = "2" ] && ui_print "- 已选择: 解除充电限流"
        ;;
    6)
        ui_print "- 已选择: GT7P 竞速版解容 (满充 4.55V / 关机 2.85V / 解除充电限流)"
        ;;
    1)
        ui_print "- 已选择: 解除充电限流 (电池参数保持原版)"
        ;;
esac

cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATTERY=$BATTERY
OC_MODE=$OC_MODE
LTPO_OFF=$LTPO_OFF
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
rm -f "$DATA_DIR/.flash_fp" "$DATA_DIR/.rescue_lock"

if [ "$OC_MODE" = "ko" ]; then
    ui_print "- 方案: KO 内核挂载, 档位 ${HZ_CHOICE}Hz (不修改任何分区)"
else
    if [ "$HZ_CHOICE" != "0" ]; then
        ui_print "- 方案: DTBO 补丁, 档位 ${HZ_CHOICE}Hz, 电池选项 $BATTERY"
    else
        ui_print "- 方案: DTBO 补丁, 不超频, 电池选项 $BATTERY"
    fi
fi
if [ "$LTPO_OFF" = "1" ]; then
    ui_print "- LTPO 动态刷新率: 已禁用 (重启后完全生效)"
    sh "$MODPATH/post-fs-data.sh" >/dev/null 2>&1
else
    ui_print "- LTPO 动态刷新率: 保持默认"
fi

ui_print " "
ui_print "- v2.37 QQ群验证: 安装时自动检测本机QQ并联网核对群名单"
ui_print "  (未入群将打开QQ群卡片并阻止刷入; 已验证授权30天)"
ui_print "- 安全架构: 安装过程不写入任何分区"
ui_print "  重启后 service.sh 自动: 备份原厂 -> 生成补丁 -> 刷入 dtbo"
ui_print "  (第 1 次重启: 备份并刷入; 第 2 次重启: 新档位完整生效)"
ui_print "- 救援保护: 补丁被还原(非OTA)时自动锁定, 防止救回后再刷"
ui_print "- 若无法开机: fastboot 刷回原厂 dtbo 即可恢复"
ui_print ""
ui_print "安装完成! WebUI: KernelSU/Magisk 管理器 -> 超频解容 -> 打开WebUI"
