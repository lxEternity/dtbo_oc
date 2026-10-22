#!/system/bin/sh
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
BATT_VOFF_DTS=$(echo "$IDINFO" | grep '^BATT_VOFF_DTS=' | cut -d= -f2)
BATT_FULL_DTS=$(echo "$IDINFO" | grep '^BATT_FULL_DTS=' | cut -d= -f2)
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
[ -z "$BATT_VOFF_DTS" ] && BATT_VOFF_DTS=0
[ -z "$BATT_FULL_DTS" ] && BATT_FULL_DTS=0
CHOICES=""
case "$DEVICE" in
    ace2pro)   CHOICES="144 165 185" ;;
    op13t)     CHOICES="144" ;;
    op15t)     CHOICES="185 188 190 195 198" ;;
    ace5)      CHOICES="144" ;;
    ace3)      CHOICES="144" ;;
    ace3pro)   CHOICES="144" ;;
    op12)      CHOICES="144" ;;
    op13)      CHOICES="144 150" ;;
    op15|ace6) CHOICES="185 188 190 195 198" ;;
    gt8)       CHOICES="144 165 185 188 190 195 198" ;;
    gt7p)      CHOICES="130 142 144" ;;
    gt7s)      CHOICES="144 165 185" ;;
    gt8p)      CHOICES="165 185" ;;
    ace6t)     CHOICES="185" ;;
    ace6u)     CHOICES="185" ;;
    ace5p)     CHOICES="144" ;;
    gt7p2)     CHOICES="144 150" ;;
    op11)      CHOICES="" ;;
    *) echo "[错误] 无法识别机型 (DEVICE=$DEVICE)"; exit 1 ;;
esac

HZ_CHOICE=""; OC_MODE=""; LTPO_OFF=""
BATT_LIMIT=""; BATT_UNCAP=""; BATT_MOD=""; BATT_FULL_ON=""; BATT_VOFF=""; BATT_FULL=""
[ -f "$CONFIG" ] && . "$CONFIG"

if [ -n "$BATTERY" ]; then
    case "$BATTERY" in
        1) BATT_LIMIT=1 ;;
        2) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2800 ;;
        3) BATT_MOD=1 ;;
        4) BATT_MOD=1; BATT_LIMIT=1 ;;
        5) BATT_UNCAP=1; BATT_VOFF=2800 ;;
        6) BATT_LIMIT=1; BATT_UNCAP=1; BATT_VOFF=2850; BATT_FULL_ON=1; BATT_FULL=4550 ;;
    esac
    sed -i '/^BATTERY=/d' "$CONFIG" 2>/dev/null
    { echo "BATT_LIMIT=${BATT_LIMIT:-0}"; echo "BATT_UNCAP=${BATT_UNCAP:-0}"
      echo "BATT_VOFF=${BATT_VOFF:-3000}"; echo "BATT_MOD=${BATT_MOD:-0}"
      echo "BATT_FULL_ON=${BATT_FULL_ON:-0}"; echo "BATT_FULL=${BATT_FULL:-0}"; } >> "$CONFIG"
   
    BATTERY=""
fi
[ -z "$HZ_CHOICE" ] && HZ_CHOICE=144
[ -z "$OC_MODE" ] && OC_MODE=dtbo
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac
[ -z "$LTPO_OFF" ] && LTPO_OFF=0
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac
[ -z "$BATT_LIMIT" ] && BATT_LIMIT=0
[ -z "$BATT_UNCAP" ] && BATT_UNCAP=0
[ -z "$BATT_MOD" ] && BATT_MOD=0
[ -z "$BATT_FULL_ON" ] && BATT_FULL_ON=0
[ -z "$BATT_VOFF" ] && BATT_VOFF=3000
[ -z "$BATT_FULL" ] && BATT_FULL=0
case "$BATT_LIMIT" in 0|1) ;; *) BATT_LIMIT=0 ;; esac
case "$BATT_UNCAP" in 0|1) ;; *) BATT_UNCAP=0 ;; esac
case "$BATT_MOD" in 0|1) ;; *) BATT_MOD=0 ;; esac
case "$BATT_FULL_ON" in 0|1) ;; *) BATT_FULL_ON=0 ;; esac
case "$BATT_VOFF" in ''|*[!0-9]*) BATT_VOFF=3000 ;; esac
[ "$BATT_VOFF" -lt 2700 ] && BATT_VOFF=2700
[ "$BATT_VOFF" -gt 3350 ] && BATT_VOFF=3350
case "$BATT_FULL" in ''|*[!0-9]*) BATT_FULL=0 ;; esac
[ "$BATT_FULL" -gt 0 ] && [ "$BATT_FULL" -lt 4300 ] && BATT_FULL=4300
[ "$BATT_FULL" -gt 4570 ] && BATT_FULL=4570
[ "$BATT_MOD" = "1" ] && [ "$BATT_OK" != "1" ] && BATT_MOD=0
[ "$BATT_FULL_ON" = "1" ] && [ "$BATT_FULL" = "0" ] && { [ "$BATT_FULL_DTS" -ge 4300 ] && [ "$BATT_FULL_DTS" -le 4570 ] && BATT_FULL=$BATT_FULL_DTS || BATT_FULL_ON=0; }

