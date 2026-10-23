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

ui_print "*******************************"
ui_print " 超频解容模块 "
ui_print "*******************************"

ui_print "- 安装"
TOOL="$MODPATH/arm64/dtbo_oc"
DTC="$MODPATH/arm64/dtc"
chmod 755 "$TOOL" "$DTC" \
    "$MODPATH/service.sh" "$MODPATH/menu.sh" "$MODPATH/post-fs-data.sh" "$MODPATH/bin/webuictl.sh" 2>/dev/null
mkdir -p "$MODPATH/bin" "$MODPATH/ko" 2>/dev/null

"$TOOL" >/dev/null 2>&1; BINRC=$?
if [ "$BINRC" -ge 126 ]; then
    ui_print "! 二进制无法执行 (rc=$BINRC)"
    ui_print "! 无法验证, 中止安装"
    abort
fi

DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
STOCK="$DATA_DIR/dtbo_stock.img"
CONFIG="$DATA_DIR/config"
LOG="$DATA_DIR/install.log"
mkdir -p "$DATA_DIR" "$WORK" "$DATA_DIR/ko"

LICOUT=$("$TOOL" license 2>/dev/null)
case "$LICOUT" in
    LICENSE=ok*)
        LIC_QQ=$(printf '%s\n' "$LICOUT" | sed -n 's/^LICENSE=ok QQ=\([0-9]*\) .*/\1/p')
        LIC_EXP=$(printf '%s\n' "$LICOUT" | sed -n 's/.*EXPIRY_DATE=//p')
        ui_print "- 身份验证: 已通过 (QQ $LIC_QQ, 有效期至 $LIC_EXP), 跳过"
        ;;
    *)
        ui_print "- 身份验证: 自动检测本机QQ并联网核对群名单..."
        VOUT=$("$TOOL" verify --auto 2>&1)
        VRC=$?
        VREASON=$(printf '%s\n' "$VOUT" | sed -n 's/.*REASON=//p')
        if [ "$VRC" = "0" ]; then
            VQQ=$(printf '%s\n' "$VOUT" | sed -n 's/^VERIFIED=1 QQ=\([0-9]*\).*/\1/p')
            VEXP=$(printf '%s\n' "$VOUT" | sed -n 's/.*EXPIRY_DATE=//p')
            ui_print "  验证通过: 本机QQ $VQQ 在群内, 授权30天 (至 $VEXP)"
        elif [ "$VREASON" = "not_in_group" ]; then
            ui_print "  本机QQ未加入指定QQ群,  向管理员提交ID后重新安装"
            "$TOOL" joingroup 2>/dev/null
            abort
        elif [ "$VREASON" = "not_in_group_cached" ]; then
            ui_print "  联网刷新群名单失败, 已用本地缓存核对: 本机QQ暂不在名单中"
            ui_print "  (名单可能已更新; 模块可安装, 开机联网后会自动重新验证)"
            ui_print "  (未验证通过前不会修改DTBO/不会挂载KO)"
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
    BATT_VOFF_DTS=$(echo "$IDINFO" | grep '^BATT_VOFF_STOCK=' | cut -d= -f2)
    BATT_KIND=$(echo "$IDINFO" | grep '^BATT_KIND=' | cut -d= -f2)
    BATT_VMIN=$(echo "$IDINFO" | grep '^BATT_VMIN=' | cut -d= -f2)
fi
[ -z "$STRIP" ] && STRIP=0
[ -z "$BATT_VOFF_DTS" ] && BATT_VOFF_DTS=0
[ -z "$BATT_KIND" ] && BATT_KIND=1
[ -z "$BATT_VMIN" ] && BATT_VMIN=2800
BATT_KIND_NAME="硅碳"; [ "$BATT_KIND" = "0" ] && BATT_KIND_NAME="纯碳"

[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
CHOICES=""
case "$DEVICE" in
    ace2pro)   DEF_HZ=144; CHOICES="144/165/185" ;;
    op13t)     DEF_HZ=144; CHOICES="144" ;;
    op15t)     DEF_HZ=185; CHOICES="185/188/190/195/198" ;;
    ace5)      DEF_HZ=144; CHOICES="144" ;;
    ace3)      DEF_HZ=144; CHOICES="144" ;;
    ace3pro)   DEF_HZ=144; CHOICES="144" ;;
    op12)      DEF_HZ=144; CHOICES="144" ;;
    op13)      DEF_HZ=144; CHOICES="144/150" ;;
    op15|ace6) DEF_HZ=185; CHOICES="185/188/190/195/198" ;;
    gt8)       DEF_HZ=185; CHOICES="144/165/185/188/190/195/198" ;;
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
[ -n "$DEVICE" ] && sed -i "s/^description=.*/description=为 ${DEVNAME} 定制的超频解容模块/" "$MODPATH/module.prop" 2>/dev/null
if [ "$DEVICE" = "op11" ]; then
    ui_print "- 本机型不支持刷新率超频, 仅电池/充电方案可用"
