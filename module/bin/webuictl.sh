#!/system/bin/sh
PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:$PATH
export PATH
MODDIR=${0%/*}/..
TOOL="$MODDIR/arm64/dtbo_oc"
MODVER=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
[ -n "$MODVER" ] || MODVER=v0
DTC="$MODDIR/arm64/dtc"
DATA_DIR=/data/adb/dtbo_oc
WORK="$DATA_DIR/work"
CONFIG="$DATA_DIR/config"
STOCK="$DATA_DIR/dtbo_stock.img"
LOG="$DATA_DIR/last_run.log"
SF_LOCK=/data/local/tmp/dtbo_oc_switch.lock
SF_PIN="$DATA_DIR/sf_pin"
SF_OWNS_LOCK=0

json_string() {
    awk 'BEGIN{printf "\""} {if(NR>1) printf "\\n";
        gsub(/\\/,"\\\\"); gsub(/\"/,"\\\"");
        gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); printf "%s",$0}
        END{printf "\""}'
}

fail() {
    printf '{"ok":false,"message":'
    printf '%s' "$1" | json_string
    printf '}\n'
    exit 1
}

cleanup() {
    if [ "$SF_OWNS_LOCK" = 1 ]; then
        rm -f "$SF_LOCK/pid"
        rmdir "$SF_LOCK" 2>/dev/null
    fi
    return 0
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(id -u)" = "0" ] || fail "需要 root 权限"
mkdir -p "$DATA_DIR" "$WORK" "$WORK/ko"
chmod 755 "$TOOL" "$DTC" 2>/dev/null

# ---- 快速路径: apps / ratectl (星驰式刷新率管理) 不依赖机型识别/KO/DTBO/license ----
RC_RATES="$DATA_DIR/rates.conf"
RC_CFG="$DATA_DIR/rc_config.json"
RC_APPS="$DATA_DIR/apps.conf"
RC_PID_FAST="$DATA_DIR/ratectl.pid"
RC_DAEMON_FAST="$MODDIR/bin/ratectl_daemon.sh"

rm_daemon_running() {
    [ -f "$RC_PID_FAST" ] || return 1
    DP=$(cat "$RC_PID_FAST" 2>/dev/null)
    [ -n "$DP" ] || { rm -f "$RC_PID_FAST"; return 1; }
    kill -0 "$DP" 2>/dev/null && return 0
    rm -f "$RC_PID_FAST"
    return 1
}

rm_daemon_restart() {
    # 星驰配置变化后重启守护: 启动时自动 apply 全局锁定档
    rm_daemon_running && kill "$(cat "$RC_PID_FAST")" 2>/dev/null
    rm -f "$RC_PID_FAST"
    [ -x "$RC_DAEMON_FAST" ] || return 1
    nohup sh "$RC_DAEMON_FAST" >/dev/null 2>&1 &
    sleep 0.15
    rm_daemon_running && return 0
    sleep 0.2
    rm_daemon_running
}

rm_daemon_stop() {
    rm_daemon_running && kill "$(cat "$RC_PID_FAST")" 2>/dev/null
    rm -f "$RC_PID_FAST"
    return 0
}

rm_cfg_json() {
    # 输出 rc_config.json 裸字段 (无外层花括号, 供嵌入 rm 对象): globalId/appsw/appintv
    GID=0; ASW=1; AIV=1
    if [ -f "$RC_CFG" ]; then
        v=$(grep -o '"globalRateId"[^0-9]*[0-9]*' "$RC_CFG" 2>/dev/null | grep -o '[0-9]*$')
        case "$v" in ''|*[!0-9]*) v=0 ;; esac
        [ -n "$v" ] && GID=$v
        case "$(grep -o '"appSwitchEnabled"[^a-z]*[a-z]*' "$RC_CFG" 2>/dev/null | grep -oE '(true|false)$')" in
            false) ASW=0 ;; *) ASW=1 ;;
        esac
        i=$(grep -o '"appSwitchInterval"[^0-9]*[0-9]*' "$RC_CFG" 2>/dev/null | grep -o '[0-9]*$')
        case "$i" in ''|*[!0-9]*) i=1 ;; esac
        [ "$i" -ge 1 ] 2>/dev/null && AIV=$i
    fi
    printf '"globalRateId":%s,"appSwitchEnabled":%s,"appSwitchInterval":%s' "$GID" "$([ "$ASW" = "1" ] && echo true || echo false)" "$AIV"
}

rm_cfg_set() {
    # rm_cfg_set global=<n> appsw=<0|1> appintv=<n>
    GID=""; ASW=""; AIV=""
    for kv in "$@"; do
        K=${kv%%=*}; V=${kv#*=}
        case "$K" in
            global) case "$V" in ''|*[!0-9]*) fail "档位ID无效" ;; esac; GID=$V ;;
            appsw)  case "$V" in 0|1) ;; *) fail "appsw 参数无效" ;; esac; ASW=$V ;;
            appintv) case "$V" in ''|*[!0-9]*) fail "间隔无效" ;; esac; [ "$V" -ge 1 ] && [ "$V" -le 30 ] || fail "间隔范围 1-30 秒"; AIV=$V ;;
        esac
    done
    CUR=$(rm_cfg_json)
    [ -z "$GID" ] && GID=$(printf '%s' "$CUR" | grep -o '"globalRateId":[0-9]*' | cut -d: -f2)
    if [ -z "$ASW" ]; then
        case "$CUR" in
            *'"appSwitchEnabled":false'*) ASW=0 ;;
            *) ASW=1 ;;
        esac
    fi
    [ -z "$AIV" ] && AIV=$(printf '%s' "$CUR" | grep -o '"appSwitchInterval":[0-9]*' | cut -d: -f2)
    [ -z "$GID" ] && GID=0
    [ -z "$ASW" ] && ASW=1
    [ -z "$AIV" ] && AIV=1
    printf '{"globalRateId":%s,"appSwitchEnabled":%s,"appSwitchInterval":%s}' "$GID" "$([ "$ASW" = "1" ] && echo true || echo false)" "$AIV" > "$RC_CFG"
}

rm_emit_status() {
    # rm 状态 JSON: rates 数组 + 配置 + 应用规则 + 守护状态
    printf '"rm":{"ready":%s,' "$([ -s "$RC_RATES" ] && echo 1 || echo 0)"
    rm_cfg_json
    printf ',"daemon":%s,"apps":{' "$(rm_daemon_running && echo 1 || echo 0)"
    FIRST=1
    if [ -f "$RC_APPS" ]; then
        while IFS= read -r l; do
            case "$l" in ''|*=*) ;; *) continue ;; esac
            P=${l%%=*}; V=${l#*=}
            case "$P$V" in *[\"\\]*) continue ;; esac
            case "$V" in ''|*[!0-9]*) continue ;; esac
            [ "$FIRST" = "1" ] || printf ','
            printf '"%s":%s' "$P" "$V"
            FIRST=0
        done < "$RC_APPS"
    fi
    printf '},"rates":['
    FIRST=1
    if [ -s "$RC_RATES" ]; then
        awk -F: '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
            type=($5=="overclock")?"overclock":"native"
            base=($6=="1")?1:0
            ord=($7 ~ /^[0-9]+$/)?$7:0
            if (n++) printf ","
            printf "{\"id\":%s,\"w\":%s,\"h\":%s,\"fps\":%s,\"type\":\"%s\",\"base\":%s,\"ord\":%s}", $1,$2,$3,$4,type,base,ord
        }' "$RC_RATES"
    fi
    printf ']}\n'
}

rm_scan_rates() {
    # 星驰式全量扫描: dumpsys SurfaceFlinger 档位表 -> rates.conf
    # 同 id 保留已有 type/base/ord 标注; 每个分辨率保证一个原生基准,
    # 超频档 ord 自动按 fps 升序编号 (开箱即用, 可在子页面修改)
    SCAN=$(timeout -k 1 8 dumpsys SurfaceFlinger 2>/dev/null | grep 'id=[0-9]*, hwcId=')
    [ -n "$SCAN" ] || fail "未读取到档位信息 (请确认屏幕已点亮)"
    printf '%s\n' "$SCAN" | awk '
    function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s);return s}
    {
        id=""; res=""; rate=""
        if (match($0,/id=[0-9]+,/)) { id=substr($0,RSTART+3,RLENGTH-4) }
        if (match($0,/resolution=[0-9]+x[0-9]+/)) { res=substr($0,RSTART+11,RLENGTH-11) }
        if (match($0,/(vsyncRate|refreshRate)=[0-9.]+/)) {
            rate=substr($0,RSTART,RLENGTH); sub(/^[^=]+=/,"",rate)
        }
        if (id=="" || res=="" || rate=="") next
        split(res,xy,"x")
        if (xy[1] !~ /^[0-9]+$/ || xy[2] !~ /^[0-9]+$/) next
        fps=int(rate+0.5)
        if (fps<=0) next
        key=id
        if (!(key in seen)) { seen[key]=1; order[++n]=id; w[id]=xy[1]; h[id]=xy[2]; f[id]=fps }
    }
    END {
        for (i=1;i<=n;i++) {
            id=order[i]
            print id ":" w[id] ":" h[id] ":" f[id] ":native:0:0"
        }
    }' > "$DATA_DIR/rates_scan.raw"
    [ -s "$DATA_DIR/rates_scan.raw" ] || fail "档位解析失败"
    # 合并旧标注
    awk -F: '
    FILENAME ~ /rates_scan/ { nid[$1]=$0; nw[$1]=$2; nh[$1]=$3; nf[$1]=$4; order[++n]=$1; next }
    $1 ~ /^[0-9]+$/ { t[$1]=$5; b[$1]=$6; o[$1]=$7 }
    END {
        for (i=1;i<=n;i++) {
            id=order[i]
            type=(t[id]=="overclock")?"overclock":"native"
            base=(b[id]=="1")?"1":"0"
            ord=(o[id] ~ /^[0-9]+$/)?o[id]:0
            print id ":" nw[id] ":" nh[id] ":" nf[id] ":" type ":" base ":" ord
        }
    }' "$DATA_DIR/rates_scan.raw" "$RC_RATES" > "$DATA_DIR/rates_merge.tmp" 2>/dev/null
    mv -f "$DATA_DIR/rates_merge.tmp" "$RC_RATES"
    rm -f "$DATA_DIR/rates_scan.raw"
    # 每个分辨率保证原生基准: 无 base 时取最高 fps 的 native 档
    awk -F: '
    {
        res=$2"x"$3
        if ($5=="native") {
            if (!(res in bw) || $4>bf[res]) { bw[res]=$1; bf[res]=$4 }
        }
        lines[++n]=$0; res_of[n]=res
    }
    END {
        for (i=1;i<=n;i++) {
            split(lines[i],f,":")
            out=lines[i]
            if (f[5]=="native" && f[6]=="1" && bw[res_of[i]]!=f[1]) {
                out=f[1]":"f[2]":"f[3]":"f[4]":native:0:0"
            } else if (f[5]=="native" && f[6]=="0" && bw[res_of[i]]==f[1]) {
                out=f[1]":"f[2]":"f[3]":"f[4]":native:1:0"
            }
            print out
        }
    }' "$RC_RATES" > "$DATA_DIR/rates_base.tmp"
    mv -f "$DATA_DIR/rates_base.tmp" "$RC_RATES"
    # 超频档 ord 按 fps 升序自动编号 (仅空缺时)
    awk -F: '
    {
        res=$2"x"$3
        lines[++n]=$0
        if ($5=="overclock") { oc_res[n]=res; oc_fps[n]=$4 }
        else oc_res[n]=""
    }
    END {
        # 计算每个分辨率超频档排序位次
        for (i=1;i<=n;i++) if (oc_res[i]!="") {
            k=1
            for (j=1;j<=n;j++) if (oc_res[j]==oc_res[i]) {
                if (oc_fps[j]<oc_fps[i]) k++
                else if (oc_fps[j]==oc_fps[i] && j<i) k++
            }
            ord_of[i]=k
        }
        for (i=1;i<=n;i++) {
            split(lines[i],f,":")
            if (f[5]=="overclock" && f[7]=="0") {
                print f[1]":"f[2]":"f[3]":"f[4]":overclock:"f[6]":"ord_of[i]
            } else print lines[i]
        }
    }' "$RC_RATES" > "$DATA_DIR/rates_ord.tmp"
    mv -f "$DATA_DIR/rates_ord.tmp" "$RC_RATES"
}

case "${1:-}" in
    apps)
        # 应用列表 (含名称, applist.dex): 结果落盘缓存, 二次打开瞬时返回; 过期后台刷新
        AP_CACHE="$DATA_DIR/applist.json"
        if [ -s "$AP_CACHE" ]; then
            printf '{"ok":true,"apps":'
            cat "$AP_CACHE"
            printf '}\n'
            AP_AGE=$(( $(date +%s) - $(stat -c %Y "$AP_CACHE" 2>/dev/null || echo 0) ))
            if [ "$AP_AGE" -gt 600 ]; then
                ( OUT=$(CLASSPATH="$MODDIR/arm64/applist.dex" app_process / AppList 2>/dev/null)
                  if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q '^\['; then
                      printf '%s' "$OUT" > "$AP_CACHE.tmp" 2>/dev/null && mv -f "$AP_CACHE.tmp" "$AP_CACHE"
                  fi ) >/dev/null 2>&1 &
            fi
            exit 0
        fi
        OUT=$(CLASSPATH="$MODDIR/arm64/applist.dex" app_process / AppList 2>/dev/null)
        if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q '^\['; then
            printf '%s' "$OUT" > "$AP_CACHE.tmp" 2>/dev/null && mv -f "$AP_CACHE.tmp" "$AP_CACHE"
            printf '{"ok":true,"apps":%s}\n' "$OUT"
            exit 0
        fi
        # dex 不可用时回退纯包名 (不缓存)
        APPSLIST=$(pm list packages -3 2>/dev/null | sed 's/^package://' | sort)
        [ -n "$APPSLIST" ] || fail "无法获取应用列表"
        printf '{"ok":true,"apps":['
        FIRST=1
        for p in $APPSLIST; do
            case "$p" in *[\"\\]*) continue ;; esac
            [ "$FIRST" = "1" ] || printf ','
            printf '{"p":"%s","n":"%s"}' "$p" "$p"
            FIRST=0
        done
        printf ']}\n'
        exit 0
        ;;
    ratectl)
        # 星驰式刷新率管理: status / scan / global / appsw / app / rates / stop
        shift
        SUB="${1:-}"
        shift 2>/dev/null
        case "$SUB" in
            status)
                printf '{"ok":true,'
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            scan)
                rm_scan_rates
                rm_daemon_restart 2>/dev/null
                printf '{"ok":true,"message":"扫描完成",'
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            global)
                # ratectl global id=<n>|0 ; 0 = 解除锁定并交还系统
                ID="${1:-}"
                ID=${ID#id=}
                case "$ID" in ''|*[!0-9]*) fail "档位ID无效" ;; esac
                if [ "$ID" != "0" ] && [ -s "$RC_RATES" ]; then
                    grep -q "^$ID:" "$RC_RATES" 2>/dev/null || fail "档位 $ID 不在已扫描列表中, 请先扫描"
                fi
                rm_cfg_set global="$ID"
                if [ "$ID" = "0" ]; then
                    # 解除锁定: 交还系统自动调频 + 恢复刷新率上下限
                    rm_daemon_stop
                    service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1
                    rm -f "$DATA_DIR/sf_pin"
                    if [ -s "$DATA_DIR/ratectl.pinbak" ]; then
                        OMIN=$(cut -d' ' -f2 "$DATA_DIR/ratectl.pinbak" 2>/dev/null)
                        OPEAK=$(cut -d' ' -f3 "$DATA_DIR/ratectl.pinbak" 2>/dev/null)
                        if [ "$OMIN" = "-" ]; then settings --user 0 delete system min_refresh_rate 2>/dev/null; else settings --user 0 put system min_refresh_rate "$OMIN" 2>/dev/null; fi
                        if [ "$OPEAK" = "-" ]; then settings --user 0 delete system peak_refresh_rate 2>/dev/null; else settings --user 0 put system peak_refresh_rate "$OPEAK" 2>/dev/null; fi
                        rm -f "$DATA_DIR/ratectl.pinbak"
                    fi
                    MSG="已解除全局锁定, 交还系统自动调频"
                else
                    rm_daemon_restart || MSG="(后台服务启动失败, 将在重启后生效); "
                    MSG="${MSG}已锁定并即时应用"
                fi
                printf '{"ok":true,"message":'
                printf '%s' "$MSG" | json_string
                printf ','
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            appsw)
                rm_cfg_set "$@" 2>/dev/null || rm_cfg_set appsw=1
                rm_daemon_restart 2>/dev/null
                printf '{"ok":true,"message":"已保存",'
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            app)
                ACT="${1:-}"; PKG="${2:-}"; AID="${3:-}"
                case "$ACT" in
                    set)
                        case "$PKG" in ''|*[!a-zA-Z0-9._]*) fail "包名无效" ;; esac
                        case "$AID" in ''|*[!0-9]*) fail "档位ID无效" ;; esac
                        sed -i "\|^$PKG=|d" "$RC_APPS" 2>/dev/null
                        echo "$PKG=$AID" >> "$RC_APPS"
                        rm_daemon_restart 2>/dev/null
                        MSG="已设置 $PKG -> ID $AID"
                        ;;
                    del)
                        case "$PKG" in ''|*[!a-zA-Z0-9._]*) fail "包名无效" ;; esac
                        sed -i "\|^$PKG=|d" "$RC_APPS" 2>/dev/null
                        rm_daemon_restart 2>/dev/null
                        MSG="已移除 $PKG"
                        ;;
                    *) fail "未知子操作" ;;
                esac
                printf '{"ok":true,"message":'
                printf '%s' "$MSG" | json_string
                printf ','
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            rates)
                # ratectl rates "id:w:h:fps:type:base:ord;id:...;..."
                RAW="${1:-}"
                [ -n "$RAW" ] || fail "档位表为空"
                printf '%s' "$RAW" | tr ';' '\n' | awk -F: '
                NF>=7 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ &&
                ($5=="native"||$5=="overclock") && ($6=="0"||$6=="1") && $7 ~ /^[0-9]+$/ {
                    print $1":"$2":"$3":"$4":"$5":"$6":"$7
                }' > "$RC_RATES.tmp"
                [ -s "$RC_RATES.tmp" ] || { rm -f "$RC_RATES.tmp"; fail "档位表格式无效"; }
                mv -f "$RC_RATES.tmp" "$RC_RATES"
                rm_daemon_restart 2>/dev/null
                printf '{"ok":true,"message":"档位配置已保存",'
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            stop)
                rm_cfg_set global=0
                rm_daemon_stop
                service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1
                printf '{"ok":true,"message":"已停止刷新率管理服务",'
                rm_emit_status
                printf '}\n'
                exit 0
                ;;
            *) fail "未知子操作" ;;
        esac
        ;;
esac

SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
DTBO=""
for d in /dev/block/by-name /dev/block/bootdevice/by-name /dev/block/soc/by-name; do
    for n in dtbo "dtbo$SLOT"; do
        [ -e "$d/$n" ] && DTBO="$d/$n" && break 2
    done
done
if [ -z "$DTBO" ]; then
    DTBO=$(ls -d /dev/block/platform/*/by-name/dtbo 2>/dev/null | head -n 1)
    [ -z "$DTBO" ] && DTBO=$(find /dev/block -maxdepth 4 -name 'dtbo*' 2>/dev/null | head -n 1)
