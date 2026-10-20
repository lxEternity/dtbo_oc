#!/system/bin/sh
MODDIR=${0%/*}
TOOL="$MODDIR/arm64/dtbo_oc"
DTC="$MODDIR/arm64/dtc"
GUARD="$MODDIR/bin/ko_abi_guard"
DATA_DIR=/data/adb/dtbo_oc
CONFIG="$DATA_DIR/config"
WORK="$DATA_DIR/work"
KOLOG="$DATA_DIR/ko_boot.log"

klog() { echo "$@" >> "$KOLOG"; }

LTPO_OFF=0
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac

if [ "$LTPO_OFF" = "1" ] && command -v resetprop >/dev/null 2>&1; then
    resetprop -n persist.oplus.display.vrr 0
    resetprop -n persist.oplus.display.vrr.adfr 0
    resetprop -n debug.oplus.display.dynamic_fps_switch 0
    resetprop -n sys.display.vrr.vote.support 0
    resetprop -n vendor.display.enable_dpps_dynamic_fps 0
    resetprop -n ro.display.brightness.brightness.mode 1
    resetprop -n debug.egl.swapinterval 1
fi

[ "${OC_MODE:-dtbo}" = "ko" ] || exit 0
[ "${HZ_CHOICE:-0}" != "0" ] || exit 0
[ -x "$TOOL" ] || exit 0

mkdir -p "$DATA_DIR" "$WORK" "$DATA_DIR/ko" "$DATA_DIR/ko_abi"
: > "$KOLOG"
chmod 755 "$TOOL" "$DTC" "$GUARD" 2>/dev/null

LICOUT=$("$TOOL" license 2>/dev/null)
case "$LICOUT" in
    LICENSE=ok*) : ;;
    *)
        klog "[门禁] QQ群验证未通过 ($LICOUT), 跳过 KO 加载"
        klog "[门禁] 请通过 WebUI 或终端菜单完成QQ群验证 (联网验证, 授权30天)"
        exit 0
        ;;
esac

SLOT=$(getprop ro.boot.slot_suffix)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/soc/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        [ -e "$d/$n" ] && DTBO="$d/$n" && break 2
    done
done
[ -z "$DTBO" ] && DTBO=$(ls -d /dev/block/platform/*/by-name/dtbo 2>/dev/null | head -n 1)
if [ -z "$DTBO" ] || ! dd if="$DTBO" of="$WORK/ko_id.img" 2>>"$KOLOG"; then
    klog "[错误] KO预载: 无法读取 dtbo 分区, 放弃开机加载 (service.sh 会再报错)"
    exit 0
fi

IDINFO=$("$TOOL" identify --img "$WORK/ko_id.img" --dtc "$DTC" --workdir "$WORK" 2>>"$KOLOG")
DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
if [ -z "$DEVICE" ]; then
    klog "[错误] KO预载: 机型识别失败, 放弃开机加载"
    exit 0
fi

KO=""
[ -f "$DATA_DIR/ko/$DEVICE.ko" ] && KO="$DATA_DIR/ko/$DEVICE.ko"
[ -z "$KO" ] && [ -f "$MODDIR/ko/$DEVICE.ko" ] && KO="$MODDIR/ko/$DEVICE.ko"
if [ -z "$KO" ]; then
    klog "KO方案: 本机型 ($DEVICE) 无可用 KO, 跳过"
    exit 0
fi

MODNAME=$(strings "$KO" 2>/dev/null | sed -n 's/^name=//p' | head -n 1)
KOVER=$(strings "$KO" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 | cut -d' ' -f1)
KVER=$(uname -r)
if [ -n "$KOVER" ] && [ "$KOVER" != "$KVER" ]; then
    klog "[错误] KO 内核版本不匹配 (KO=$KOVER 系统=$KVER), 拒绝加载"
    klog "[提示] OTA 更新内核后需重新编译 KO, 等待模块更新"
    exit 0
fi

expand_hz() {
    T=$1; L=""
    for t in 130 132 138 141 144 148 150 158 165 170 178 185 190 195 198; do
        [ "$t" -le "$T" ] || continue
        [ "$t" = "198" ] && [ "$T" -lt "195" ] && continue
        L="${L:+$L,}$t"
    done
    echo "$L"
}

DRM_SPECS_FOR() {
    D=$1; H=$2
    LIST=""
    case "$D" in
        gt8p) W=1440; H2=3136 ;;
        op12) W=1440; H2=3168 ;;
        op13) W=1440; H2=3168; LIST="130 132 138 141 144 148 150" ;;
        op15) W=1272; H2=2772; LIST="170 178 185 190 195 198 205" ;;
        *) return 1 ;;
    esac
    if [ -n "$LIST" ]; then
        L=$LIST
    else
        L=$(expand_hz "$H" | tr ',' '\n' | tail -n 8 | tr '\n' ' ')
    fi
    S=""
    for hz in $L; do
        S="${S:+$S;}${W}x${H2}@${hz}"
    done
    [ -n "$S" ] && echo "$S"
}