fi
if [ "$DEVICE" = "gt7p2" ]; then
    ui_print "- 本机型 AC180 面板原厂 120Hz, 可超频至 144"
fi

KO_AVAIL=0
if [ -n "$DEVICE" ]; then
    # 升级清理: 模块已内置本机型 KO 时, 删除 DATA_DIR 同名旧缓存
    # (旧 vermagic 缓存优先级高于模块内置, 会一直报内核不匹配)
    if [ -f "$MODPATH/ko/$DEVICE.ko" ] && [ -f "$DATA_DIR/ko/$DEVICE.ko" ] \
        && ! cmp -s "$MODPATH/ko/$DEVICE.ko" "$DATA_DIR/ko/$DEVICE.ko"; then
        rm -f "$DATA_DIR/ko/$DEVICE.ko"
        ui_print "- 已清理旧版缓存 KO ($DEVICE.ko)"
    fi
    for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODPATH/ko/$DEVICE.ko"; do
        [ -f "$p" ] && KO_AVAIL=1 && break
    done
fi
if [ "$KO_AVAIL" = "1" ]; then
    ui_print "- 已找到本机型 KO 内核模块 ($DEVICE.ko)"
else
    ui_print "- 未内置本机型 KO ($DEVICE.ko), 可侧载启用"
    ui_print "  (选择 KO 方案后, 放入 /data/adb/dtbo_oc/ko/ 重启即生效)"
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

HZ_CHOICE=""; OC_MODE=""; LTPO_OFF=""
BATT_LIMIT=""; BATT_UNCAP=""; BATT_MOD=""; BATT_VOFF=""
BATTERY=""
PRESET=0
if [ -f /sdcard/dtbo_oc.conf ]; then
    . /sdcard/dtbo_oc.conf
    PRESET=1
    ui_print "- 检测到 /sdcard/dtbo_oc.conf 预设, 跳过按键选择"
fi
if [ -f "$CONFIG" ]; then
    [ -z "$HZ_CHOICE" ] && HZ_CHOICE=$(grep '^HZ_CHOICE=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$OC_MODE" ] && OC_MODE=$(grep '^OC_MODE=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$LTPO_OFF" ] && LTPO_OFF=$(grep '^LTPO_OFF=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATT_LIMIT" ] && BATT_LIMIT=$(grep '^BATT_LIMIT=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATT_UNCAP" ] && BATT_UNCAP=$(grep '^BATT_UNCAP=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATT_MOD" ] && BATT_MOD=$(grep '^BATT_MOD=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATT_VOFF" ] && BATT_VOFF=$(grep '^BATT_VOFF=' "$CONFIG" 2>/dev/null | cut -d= -f2)
    [ -z "$BATTERY" ] && BATTERY=$(grep '^BATTERY=' "$CONFIG" 2>/dev/null | cut -d= -f2)
fi
# v2.50 配置迁移: 旧版 BATTERY 固定方案 -> 充电相关独立开关 (一次性)
if [ -n "$BATTERY" ]; then
    case "$BATTERY" in
        1) BATT_LIMIT=1 ;;
        2) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2800 ;;
        3) BATT_MOD=1 ;;
        4) BATT_MOD=1; BATT_LIMIT=1 ;;
        5) BATT_UNCAP=1; BATT_VOFF=2800 ;;
        6) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2800 ;;
    esac
    BATTERY=""
    ui_print "- 已迁移旧版电池方案到充电相关独立开关"
fi