fi

DEVICE=""
DEVNAME="未知机型"
MAXRATE=""
CHOICES=""
BATT_OK=0
OC_OK=1
BATT_VOFF_DTS=""
if [ -f "$STOCK" ]; then
    rm -rf "$WORK"/ide* 2>/dev/null
    IDINFO=$("$TOOL" identify --img "$STOCK" --dtc "$DTC" --workdir "$WORK" 2>/dev/null)
    DEVICE=$(echo "$IDINFO" | grep '^DEVICE=' | cut -d= -f2)
    DEVNAME=$(echo "$IDINFO" | grep '^NAME=' | cut -d= -f2)
    MAXRATE=$(echo "$IDINFO" | grep '^MAX_RATE=' | cut -d= -f2)
    BATT_OK=$(echo "$IDINFO" | grep '^BATT_MOD_CAPABLE=' | cut -d= -f2)
    OC_OK=$(echo "$IDINFO" | grep '^OC_CAPABLE=' | cut -d= -f2)
    BATT_VOFF_DTS=$(echo "$IDINFO" | grep '^BATT_VOFF_DTS=' | cut -d= -f2)
fi
[ -z "$BATT_OK" ] && BATT_OK=0
[ -z "$OC_OK" ] && OC_OK=1
case "$DEVICE" in
    op15|op15t|ace6|ace6t|ace6u) MAXRATE=165 ;;
    gt8|gt8p)                     MAXRATE=144 ;;
    ace2pro|op11|op12|op13|op13t|ace5|ace5p|ace3|ace3pro|gt7p|gt7p2|gt7s) MAXRATE=120 ;;
