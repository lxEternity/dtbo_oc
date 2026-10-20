#!/bin/bash
# 全机型矩阵测试: 识别 + 按目标 patch + 汇总
cd /workspace/DTBO_OC_Module/test
U=/workspace/.uploads
T=./dtbo_oc_host
DTC=./dtc
PASS=0; FAIL=0

run_case() { # $1=镜像 $2=名称 $3=hz(空=无) $4=附加参数 $5=备注
    local img="$1" name="$2" hz="$3" extra="$4" note="$5"
    local wd="tw_${name}"; rm -rf "$wd"; mkdir -p "$wd"
    # 文件名可能含空格: 复制为简单名
    cp "$img" "$wd/in.img"
    local idout=$($T identify --img "$wd/in.img" --dtc $DTC --workdir "$wd" 2>/dev/null)
    local dev=$(echo "$idout" | grep '^DEVICE=' | cut -d= -f2)
    local strip=$(echo "$idout" | grep '^STRIP_ABOVE=' | cut -d= -f2)
    [ -z "$strip" ] && strip=0
    local out="tp_${name}.img"
    local args="--img $wd/in.img --out $out --dtc $DTC --workdir $wd $extra"
    [ -n "$hz" ] && args="$args --hz $hz"
    [ "$strip" != "0" ] && args="$args --strip-above $strip"
    $T patch $args > "tl_${name}.log" 2>&1
    local rc=$?
    local done_line=$(grep -E "^\[DONE\]" "tl_${name}.log" | tail -1)
    if [ $rc -eq 0 ] || [ $rc -eq 3 ]; then
        echo "PASS $name dev=$dev rc=$rc $done_line [$note]"
        PASS=$((PASS+1))
    else
        echo "FAIL $name dev=$dev rc=$rc [$note]"
        grep -E "FATAL|ERROR" "tl_${name}.log" | head -3
        FAIL=$((FAIL+1))
    fi
}

G144="130,132,138,141,144,148,150"                                        # 原厂120→150
G185="148,150,158,165,170,178,185,190"                                    # 原厂144→190
G195="170,178,185,190,195,198,205"                                        # 原厂165→205
G205="148,150,158,165,170,178,185,190,195,198,205"                        # 原厂144→205 (GT8)

run_case "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pro_185 "132,138,141,144,150,158,165,170,178,185" "" "ACE2Pro无130"
run_case "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pro_batt "132,138,141,144,150,158,165,170,178,185" "--battery 2" "185+解容限流"
run_case "$U/a46c7974-e65b-42e7-bbcf-e91794771505_一加_13T_17.0.0.104_dtbo.img" op13t "$G144" "--multifam --min-clone" "13T双家族"
run_case "$U/4bc3da55-6c91-47d6-8526-0704189d1019_一加13t可超144.dtbo.img" op13t_old "$G144" "--multifam" "13T旧镜像"
run_case "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15_195 "$G195" "--min-clone" "一加15目标205"
run_case "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15_batt "$G195" "--battery 2 --min-clone" "一加15+解容"
run_case "$U/d9f85ea1-86d4-4d89-a8bc-22be7022f0d3_一加15.dtbo.img" op15_old "$G195" "--min-clone" "一加15旧镜像"
run_case "$U/a1f05034-d8db-4d74-bb53-eab9df2f6e49_一加15t可超195.dtbo.img" op15t "$G195" "--min-clone" "备注195→205"
run_case "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6 "$G195" "--min-clone" "ACE6 205"
run_case "$U/0bb81094-120b-4f24-a48d-ecce4e50f366_一加ace6t可超频185.dtbo.img" ace6t "170,178,185,190" "--min-clone" "ACE6T 190"
run_case "$U/e207c7a7-aa6f-42af-9edf-6619f3c651d2_一加ace6至尊.可超频195+解容+移除充电限流dtbo.img" ace6u "185" "" "MTK KO 185"
run_case "$U/59c8eba7-c34b-46ce-bbd3-3fdad67c0b5b_一加ace3pro可超144.dtbo.img" ace3pro "$G144" "--min-clone" "动态时序"
run_case "$U/8836604a-7fce-4deb-919f-b440101bf631_一加ace3可超144.dtbo.img" ace3 "$G144" "--min-clone" "动态时序"
run_case "$U/b527a8e3-eae6-4264-9e09-32748a7c0d08_一加Ace5可超144.dtbo.img" ace5 "$G144" "--min-clone" "备注144"
run_case "$U/546a08d5-f25e-48be-9ed5-386c4658ee2f_ace5pro.可超频144.dtbo.img" ace5p "$G144" "--min-clone" "Sun平台"
run_case "$U/31897c63-f086-417a-960f-1e4812be6755_一加13.dtbo.img" op13 "$G144" "--include-family wqhd_sdc --min-clone" "2K全套150"
run_case "$U/798682e4-4ade-4645-b3c4-dc5f2c3527b7_一加12可超144.dtbo_a.img" op12 "$G144" "--multifam --min-clone" "AA545双供应商族"
run_case "$U/395c2b85-214a-4857-b007-24cdcd555b4f_一加11不可超频，可解容+移除充电限流.dtbo.img" op11_batt "" "--battery 2" "一加11仅解容"
run_case "$U/83ae6eb4-3f9e-4248-bdb0-89f90cf06007_真我gt8.dtbo.img" gt8 "$G205" "--min-clone" "GT8 144→205"
run_case "$U/a547f0f9-dea0-443b-abec-38a2f214734e_真我gt8pro可超频185.dtbo.img" gt8p "$G185" "--min-clone" "144基准→190"
run_case "$U/c64d3c24-bd71-4dd9-a920-6edc6752b070_真我GT7 Pro可超185dtbo.img" gt7s "130,132,138,141,144,148,150,158,170,178,185" "--gt7s" "GT7P同镜像165实测不开机移除"
run_case "$U/fe1fffd6-3d36-425f-a8bd-a503ee7fadba_真我gt7Pro竞速版.可超频144.dtbo.img" gt7p2 "$G144" "--battery 2 --gt7p2 --min-clone" "AC180面板120基准超150"
run_case "$U/2255da35-e279-450d-8292-af0112c8dbd4_真我GT7Pro竞速版已修改dtbo.img" gt7p "130,142,144" "--gt7p" "GT7P实测表"

echo "==== PASS=$PASS FAIL=$FAIL ===="