if [ "$PRESET" != "1" ] && { [ "$HAVE_KEYS" = "1" ] || [ "$HAVE_GETEVENT" = "1" ]; }; then
    ui_print " "
    if [ "$HAVE_KEYS" = "1" ]; then
        ui_print "- 请用 [音量+/音量-] 切换选项, [电源键] 确认"
    else
        ui_print "- 请用 [音量+/音量-] 切换选项, [电源键] 确认 (兼容模式)"
    fi

    MODE_INIT=0
    [ "${OC_MODE:-dtbo}" = "ko" ] && MODE_INIT=1
    ui_choose "选择超频方案:" "DTBO 补丁 (重启生效)|KO 内核挂载 (不改DTBO, 重启生效)" "$MODE_INIT"
    OC_MODE=$([ "$SEL" = "1" ] && echo ko || echo dtbo)
    if [ "$OC_MODE" = "ko" ] && [ "$DEVICE" = "ace6" ]; then
        ui_choose "确认: 仍要在 ACE6 上启用 KO 方案?" "否, 改用 DTBO 补丁 (推荐)|是, 我已知晓无法开机风险" 0
        [ "$SEL" = "0" ] && { OC_MODE=dtbo; ui_print "- 已改用 DTBO 补丁"; }
    fi
    if [ "$OC_MODE" = "ko" ] && [ "$KO_AVAIL" != "1" ]; then
        ui_print "- 本机型未内置 KO, 安装后侧载 KO 文件才会生效"
        ui_print "  (放入 /data/adb/dtbo_oc/ko/$DEVICE.ko 后重启)"
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
        BATT_LIMIT=0; BATT_UNCAP=0; BATT_MOD=0
        ui_print "- KO 方案不修改 DTBO, 充电相关功能不可用 (已全部关闭)"
    else
        ui_print " "
        ui_print "- 充电相关 (独立开关, 可任意组合; 原厂关机电压: $([ "$BATT_VOFF_DTS" != "0" ] && echo "${BATT_VOFF_DTS}mV" || echo "未识别"))"

        L_INIT=0; [ "${BATT_LIMIT:-0}" = "1" ] && L_INIT=1
        ui_choose "解除充电限流 (删限流节点/策略表电流拉满8000mA):" "关闭|开启" "$L_INIT"
        BATT_LIMIT=$([ "$SEL" = "1" ] && echo 1 || echo 0)

        U_INIT=0; [ "${BATT_UNCAP:-0}" = "1" ] && U_INIT=1
        ui_choose "电池解容 (自定义关机电压, 释放底部隐藏电量):" "关闭|开启" "$U_INIT"
        BATT_UNCAP=$([ "$SEL" = "1" ] && echo 1 || echo 0)
        if [ "$BATT_UNCAP" = "1" ]; then
            ui_print "- 原厂关机电压: $([ "$BATT_VOFF_DTS" != "0" ] && echo "${BATT_VOFF_DTS}mV" || echo "未识别") (电池类型: ${BATT_KIND_NAME})"
            VOPTS=""; VINIT=7; i=0; v=2450
            [ -n "${BATT_VOFF:-}" ] || BATT_VOFF=2800
            while [ "$v" -le 2800 ]; do
                VOPTS="${VOPTS:+$VOPTS|}${v}mV"
                [ "$BATT_VOFF" = "$v" ] && VINIT=$i
                i=$((i+1)); v=$((v+50))
            done
            ui_choose "关机电压 (1%电量=关机+50mV, 充电中欠压=关机-100mV):" "$VOPTS" "$VINIT"
            BATT_VOFF=2800; i=0; v=2450
            while [ "$v" -le 2800 ]; do
                [ "$i" = "$SEL" ] && BATT_VOFF=$v
                i=$((i+1)); v=$((v+50))
            done
            ui_print "- 本机为${BATT_KIND_NAME}电池, 最低关机电压 ${BATT_VMIN}mV, 低于 ${BATT_VMIN} 可能会无效"
        fi

        if [ "$BATT_OK" = "1" ]; then
            M_INIT=0; [ "${BATT_MOD:-0}" = "1" ] && M_INIT=1
            ui_choose "魔改电池 (容量固定 6100mAh, 仅已更换魔改电芯时开启):" "关闭|开启" "$M_INIT"
            BATT_MOD=$([ "$SEL" = "1" ] && echo 1 || echo 0)
            if [ "$BATT_MOD" = "1" ]; then
                ui_choose "确认: 设备是否已更换 6100mAh 魔改电池?" "否, 改回关闭|是, 确认已更换" 0
                [ "$SEL" = "0" ] && { BATT_MOD=0; ui_print "- 已改回关闭"; }
            fi
        else
            BATT_MOD=0
        fi

    fi

    LTPO_INIT=0
    [ "${LTPO_OFF:-0}" = "1" ] && LTPO_INIT=1
    ui_choose "禁用 LTPO 动态刷新率 (防止系统自动降档锁 60Hz):" "保持默认 (保留 LTPO/VRR 自适应)|禁用 (超频档位更稳定, 可能略增耗电)" "$LTPO_INIT"
    LTPO_OFF=$([ "$SEL" = "1" ] && echo 1 || echo 0)