esac
case "$DEVICE" in
    # 原厂120可超185: ACE2Pro (无130)
    ace2pro)   CHOICES="132 138 141 144 150 158 165 170 178 185" ;;
    # 一加13: 引用式克隆 (社区实机验证镜像同款方法, 仅 130/141/144/150 四档)
    op13)      CHOICES="130 141 144 150" ;;
    # 原厂120可超144→放开到150
    op12|op13t|ace5|ace5p|ace3|ace3pro|gt7p2) CHOICES="130 132 138 141 144 148 150" ;;
    # 原厂120可超185: GT7 Pro/GT7S (165实测不开机保留移除)
    gt7s)      CHOICES="130 132 138 141 144 148 150 158 170 178 185" ;;
    # GT7P竞速版 --gt7p 模式实测表
    gt7p)      CHOICES="130 142 144" ;;
    # 原厂144可超185: GT8 Pro
    gt8p)      CHOICES="148 150 158 165 170 178 185 190" ;;
    # 原厂144可超195: GT8
    gt8)       CHOICES="148 150 158 165 170 178 185 190 195 198 205" ;;
    # 原厂165可超185: ACE6T
    ace6t)     CHOICES="170 178 185 190" ;;
    # 原厂165可超195: 一加15/15T/ACE6
    op15|op15t|ace6) CHOICES="170 178 185 190 195 198 205" ;;
    # 原厂165可超185: ACE6至尊版 (DTBO/KO 双方案)
    ace6u)     CHOICES="185" ;;
    op11)      CHOICES="" ;;