KO_AVAIL=0
for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODDIR/ko/$DEVICE.ko"; do
    [ -f "$p" ] && KO_AVAIL=1 && break
done

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
echo " 超频解容模块"
echo " 机型: $DEVNAME ($DEVICE)"
echo "$TIPS"
echo "=============================================="

LICOUT=$("$TOOL" license 2>/dev/null)
case "$LICOUT" in
    LICENSE=ok*)
        LIC_QQ=$(printf '%s\n' "$LICOUT" | sed -n 's/^LICENSE=ok QQ=\([0-9]*\) .*/\1/p')
        LIC_EXP=$(printf '%s\n' "$LICOUT" | sed -n 's/.*EXPIRY_DATE=//p')
        echo " 身份验证: 已通过 (QQ $LIC_QQ, 有效期至 $LIC_EXP)"
        ;;
    *)
        echo " 身份验证: 未通过, 尝试自动验证本机QQ..."
        if "$TOOL" verify --auto >/dev/null 2>&1; then
            LICOUT=$("$TOOL" license 2>/dev/null)
            LIC_QQ=$(printf '%s\n' "$LICOUT" | sed -n 's/^LICENSE=ok QQ=\([0-9]*\) .*/\1/p')
            LIC_EXP=$(printf '%s\n' "$LICOUT" | sed -n 's/.*EXPIRY_DATE=//p')
            echo " 身份验证: 自动通过 (本机QQ $LIC_QQ, 有效期至 $LIC_EXP)"
        else
        echo "----------------------------------------------"
        echo " 自动验证未通过, 可手动输入QQ号验证"
        echo " (验证需联网拉取群成员名单,)"
        VERIFY_OK=0
        TRIES=0
        while [ "$TRIES" -lt 3 ] && [ "$VERIFY_OK" != "1" ]; do
            printf " 请输入QQ号进行验证 (直接回车退出): "
            if ! read QQIN; then break; fi
            [ -z "$QQIN" ] && break
            if "$TOOL" verify --qq "$QQIN"; then
                VERIFY_OK=1
            else
                TRIES=$((TRIES+1))
                echo " 验证未通过 (剩余尝试: $((3 - TRIES)))"
            fi
        done
        if [ "$VERIFY_OK" != "1" ]; then
            echo "----------------------------------------------"
            echo "[退出] 未完成身份验证, 无法使用超频功能"
            echo " QQ群内向管理员提交ID后重新验证"
            exit 1
        fi
        fi
        ;;
esac

MODE_INIT=0
[ "$OC_MODE" = "ko" ] && MODE_INIT=1
choose "选择超频方案:" "DTBO 补丁 (刷入分区, 重启生效)|KO 内核挂载 (不改DTBO, 即时生效)" "$MODE_INIT"
OC_MODE=$([ "$SEL" = "1" ] && echo ko || echo dtbo)
if [ "$OC_MODE" = "ko" ] && [ "$KO_AVAIL" != "1" ]; then
    echo " 本机型未内置 KO, 需侧载 KO 文件才会生效"
    echo " (放入 /data/adb/dtbo_oc/ko/$DEVICE.ko 后重启)"
fi

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

if [ "$OC_MODE" = "ko" ]; then
    BATT_LIMIT=0; BATT_UNCAP=0; BATT_MOD=0; BATT_FULL_ON=0
    echo " KO 方案不修改 DTBO, 充电相关功能不可用 (已全部关闭)"
