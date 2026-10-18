#!/bin/bash
# 新旧逻辑全矩阵对比: 旧输出保存为 *_old.img, 新输出 tp_*.img, 逐一 cmp
U=/workspace/.uploads
OLDD=~/old_out; NEWD=~/new_out
mkdir -p $OLDD $NEWD
G144="130,132,138,141,144"; G165="130,132,138,141,144,148,150,158,165"
G185="130,132,138,141,144,148,150,158,165,170,178,185"
G195="130,132,138,141,144,148,150,158,165,170,178,185,190,195,198"
run_case() {
    local img="$1" name="$2" hz="$3" extra="$4"
    for side in old new; do
        local wd="cw_${name}_${side}"; rm -rf "$wd"; mkdir -p "$wd"; cp "$img" "$wd/in.img"
        local bin=$( [ $side = old ] && echo ./dtbo_oc_v271_host || echo ./dtbo_oc_host )
        local args="--img $wd/in.img --out tp_${name}.img --dtc ./dtc --workdir $wd $extra"
        [ -n "$hz" ] && args="$args --hz $hz"
        $bin patch $args > /dev/null 2>&1
        local rc=$?
        local out=$( [ $side = old ] && echo "$OLDD/$name.img" || echo "$NEWD/$name.img" )
        local got=$(ls tp_${name}.img 2>/dev/null)
        # 输出文件名固定 tp_${name}.img (脚本内 --out tp_${name}.img)? run_all 用相对名, cmp 版直接找最新生成的
        mv -f "tp_${name}.img" "$out" 2>/dev/null || true
        echo "$side $name rc=$rc"
    done
}
run_case "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pro_185 "$G185" ""
run_case "$U/a46c7974-e65b-42e7-bbcf-e91794771505_一加_13T_17.0.0.104_dtbo.img" op13t "$G144" "--multifam"
run_case "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15_195 "$G195" ""
run_case "$U/a1f05034-d8db-4d74-bb53-eab9df2f6e49_一加15t可超195.dtbo.img" op15t "$G195" ""
run_case "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6 "$G195" ""
run_case "$U/0bb81094-120b-4f24-a48d-ecce4e50f366_一加ace6t可超频185.dtbo.img" ace6t "$G185" ""
run_case "$U/e207c7a7-aa6f-42af-9edf-6619f3c651d2_一加ace6至尊.可超频195+解容+移除充电限流dtbo.img" ace6u "$G195" ""
run_case "$U/59c8eba7-c34b-46ce-bbd3-3fdad67c0b5b_一加ace3pro可超144.dtbo.img" ace3pro "$G144" ""
run_case "$U/8836604a-7fce-4deb-919f-b440101bf631_一加ace3可超144.dtbo.img" ace3 "$G144" ""
run_case "$U/b527a8e3-eae6-4264-9e09-32748a7c0d08_一加Ace5可超144.dtbo.img" ace5 "$G144" ""
run_case "$U/546a08d5-f25e-48be-9ed5-386c4658ee2f_ace5pro.可超频144.dtbo.img" ace5p "$G144" ""
run_case "$U/31897c63-f086-417a-960f-1e4812be6755_一加13.dtbo.img" op13 "$G144" ""
run_case "$U/798682e4-4ade-4645-b3c4-dc5f2c3527b7_一加12可超144.dtbo_a.img" op12 "$G144" ""
run_case "$U/83ae6eb4-3f9e-4248-bdb0-89f90cf06007_真我gt8.dtbo.img" gt8 "$G195" ""
run_case "$U/a547f0f9-dea0-443b-abec-38a2f214734e_真我gt8pro可超频185.dtbo.img" gt8p "$G185" ""
run_case "$U/c64d3c24-bd71-4dd9-a920-6edc6752b070_真我GT7 Pro可超185dtbo.img" gt7s "$G185" ""
run_case "$U/fe1fffd6-3d36-425f-a8bd-a503ee7fadba_真我gt7Pro竞速版.可超频144.dtbo.img" gt7p2 "$G144" "--battery 2"
run_case "$U/2255da35-e279-450d-8292-af0112c8dbd4_真我GT7Pro竞速版已修改dtbo.img" gt7p "130,142,144" "--gt7p"
echo "==== 对比结果 ===="
for f in $OLDD/*.img; do
    n=$(basename $f)
    if [ ! -f "$NEWD/$n" ]; then echo "MISSING $n (新逻辑未产出)"; continue; fi
    if cmp -s "$f" "$NEWD/$n"; then echo "SAME  $n"; else echo "DIFF  $n ($(stat -c%s $f) -> $(stat -c%s $NEWD/$n))"; fi
done