esac

# 方案级选项 (与安装脚本 customize.sh 一致): 主页"超频方案"按钮
# 选择任一方案 = 刷入该机型完整档位列表, HZ_CHOICE 仅作为方案标记
PLANS=""
case "$DEVICE" in
    ace2pro)     PLANS="144 165 185" ;;
    op13)        PLANS="144 150" ;;
    op12|op13t|ace5|ace5p|ace3|ace3pro|gt7p2) PLANS="144" ;;
    op15|op15t|ace6) PLANS="185 188 190 195 198" ;;
    gt8)         PLANS="144 165 185 188 190 195 198" ;;
    gt7p)        PLANS="130 142 144" ;;
    gt7s)        PLANS="144 165 185" ;;
    gt8p)        PLANS="165 185" ;;
    ace6t|ace6u) PLANS="185" ;;
esac

HZ=""
OC_MODE=""
LTPO_OFF=""
FLASH=""
BATT_LIMIT=""; BATT_UNCAP=""; BATT_MOD=""; BATT_VOFF=""
if [ -f "$CONFIG" ]; then
    . "$CONFIG"
fi
HZ="${HZ_CHOICE:-}"
[ -z "$HZ" ] && HZ=0
[ -z "$OC_MODE" ] && OC_MODE=dtbo
[ -z "$LTPO_OFF" ] && LTPO_OFF=0
case "$OC_MODE" in dtbo|ko) ;; *) OC_MODE=dtbo ;; esac
case "$LTPO_OFF" in 0|1) ;; *) LTPO_OFF=0 ;; esac
# 充电相关独立开关 (v2.50 全自定义参数)
[ -z "$BATT_LIMIT" ] && BATT_LIMIT=0
[ -z "$BATT_UNCAP" ] && BATT_UNCAP=0
[ -z "$BATT_MOD" ] && BATT_MOD=0
[ -z "$BATT_VOFF" ] && BATT_VOFF=2800
case "$BATT_LIMIT" in 0|1) ;; *) BATT_LIMIT=0 ;; esac
case "$BATT_UNCAP" in 0|1) ;; *) BATT_UNCAP=0 ;; esac
case "$BATT_MOD" in 0|1) ;; *) BATT_MOD=0 ;; esac
case "$BATT_VOFF" in ''|*[!0-9]*) BATT_VOFF=2800 ;; esac
[ "$BATT_VOFF" -lt 2650 ] && BATT_VOFF=2650
[ "$BATT_VOFF" -gt 3150 ] && BATT_VOFF=3150
[ "$BATT_MOD" = "1" ] && [ "$BATT_OK" != "1" ] && BATT_MOD=0
[ -z "$BATT_VOFF_DTS" ] && BATT_VOFF_DTS=0

KO_FILE=""
KO_AVAIL=0
KO_LOADED=0
KO_INSTALLED=0
KO_VERMATCH=""
if [ -n "$DEVICE" ]; then
    KO_FB=""
    for p in "$DATA_DIR/ko/$DEVICE.ko" "$MODDIR/ko/$DEVICE.ko"; do
        if [ -f "$p" ]; then
            KO_AVAIL=1
            [ -z "$KO_FB" ] && KO_FB="$p"
            kv=$(strings "$p" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 | cut -d' ' -f1)
            if [ -n "$kv" ] && [ "$kv" = "$(uname -r)" ]; then KO_FILE="$p"; break; fi
        fi
    done
    [ -z "$KO_FILE" ] && [ -n "$KO_FB" ] && KO_FILE="$KO_FB"
fi
KO_MN=""
if [ -n "$KO_FILE" ]; then
    KO_MN=$(strings "$KO_FILE" 2>/dev/null | sed -n 's/^name=//p' | head -n 1)