elif [ "$PRESET" != "1" ]; then
    ui_print "! 当前环境不支持按键交互 (无输入设备/权限)"
    ui_print "  使用默认/已有配置, 或在 /sdcard/dtbo_oc.conf 写入预设后重装:"
    ui_print "  HZ_CHOICE=144/165/185/0(不超频), OC_MODE=dtbo/ko"
    ui_print "  充电相关: BATT_LIMIT=0/1 BATT_UNCAP=0/1 BATT_VOFF=2450-2800"
    ui_print "            BATT_MOD=0/1"
    if [ -z "$CHOICES" ] || [ "$OC_OK" != "1" ]; then HZ_CHOICE=0; fi
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

# 充电相关参数规范化 (v2.50 全自定义模型)
[ -z "$BATT_LIMIT" ] && BATT_LIMIT=0
[ -z "$BATT_UNCAP" ] && BATT_UNCAP=0
[ -z "$BATT_MOD" ] && BATT_MOD=0
[ -z "$BATT_VOFF" ] && BATT_VOFF=2800
case "$BATT_LIMIT" in 0|1) ;; *) BATT_LIMIT=0 ;; esac
case "$BATT_UNCAP" in 0|1) ;; *) BATT_UNCAP=0 ;; esac
case "$BATT_MOD" in 0|1) ;; *) BATT_MOD=0 ;; esac
case "$BATT_VOFF" in ''|*[!0-9]*) BATT_VOFF=2800 ;; esac
[ "$BATT_VOFF" -lt 2450 ] && BATT_VOFF=2450
[ "$BATT_VOFF" -gt 2800 ] && BATT_VOFF=2800
[ -z "$OC_MODE" ] && OC_MODE=dtbo
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac
if [ "$OC_MODE" = "ko" ] && [ "$KO_AVAIL" != "1" ]; then
    ui_print "! 未找到本机型 KO ($DEVICE.ko), 已保持 KO 方案"
    ui_print "  (侧载 KO 到 /data/adb/dtbo_oc/ko/ 后重启生效)"
fi
[ -z "$LTPO_OFF" ] && LTPO_OFF=0
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac

if [ "$BATT_MOD" = "1" ] && [ "$BATT_OK" != "1" ]; then
    ui_print "- 魔改电池仅 ACE2Pro/一加11/一加12 支持, 已重置为关闭"
    BATT_MOD=0
fi
if [ "$OC_MODE" = "ko" ]; then
    if [ "$BATT_LIMIT$BATT_UNCAP$BATT_MOD" != "000" ]; then
        BATT_LIMIT=0; BATT_UNCAP=0; BATT_MOD=0
        ui_print "- KO 方案不修改 DTBO, 充电相关功能已全部关闭"
    fi
fi
if [ "$BATT_LIMIT" = "1" ]; then ui_print "- 已选择: 解除充电限流"; fi
if [ "$BATT_UNCAP" = "1" ]; then ui_print "- 已选择: 电池解容 (关机 ${BATT_VOFF}mV / 1% $((BATT_VOFF+50))mV)"; fi
if [ "$BATT_MOD" = "1" ]; then ui_print "- 已选择: 魔改电池 6100mAh"; fi

cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATT_LIMIT=$BATT_LIMIT
BATT_UNCAP=$BATT_UNCAP
BATT_VOFF=$BATT_VOFF
BATT_MOD=$BATT_MOD
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
        ui_print "- 方案: DTBO 补丁, 档位 ${HZ_CHOICE}Hz"
    else
        ui_print "- 方案: DTBO 补丁, 不超频 (仅充电相关功能)"
    fi
fi
if [ "$LTPO_OFF" = "1" ]; then
    ui_print "- LTPO 动态刷新率: 已禁用 (重启后完全生效)"
    sh "$MODPATH/post-fs-data.sh" >/dev/null 2>&1
else
    ui_print "- LTPO 动态刷新率: 保持默认"
fi

ui_print " "


ui_print "  重启后  自动备份原厂dtbo并生成补丁刷入"
ui_print "  (第 1 次重启: 备份并刷入; 第 2 次重启: 新档位完整生效)"

ui_print "- 若无法开机: fastboot 刷回原厂 dtbo 即可恢复"
ui_print ""
ui_print "安装完成! 如需修改超频配置请重启到WEBUI页面重新保存"