case "$MODNAME" in
    *_drm_modes)
        ISDRM=1
        ;;
    *) ISDRM=0 ;;
esac

if [ "$ISDRM" = "1" ]; then
    i=0
    while [ "$i" -lt 15 ]; do
        [ -d /sys/module/msm_drm ] && break
        sleep 1
        i=$((i+1))
    done
    [ -d /sys/module/msm_drm ] || { klog "[错误] msm_drm 未就绪, 放弃 DRM-KO 加载"; exit 0; }

    SPECS=$(DRM_SPECS_FOR "$DEVICE" "$HZ_CHOICE")
    [ -z "$SPECS" ] && { klog "[错误] 机型 $DEVICE 不在 DRM-KO 支持表, 跳过"; exit 0; }

    RESOLVED="$KO"
    PLAN=direct
    if [ -x "$GUARD" ]; then
        CONTRACT="$DATA_DIR/ko_abi/contract.txt"
        PROVIDERS="$DATA_DIR/ko_abi/providers.txt"
        "$GUARD" scan --out "$CONTRACT.tmp" --out-providers "$PROVIDERS.tmp" >>"$KOLOG" 2>&1 \
            && mv -f "$CONTRACT.tmp" "$CONTRACT" && mv -f "$PROVIDERS.tmp" "$PROVIDERS"
        if [ -s "$CONTRACT" ]; then
            "$GUARD" check --contract "$CONTRACT" --providers "$PROVIDERS" "$KO" >>"$KOLOG" 2>&1
            CRCRC=$?
            case "$CRCRC" in
                0) PLAN=verified ;;
                3)
                    ADAPT="$DATA_DIR/ko_abi/$(basename "$KO")"
                    if "$GUARD" patch --contract "$CONTRACT" --providers "$PROVIDERS" \
                        --output "$ADAPT" "$KO" >>"$KOLOG" 2>&1; then
                        RESOLVED="$ADAPT"; PLAN=adapted
                    else
                        klog "[错误] KO ABI 适配失败 (CRC 漂移且无法修补), 拒绝加载"; exit 0
                    fi
                    ;;
                *) klog "[错误] KO ABI 校验未通过 (rc=$CRCRC), 拒绝加载"; exit 0 ;;
            esac
        fi
    fi

    case "$DEVICE" in
        gt8p) INSMOD_ARGS="drop_stock_fhd=1 mode_specs=$SPECS phy_profile=stock" ;;
        op12) INSMOD_ARGS="drop_stock_low=1 mode_specs=$SPECS" ;;
        *)    INSMOD_ARGS="mode_specs=$SPECS" ;;
    esac
    klog "加载 DRM-KO ($MODNAME, plan=$PLAN, specs=$SPECS)"
    if ! insmod "$RESOLVED" $INSMOD_ARGS >>"$KOLOG" 2>&1; then
        klog "[错误] DRM-KO insmod 失败 (vermagic=$KOVER)"
        exit 0
    fi
    AP=$(cat "/sys/module/$MODNAME/parameters/applied" 2>/dev/null)
    CA=$(cat "/sys/module/$MODNAME/parameters/cache_applied" 2>/dev/null)
    FC=$(cat "/sys/module/$MODNAME/parameters/failure_code" 2>/dev/null)
    if { [ "$AP" = "Y" ] || [ "$AP" = "1" ]; } && { [ "$CA" = "Y" ] || [ "$CA" = "1" ]; } && [ "$FC" = "0" ]; then
        klog "DRM-KO 注入成功 (applied=Y cache=Y failure=0)"
    else
        klog "[警告] DRM-KO 状态待确认: applied=$AP cache=$CA failure=$FC"
    fi
else
    klog "加载 KO ($MODNAME, PMB110 流程)"
    if ! insmod "$KO" boot_mode=1 >>"$KOLOG" 2>&1; then
        klog "[错误] KO insmod 失败 (vermagic=$KOVER)"
        exit 0
    fi
    echo "$MODNAME" > "$DATA_DIR/ko_loaded"
    i=0 ST=""
    while [ "$i" -lt 15 ]; do
        ST=$(cat "/sys/module/$MODNAME/parameters/status" 2>/dev/null)
        case "$ST" in *captured=1*) break ;; esac
        sleep 1
        i=$((i+1))
    done
    echo 1 > "/sys/module/$MODNAME/parameters/fake_mode" 2>>"$KOLOG" \
        && klog "KO 超频档位已启用 ($ST)" \
        || klog "[警告] KO fake_mode=1 写入失败"
fi
exit 0