fi
[ -z "$KO_MN" ] && KO_MN=$(ls /sys/module 2>/dev/null | grep -E '_185_mode$|_oc_mode$|_drm_modes$' | head -n 1)
if [ -n "$KO_FILE" ]; then
    KOVER=$(strings "$KO_FILE" 2>/dev/null | sed -n 's/^vermagic=//p' | head -n 1 | cut -d' ' -f1)
    if [ -n "$KOVER" ]; then
        if [ "$KOVER" = "$(uname -r)" ]; then KO_VERMATCH="1"; else KO_VERMATCH="0"; fi
    fi
fi
if [ -n "$KO_MN" ] && [ -d "/sys/module/$KO_MN" ]; then
    KO_LOADED=1
    case "$KO_MN" in
        *_drm_modes)
            AP=$(cat "/sys/module/$KO_MN/parameters/applied" 2>/dev/null)
            FC=$(cat "/sys/module/$KO_MN/parameters/failure_code" 2>/dev/null)
            { [ "$AP" = "Y" ] || [ "$AP" = "1" ]; } && [ "$FC" = "0" ] && KO_INSTALLED=1
            ;;
        *)
            KST=$(cat "/sys/module/$KO_MN/parameters/status" 2>/dev/null)
            case "$KST" in *installed=1*) KO_INSTALLED=1 ;; esac
            ;;
    esac
fi

DTBO_PATCHED=0
if [ -n "$DTBO" ] && [ -f "$STOCK" ]; then
    dd if="$DTBO" of="$WORK/web_cur.img" 2>/dev/null
    cmp -s "$WORK/web_cur.img" "$STOCK" || DTBO_PATCHED=1
fi

LIC_STATE="none"; LIC_QQ=""; LIC_EXP=""
lic_query() {
    LIC_STATE="none"; LIC_QQ=""; LIC_EXP=""
    [ -x "$TOOL" ] || return 0
    L=$("$TOOL" license 2>/dev/null) || L=""
    case "$L" in
        LICENSE=ok*)
            LIC_STATE="ok"
            LIC_QQ=$(printf '%s\n' "$L" | sed -n 's/^LICENSE=ok QQ=\([0-9]*\) .*/\1/p')
            LIC_EXP=$(printf '%s\n' "$L" | sed -n 's/.*EXPIRY_DATE=//p')
            ;;
        LICENSE=expired*)
            LIC_STATE="expired"
            LIC_QQ=$(printf '%s\n' "$L" | sed -n 's/^LICENSE=expired QQ=\([0-9]*\) .*/\1/p')
            LIC_EXP=$(printf '%s\n' "$L" | sed -n 's/.*EXPIRY_DATE=//p')
            ;;
        LICENSE=wrongmachine*) LIC_STATE="wrongmachine" ;;
        LICENSE=bad*) LIC_STATE="bad" ;;
    esac
    return 0
}
lic_query
MACHINE=""
[ -x "$TOOL" ] && MACHINE=$("$TOOL" machineid 2>/dev/null | sed -n 's/^MACHINE=//p')

# 钉住/恢复系统刷新率设置 (min/peak_refresh_rate): 防止系统 ADFR 与锁定档位来回拉锯
# 备份文件格式: "<boot_id> <原min> <原peak>", "-" 表示原值为空 (恢复时删除键)
w_pin_bak() {
    [ -s "$DATA_DIR/ratectl.pinbak" ] && return 0
    OMIN=$(settings --user 0 get system min_refresh_rate 2>/dev/null)
    OPEAK=$(settings --user 0 get system peak_refresh_rate 2>/dev/null)
    case "$OMIN" in ''|null) OMIN="-" ;; esac
    case "$OPEAK" in ''|null) OPEAK="-" ;; esac
    printf '%s %s %s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" "$OMIN" "$OPEAK" > "$DATA_DIR/ratectl.pinbak" 2>/dev/null
    return 0
}
w_pin_hz() {
    w_pin_bak
    settings --user 0 put system min_refresh_rate "$1" 2>/dev/null
    settings --user 0 put system peak_refresh_rate "$1" 2>/dev/null
    return 0
}
w_pin_restore() {
    [ -s "$DATA_DIR/ratectl.pinbak" ] || return 0
    OMIN=$(cut -d' ' -f2 "$DATA_DIR/ratectl.pinbak" 2>/dev/null)
    OPEAK=$(cut -d' ' -f3 "$DATA_DIR/ratectl.pinbak" 2>/dev/null)
    if [ "$OMIN" = "-" ]; then settings --user 0 delete system min_refresh_rate 2>/dev/null; else settings --user 0 put system min_refresh_rate "$OMIN" 2>/dev/null; fi
    if [ "$OPEAK" = "-" ]; then settings --user 0 delete system peak_refresh_rate 2>/dev/null; else settings --user 0 put system peak_refresh_rate "$OPEAK" 2>/dev/null; fi
    rm -f "$DATA_DIR/ratectl.pinbak"
    return 0
}

sf_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

sf_pin_active() {
    [ -f "$SF_PIN" ] || return 1
    PIN_BOOT=$(cut -d' ' -f1 "$SF_PIN" 2>/dev/null)
    [ "$PIN_BOOT" = "$(sf_boot_id)" ] || { rm -f "$SF_PIN"; return 1; }
    return 0
}

sf_capture() {
    timeout -k 1 4 dumpsys -t 3 SurfaceFlinger --displays > "$WORK/sf_displays.txt" 2>&1 || return 1
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
    ' "$WORK/sf_displays.txt" > "$WORK/sf_modes.txt" || return 1
    [ -s "$WORK/sf_modes.txt" ] || return 1
    SF_DISPLAY=$(awk -F'|' '$1=="D"{print $2}' "$WORK/sf_modes.txt")
    SF_POWER=$(awk -F'|' '$1=="D"{print $3}' "$WORK/sf_modes.txt")
    SF_RENDER=$(awk -F'|' '$1=="D"{print $4}' "$WORK/sf_modes.txt")
    SF_AID=$(awk -F'|' '$1=="A"{print $2}' "$WORK/sf_modes.txt")
    [ -n "$SF_DISPLAY" ] && [ -n "$SF_AID" ] || return 1
    return 0
}

sf_send() {
    timeout -k 1 4 service call SurfaceFlinger 1035 i32 "$1" i64 "$SF_DISPLAY" >/dev/null 2>&1
}

sf_lock() {
    if ! mkdir "$SF_LOCK" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$$" > "$SF_LOCK/pid" 2>/dev/null || { rmdir "$SF_LOCK" 2>/dev/null; return 1; }
    SF_OWNS_LOCK=1
    return 0
}

sf_release_quiet() {
    if sf_pin_active; then
        sf_capture 2>/dev/null && sf_send -1
        rm -f "$SF_PIN"
    fi
}