else
    echo ""
    echo " 充电相关 (独立开关, 可任意组合; DTBO 基准: 关机 $([ "$BATT_VOFF_DTS" != "0" ] && echo "${BATT_VOFF_DTS}mV" || echo "未识别") / 满充 $([ "$BATT_FULL_DTS" != "0" ] && echo "${BATT_FULL_DTS}mV" || echo "未识别"))"

    L_INIT=0; [ "$BATT_LIMIT" = "1" ] && L_INIT=1
    choose "解除充电限流 (删限流节点/策略表电流拉满8000mA):" "关闭|开启" "$L_INIT"
    BATT_LIMIT=$([ "$SEL" = "1" ] && echo 1 || echo 0)

    U_INIT=0; [ "$BATT_UNCAP" = "1" ] && U_INIT=1
    choose "电池解容 (自定义关机电压, 释放底部隐藏电量):" "关闭|开启" "$U_INIT"
    BATT_UNCAP=$([ "$SEL" = "1" ] && echo 1 || echo 0)
    if [ "$BATT_UNCAP" = "1" ]; then
        VOPTS=""; VINIT=6; i=0; v=2700
        while [ "$v" -le 3350 ]; do
            VOPTS="${VOPTS:+$VOPTS|}${v}mV"
            [ "$BATT_VOFF" = "$v" ] && VINIT=$i
            i=$((i+1)); v=$((v+50))
        done
        choose "关机电压 (1%电量=关机+50mV, 充电中欠压=关机-100mV):" "$VOPTS" "$VINIT"
        BATT_VOFF=3000; i=0; v=2700
        while [ "$v" -le 3350 ]; do
            [ "$i" = "$SEL" ] && BATT_VOFF=$v
            i=$((i+1)); v=$((v+50))
        done
    fi

    if [ "$BATT_OK" = "1" ]; then
        M_INIT=0; [ "$BATT_MOD" = "1" ] && M_INIT=1
        choose "魔改电池 (容量固定 6100mAh, 仅已更换魔改电芯时开启):" "关闭|开启" "$M_INIT"
        BATT_MOD=$([ "$SEL" = "1" ] && echo 1 || echo 0)
        if [ "$BATT_MOD" = "1" ]; then
            choose "确认: 设备是否已更换 6100mAh 魔改电池?" "否, 改回关闭|是, 确认已更换" 0
            [ "$SEL" = "0" ] && BATT_MOD=0
        fi
    else
        BATT_MOD=0
    fi

    if [ "$BATT_FULL_DTS" -ge 4300 ] && [ "$BATT_FULL_DTS" -le 4570 ]; then
        FULL_DFT_NOTE=" (DTBO 基准 ${BATT_FULL_DTS}mV)"
    else
        FULL_DFT_NOTE=""
    fi
    F_INIT=0; [ "$BATT_FULL_ON" = "1" ] && F_INIT=1
    choose "自定义满充电压 (以 DTBO 基准满充整体偏移)${FULL_DFT_NOTE}:" "关闭 (保持 DTBO 默认)|开启" "$F_INIT"
    BATT_FULL_ON=$([ "$SEL" = "1" ] && echo 1 || echo 0)
    if [ "$BATT_FULL_ON" = "1" ]; then
        FOPTS=""; FINIT=10; i=0; v=4300
        [ "$BATT_FULL" -ge 4300 ] && [ "$BATT_FULL" -le 4570 ] || BATT_FULL=4400
        while [ "$v" -le 4570 ]; do
            MARK=""
            [ "$v" = "$BATT_FULL_DTS" ] && MARK="(原厂)"
            FOPTS="${FOPTS:+$FOPTS|}${v}mV${MARK}"
            [ "$BATT_FULL" = "$v" ] && FINIT=$i
            i=$((i+1)); v=$((v+10))
        done
        choose "满充电压 (4300-4570mV):" "$FOPTS" "$FINIT"
        BATT_FULL=4400; i=0; v=4300
        while [ "$v" -le 4570 ]; do
            [ "$i" = "$SEL" ] && BATT_FULL=$v
            i=$((i+1)); v=$((v+10))
        done
    else
        BATT_FULL=0
    fi
fi

LTPO_INIT=0
[ "$LTPO_OFF" = "1" ] && LTPO_INIT=1
choose "禁用 LTPO 动态刷新率 (防止系统自动降档锁 60Hz):" "保持默认 (保留 LTPO/VRR 自适应)|禁用 (超频档位更稳定, 可能略增耗电)" "$LTPO_INIT"
LTPO_OFF=$([ "$SEL" = "1" ] && echo 1 || echo 0)

echo ""
echo "=============================================="
echo " 方案确认"
echo "  机型: $DEVNAME ($DEVICE)"
if [ "$OC_MODE" = "ko" ]; then
    echo "  方案: KO 内核挂载 (不改DTBO)"
else
    echo "  方案: DTBO 补丁"
fi
if [ "$LTPO_OFF" = "1" ]; then
    echo "  LTPO: 已禁用"
else
    echo "  LTPO: 保持默认"
fi
if [ "$HZ_CHOICE" != "0" ]; then
    echo "  档位: ${HZ_CHOICE}Hz"
else
    echo "  档位: 不超频"