emit_display_json() {
    AG=$(awk -F'|' '$1=="A"{print $6}' "$WORK/sf_modes.txt")
    AW=$(awk -F'|' '$1=="A"{print $3}' "$WORK/sf_modes.txt")
    AH=$(awk -F'|' '$1=="A"{print $4}' "$WORK/sf_modes.txt")
    AHZ=$(awk -F'|' '$1=="A"{print $5}' "$WORK/sf_modes.txt")
    RR=$(awk -v v="$SF_RENDER" 'BEGIN{printf "%.2f", v+0}')
    AHZI=$(awk -v v="$AHZ" 'BEGIN{printf "%d", int(v+0.5)}')
    if sf_pin_active; then PINNED=1; else PINNED=0; fi
    printf '"sf":{"ok":true,"power":"%s","render_hz":%s,"pinned":%s,' "$SF_POWER" "$RR" "$PINNED"
    printf '"active":{"id":%s,"w":%s,"h":%s,"hz":%s,"group":%s},' "$SF_AID" "$AW" "$AH" "$AHZI" "$AG"
    awk -F'|' -v agr="$AG" '
    $1=="M" {
        key=$3"x"$4"@"int($5+0.5)
        if (!(key in best)) { best[key]=$0; keys[++n]=key; next }
        split(best[key], b, "|")
        if ($6==agr && b[6]!=agr) best[key]=$0
    }
    END { for (i=1;i<=n;i++) print best[keys[i]] }
    ' "$WORK/sf_modes.txt" > "$WORK/sf_dedup.txt"
    printf '"modes":['
    awk -F'|' '{ if (n++) printf ","; printf "{\"id\":%s,\"w\":%s,\"h\":%s,\"hz\":%d,\"group\":%s}", $2,$3,$4,int($5+0.5),$6 }' "$WORK/sf_dedup.txt"
    printf ']}'
}

emit_status() {
    CHOICES_JSON=$(echo "$CHOICES" | tr ' ' ',' | sed 's/^,$//;s/,$//')
    PLANS_JSON=$(echo "$PLANS" | tr ' ' ',' | sed 's/^,$//;s/,$//')
    OC_ACTIVE=0
    if [ "$OC_MODE" = "ko" ]; then
        [ "$KO_LOADED" = "1" ] && OC_ACTIVE=1
    elif [ "$HZ" != "0" ] && [ -n "$HZ" ] && [ "$DTBO_PATCHED" = "1" ]; then
        OC_ACTIVE=1
    fi
    KO_BUILTIN=0
    [ -n "$DEVICE" ] && [ -f "$MODDIR/ko/$DEVICE.ko" ] && KO_BUILTIN=1
    printf '{"ok":true,"device":"%s","name":' "$DEVICE"
    printf '%s' "$DEVNAME" | json_string
    printf ',"maxrate":"%s","choices":[%s],"plans":[%s],"oc_capable":%s,"batt_capable":%s,' "$MAXRATE" "$CHOICES_JSON" "$PLANS_JSON" "$OC_OK" "$BATT_OK"
    printf '"hz":%s,"oc_mode":"%s","ltpo_off":%s,' "$HZ" "$OC_MODE" "$LTPO_OFF"
    printf '"batt":{"limit":%s,"uncap":%s,"voff":%s,"mod":%s,"voff_dts":%s},' \
        "$BATT_LIMIT" "$BATT_UNCAP" "$BATT_VOFF" "$BATT_MOD" "$BATT_VOFF_DTS"
    printf '"oc_active":%s,' "$OC_ACTIVE"
    printf '"rm_ready":%s,' "$([ -s "$DATA_DIR/rates.conf" ] && echo 1 || echo 0)"
    printf '"ko":{"available":%s,"builtin":%s,"loaded":%s,"installed":%s,"vermatch":%s,"file":' "$KO_AVAIL" "$KO_BUILTIN" "$KO_LOADED" "$KO_INSTALLED" "${KO_VERMATCH:-null}"
    printf '%s' "${KO_FILE:-}" | json_string
    printf '},"dtbo_patched":%s,"stock_ok":%s,"version":"%s","machine":' "$DTBO_PATCHED" "$([ -f "$STOCK" ] && echo 1 || echo 0)" "$MODVER"
    printf '%s' "$MACHINE" | json_string
    printf ',"license":{"state":"%s","qq":' "$LIC_STATE"
    printf '%s' "$LIC_QQ" | json_string
    printf ',"expiry":'
    printf '%s' "$LIC_EXP" | json_string
    printf '}'
    if sf_capture 2>/dev/null; then
        printf ','
        emit_display_json
    else
        printf ',"sf":{"ok":false}'
    fi
    printf '}\n'
}

batt_active() {
    [ "$BATT_LIMIT" = "1" ] && return 0
    [ "$BATT_UNCAP" = "1" ] && return 0
    [ "$BATT_MOD" = "1" ] && return 0
    return 1
}

set_config_val() {
    sed -i "s|^$1=.*|$1=$2|" "$CONFIG" 2>/dev/null
    grep -q "^$1=" "$CONFIG" || echo "$1=$2" >> "$CONFIG"
}

ltpo_apply() {
    command -v resetprop >/dev/null 2>&1 || return 1
    if [ "$LTPO_OFF" = "1" ]; then
        resetprop -n persist.oplus.display.vrr 0
        resetprop -n persist.oplus.display.vrr.adfr 0
        resetprop -n debug.oplus.display.dynamic_fps_switch 0
        resetprop -n sys.display.vrr.vote.support 0
        resetprop -n vendor.display.enable_dpps_dynamic_fps 0
        resetprop -n ro.display.brightness.brightness.mode 1
        resetprop -n debug.egl.swapinterval 1
    else
        resetprop --delete persist.oplus.display.vrr 2>/dev/null
        resetprop --delete persist.oplus.display.vrr.adfr 2>/dev/null
        resetprop --delete debug.oplus.display.dynamic_fps_switch 2>/dev/null
        resetprop --delete sys.display.vrr.vote.support 2>/dev/null
        resetprop --delete vendor.display.enable_dpps_dynamic_fps 2>/dev/null
        resetprop --delete ro.display.brightness.brightness.mode 2>/dev/null
        resetprop --delete debug.egl.swapinterval 2>/dev/null
    fi
    return 0
}

emit_result_with_sf() {
    printf '{"ok":true,"message":'
    printf '%s' "$1" | json_string
    printf ','
    emit_display_json
    printf '}\n'
}

case "${1:-}" in
    status)
        emit_status
        ;;
    save)
        shift
        MSG=""
        for kv in "$@"; do
            K=${kv%%=*}
            V=${kv#*=}
            case "$K" in
                hz)
                    OK=0
                    [ "$V" = "0" ] && OK=1
                    for c in $CHOICES $PLANS; do [ "$V" = "$c" ] && OK=1; done
                    [ "$OK" = "1" ] || fail "档位 $V 不适用于本机型"
                    HZ="$V"
                    ;;
                batt_limit)
                    case "$V" in 0|1) BATT_LIMIT="$V" ;; *) fail "解除充电限流参数无效" ;; esac
                    ;;
                batt_uncap)
                    case "$V" in 0|1) BATT_UNCAP="$V" ;; *) fail "电池解容参数无效" ;; esac
                    ;;
                batt_voff)
                    case "$V" in ''|*[!0-9]*) fail "关机电压无效" ;; esac
                    [ "$V" -ge 2650 ] && [ "$V" -le 3150 ] || fail "关机电压范围 2650-3150mV"
                    BATT_VOFF="$V"
                    ;;
                batt_mod)
                    case "$V" in 0|1) BATT_MOD="$V" ;; *) fail "魔改电池参数无效" ;; esac
                    [ "$BATT_MOD" = "1" ] && [ "$BATT_OK" != "1" ] && fail "魔改电池仅 ACE2Pro/一加11/一加12 支持"
                    ;;
                oc_mode)
                    case "$V" in dtbo|ko) OC_MODE="$V" ;; *) fail "未知超频方案 $V" ;; esac
                    ;;
                ltpo_off)
                    case "$V" in 0|1) LTPO_OFF="$V" ;; *) fail "LTPO 参数无效" ;; esac
                    ;;
            esac
        done
        if [ "$OC_MODE" = "ko" ] && [ "$KO_AVAIL" != "1" ]; then
            MSG="${MSG}未找到 KO ($DEVICE.ko), 侧载到 /data/adb/dtbo_oc/ko/ 后重启生效; "
        fi
        if [ "$OC_MODE" = "ko" ] && batt_active; then
            BATT_LIMIT=0; BATT_UNCAP=0; BATT_MOD=0
            MSG="KO 方案不修改 DTBO, 充电相关功能已全部关闭; "
        fi
        if [ ! -f "$CONFIG" ]; then
            cat > "$CONFIG" <<EOF