fi
BATT_N=0
if [ "$BATT_LIMIT" = "1" ]; then echo "  充电: 解除充电限流"; BATT_N=$((BATT_N+1)); fi
if [ "$BATT_UNCAP" = "1" ]; then echo "  充电: 电池解容 (关机 ${BATT_VOFF}mV / 1% $((BATT_VOFF+50))mV / 充电中欠压 $((BATT_VOFF-100))mV)"; BATT_N=$((BATT_N+1)); fi
if [ "$BATT_MOD" = "1" ]; then echo "  充电: 魔改电池 6100mAh"; BATT_N=$((BATT_N+1)); fi
if [ "$BATT_FULL_ON" = "1" ]; then echo "  充电: 满充 ${BATT_FULL}mV (基准 $([ "$BATT_FULL_DTS" != "0" ] && echo "${BATT_FULL_DTS}mV" || echo "未识别") 偏移 $([ "$BATT_FULL_DTS" != "0" ] && echo "$((BATT_FULL-BATT_FULL_DTS))mV" || echo "-"))"; BATT_N=$((BATT_N+1)); fi
[ "$BATT_N" = "0" ] && echo "  充电: 相关功能全部关闭 (原版)"
echo "=============================================="
choose "应用方式:" "稍后 (下次开机自动处理)|立即刷入 (重启后生效)" 0
APPLY=$SEL

if [ -f "$CONFIG" ]; then
    sed -i "s/^HZ_CHOICE=.*/HZ_CHOICE=$HZ_CHOICE/;s/^BATT_LIMIT=.*/BATT_LIMIT=$BATT_LIMIT/;s/^BATT_UNCAP=.*/BATT_UNCAP=$BATT_UNCAP/;s/^BATT_VOFF=.*/BATT_VOFF=$BATT_VOFF/;s/^BATT_MOD=.*/BATT_MOD=$BATT_MOD/;s/^BATT_FULL_ON=.*/BATT_FULL_ON=$BATT_FULL_ON/;s/^BATT_FULL=.*/BATT_FULL=$BATT_FULL/;s/^OC_MODE=.*/OC_MODE=$OC_MODE/;s/^LTPO_OFF=.*/LTPO_OFF=$LTPO_OFF/" "$CONFIG" 2>/dev/null || {
        cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATT_LIMIT=$BATT_LIMIT
BATT_UNCAP=$BATT_UNCAP
BATT_VOFF=$BATT_VOFF
BATT_MOD=$BATT_MOD
BATT_FULL_ON=$BATT_FULL_ON
BATT_FULL=$BATT_FULL
OC_MODE=$OC_MODE
LTPO_OFF=$LTPO_OFF
EOF
    }
else
    cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ_CHOICE
BATT_LIMIT=$BATT_LIMIT
BATT_UNCAP=$BATT_UNCAP
BATT_VOFF=$BATT_VOFF
BATT_MOD=$BATT_MOD
BATT_FULL_ON=$BATT_FULL_ON
BATT_FULL=$BATT_FULL
OC_MODE=$OC_MODE
LTPO_OFF=$LTPO_OFF
FLASH=1
BACKUP_PATH=/sdcard/dtbo_backup.img
DTBO_PATH=
EOF
fi

if command -v resetprop >/dev/null 2>&1; then
    if [ "$LTPO_OFF" = "1" ]; then
        resetprop -n persist.oplus.display.vrr 0
        resetprop -n persist.oplus.display.vrr.adfr 0
        resetprop -n debug.oplus.display.dynamic_fps_switch 0
        resetprop -n sys.display.vrr.vote.support 0
        resetprop -n vendor.display.enable_dpps_dynamic_fps 0
        resetprop -n ro.display.brightness.brightness.mode 1
        resetprop -n debug.egl.swapinterval 1
        echo "LTPO 已禁用 (已即时应用, 重启后完全生效)"
    else
        resetprop --delete persist.oplus.display.vrr 2>/dev/null
        resetprop --delete persist.oplus.display.vrr.adfr 2>/dev/null
        resetprop --delete debug.oplus.display.dynamic_fps_switch 2>/dev/null
        resetprop --delete sys.display.vrr.vote.support 2>/dev/null
        resetprop --delete vendor.display.enable_dpps_dynamic_fps 2>/dev/null
        resetprop --delete ro.display.brightness.brightness.mode 2>/dev/null
        resetprop --delete debug.egl.swapinterval 2>/dev/null
        echo "LTPO 已恢复默认 (已即时应用)"
    fi
fi

echo ""
echo "配置已保存: HZ_CHOICE=$HZ_CHOICE 充电相关[限流=$BATT_LIMIT 解容=$BATT_UNCAP(${BATT_VOFF}mV) 魔改=$BATT_MOD 满充=$BATT_FULL_ON($([ "$BATT_FULL_ON" = "1" ] && echo "${BATT_FULL}mV" || echo "-"))] OC_MODE=$OC_MODE LTPO_OFF=$LTPO_OFF"
echo ""
if [ "$APPLY" = "1" ]; then
    echo "正在执行 service.sh ..."
    sh "$MODDIR/service.sh"
    echo "完成。重启后生效。"
else
    echo "下次开机时自动应用"
fi