HZ_CHOICE=$HZ
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
        else
            set_config_val HZ_CHOICE "$HZ"
            set_config_val BATT_LIMIT "$BATT_LIMIT"
            set_config_val BATT_UNCAP "$BATT_UNCAP"
            set_config_val BATT_VOFF "$BATT_VOFF"
            set_config_val BATT_MOD "$BATT_MOD"
            set_config_val OC_MODE "$OC_MODE"
            set_config_val LTPO_OFF "$LTPO_OFF"
        fi
        if ltpo_apply; then
            if [ "$LTPO_OFF" = "1" ]; then
                MSG="${MSG}LTPO 已禁用 (已即时应用); "
            else
                MSG="${MSG}LTPO 已恢复默认 (已即时应用); "
            fi
        fi
        printf '{"ok":true,"message":'
        printf '%s' "${MSG}配置已保存" | json_string
        printf '}\n'
        ;;
    apply)
        NEED_OC=0
        [ "$HZ" != "0" ] && [ -n "$HZ" ] && NEED_OC=1
        batt_active && NEED_OC=1
        if [ "$NEED_OC" = "1" ] && [ "$LIC_STATE" != "ok" ]; then
            fail "请先完成QQ群验证 (输入QQ号联网验证, 授权30天), 未验证不修改 DTBO / 不挂载 KO"
        fi
        sf_release_quiet
        sh "$MODDIR/service.sh" > "$WORK/webui_apply.log" 2>&1
        RC=$?
        TAIL=$(tail -n 6 "$WORK/webui_apply.log" 2>/dev/null | tr '\n' ' ' | cut -c1-400)
        printf '{"ok":%s,"rc":%s,"message":' "$([ $RC -eq 0 ] && echo true || echo false)" "$RC"
        printf '%s' "$TAIL" | json_string
        printf '}\n'
        ;;
    restore)
        sf_release_quiet
        # 星驰: 停止刷新率守护并解除全局锁定 (交还系统自动调频)
        if [ -s "$RC_CFG" ]; then
            sed -i 's/"globalRateId":[0-9]*/"globalRateId":0/' "$RC_CFG" 2>/dev/null
        fi
        rm_daemon_stop
        service call SurfaceFlinger 1035 i32 -1 >/dev/null 2>&1
        rm -f "$SF_PIN"
        MODNM=""
        if [ -f "$DATA_DIR/ko_loaded" ]; then
            MODNM=$(cat "$DATA_DIR/ko_loaded" 2>/dev/null)
        fi
        [ -z "$MODNM" ] && MODNM=$(ls /sys/module 2>/dev/null | grep -E '_185_mode$|_oc_mode$' | head -n 1)
        if [ -n "$MODNM" ] && [ -d "/sys/module/$MODNM" ]; then
            case "$MODNM" in
                *_drm_modes) ;;
                *)
                    echo 0 > "/sys/module/$MODNM/parameters/fake_mode" 2>/dev/null
                    rmmod "$MODNM" 2>/dev/null
                    ;;
            esac
        fi
        rm -f "$DATA_DIR/ko_loaded"
        RESTORED=0
        if [ -n "$DTBO" ] && [ -f "$STOCK" ]; then
            if dd if="$STOCK" of="$DTBO" 2>/dev/null; then
                sync
                RESTORED=1
            fi
        fi
        if [ -f "$CONFIG" ]; then
            sed -i 's/^HZ_CHOICE=.*/HZ_CHOICE=0/;s/^BATT_LIMIT=.*/BATT_LIMIT=0/;s/^BATT_UNCAP=.*/BATT_UNCAP=0/;s/^BATT_MOD=.*/BATT_MOD=0/;/^BATT_FULL_ON=/d;/^BATT_FULL=/d;s/^LTPO_OFF=.*/LTPO_OFF=0/' "$CONFIG"
        fi
        LTPO_OFF=0
        ltpo_apply 2>/dev/null
        printf '{"ok":%s,"message":' "$([ $RESTORED -eq 1 ] && echo true || echo false)"
        printf '%s' "已恢复原厂 DTBO, KO 停止加载 (重启后完全移除), LTPO 已恢复默认, 配置已重置为不超频" | json_string
        printf '}\n'
        ;;
    switch)
        ID="${2:-}"
        case "$ID" in
            hz=*)
                WANTHZ=${ID#hz=}
                case "$WANTHZ" in ''|*[!0-9]*) fail "档位无效" ;; esac
                sf_capture || fail "无法读取当前显示状态 (若连接了外接显示请断开后重试)"
                [ "$SF_POWER" = "On" ] || fail "请先点亮并解锁屏幕"
                AGRP=$(awk -F'|' '$1=="A"{print $6}' "$WORK/sf_modes.txt")
                ID=$(awk -F'|' -v hz="$WANTHZ" -v g="$AGRP" '$1=="M" && int($5+0.5)==hz && $6==g {print $2; exit}' "$WORK/sf_modes.txt")
                [ -n "$ID" ] || fail "当前无 ${WANTHZ}Hz 档位 (修改DTBO并重启后可用)"
                ;;
            ''|*[!0-9]*) fail "档位 ID 无效" ;;
        esac
        sf_capture || fail "无法读取当前显示状态 (若连接了外接显示请断开后重试)"
        [ "$SF_POWER" = "On" ] || fail "请先点亮并解锁屏幕"
        sf_lock || fail "已有切换任务进行中, 请稍后重试"
        awk -F'|' -v id="$ID" '$1=="M" && $2==id {f=1} END{exit !f}' "$WORK/sf_modes.txt" || fail "所选档位不存在, 请刷新后重试"
        OLD="$SF_AID"
        THZ=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print int($5+0.5)}' "$WORK/sf_modes.txt")
        if [ "$ID" = "$OLD" ]; then
            w_pin_hz "$THZ"
            emit_result_with_sf "系统已处于所选档位"
            exit 0
        fi
        TW=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print $3}' "$WORK/sf_modes.txt")
        TH=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print $4}' "$WORK/sf_modes.txt")
        THZ=$(awk -F'|' -v id="$ID" '$1=="M"&&$2==id{print int($5+0.5)}' "$WORK/sf_modes.txt")
        sf_send "$ID" || fail "切换指令发送失败 (本机系统可能不支持在线切换)"
        OK=0
        TRY=0
        while [ "$TRY" -lt 3 ]; do
            sleep 0.4
            if sf_capture && [ "$SF_POWER" = "On" ] && [ "$SF_AID" = "$ID" ]; then
                AW2=$(awk -F'|' '$1=="A"{print $3}' "$WORK/sf_modes.txt")
                AH2=$(awk -F'|' '$1=="A"{print $4}' "$WORK/sf_modes.txt")
                AHZ2=$(awk -F'|' '$1=="A"{print int($5+0.5)}' "$WORK/sf_modes.txt")
                if [ "$AW2" = "$TW" ] && [ "$AH2" = "$TH" ] && [ "$AHZ2" = "$THZ" ]; then OK=1; break; fi
            fi
            TRY=$((TRY+1))
        done
        if [ "$OK" != "1" ]; then
            sf_capture 2>/dev/null && sf_send "$OLD"
            sf_capture 2>/dev/null && sf_send -1
            fail "系统未确认所选档位, 已请求还原并交还系统自动切换"
        fi
        printf '%s %s\n' "$(sf_boot_id)" "$ID" > "$SF_PIN"
        w_pin_hz "$THZ"
        emit_result_with_sf "已切换并经系统确认; 系统自动调频已暂停, 点交还可恢复"
        ;;
    release)
        sf_capture || fail "无法读取当前显示状态"
        sf_lock || fail "已有切换任务进行中, 请稍后重试"
        sf_send -1 || fail "交还指令发送失败 (本机系统可能不支持)"
        rm -f "$SF_PIN"
        if [ -s "$RC_CFG" ]; then
            sed -i 's/"globalRateId":[0-9]*/"globalRateId":0/' "$RC_CFG" 2>/dev/null
        fi
        rm_daemon_stop
        w_pin_restore
        sleep 0.4
        sf_capture 2>/dev/null
        emit_result_with_sf "已交还系统自动切换; 若停留在低档位, 亮屏点按屏幕即可恢复调频"
        ;;
    log)
        printf '{"ok":true,"log":'
        { tail -n 30 "$LOG" 2>/dev/null; echo "--- ko_boot.log ---"; tail -n 20 "$DATA_DIR/ko_boot.log" 2>/dev/null; } | json_string
        printf '}\n'
        ;;
    verify)
        shift
        QQ=""; AUTO=0
        for kv in "$@"; do
            K=${kv%%=*}
            case "$K" in
                qq) QQ=${kv#*=} ;;
                auto) AUTO=1 ;;
            esac
        done
        if [ "$AUTO" = "1" ]; then
            VOUT=$("$TOOL" verify --auto 2>"$WORK/verify_err.txt")
        else
            case "$QQ" in ''|*[!0-9]*|0*) fail "QQ号格式无效 (5-11位数字, 不以0开头)" ;; esac
            QL=${#QQ}
            if [ "$QL" -lt 5 ] || [ "$QL" -gt 11 ]; then fail "QQ号长度应为 5-11 位"; fi
            VOUT=$("$TOOL" verify --qq "$QQ" 2>"$WORK/verify_err.txt")
        fi
        VRC=$?
        if [ "$VRC" = "0" ]; then
            lic_query
            printf '{"ok":true,"message":"验证成功","license":{"state":"%s","qq":' "$LIC_STATE"
            printf '%s' "$LIC_QQ" | json_string
            printf ',"expiry":'
            printf '%s' "$LIC_EXP" | json_string
            printf '}}\n'
            exit 0
        fi
        REASON=$(printf '%s\n' "$VOUT" | sed -n 's/.*REASON=//p')
        case "$REASON" in
            bad_qq)          fail "QQ号格式无效 (5-11位数字, 不以0开头)" ;;
            not_in_group)    if [ "$AUTO" = "1" ]; then fail "本机QQ均不在群成员名单中; 请先加入QQ群, 加群后需等待群主同步名单"; else fail "该QQ号不在群成员名单中; 请先加入QQ群, 加群后需等待群主同步名单"; fi ;;
            not_in_group_cached) fail "联网刷新群名单失败, 本地缓存名单中暂无该QQ; 名单可能已更新, 请检查网络后重试" ;;
            no_local_qq)     fail "未在本机检测到QQ/TIM账号, 请手动输入QQ号验证" ;;
            machine_not_allowed)
                VMID=$(printf '%s\n' "$VOUT" | sed -n 's/.*MACHINE=//p')
                fail "该QQ绑定的设备数量已达上限, 本机未在授权列表; 主板ID: ${VMID:-未知}, 请群主在名单该QQ行追加此机器码" ;;
            list_invalid)    fail "云端群成员名单无效 (缺少群号标识), 请联系群主" ;;
            download_failed) fail "无法联网获取群成员名单, 请检查网络后重试" ;;
            write_failed)    fail "授权写入失败, 请重试" ;;
            *)               fail "验证失败, 请稍后重试" ;;
        esac
        ;;
    *)
        fail "未知操作"
        ;;
esac
