#!/bin/bash
# v2.34 回归: v2.30 插值全机型 + 零 vbmeta (avboff 已移除) + 救援锁
U=/workspace/.uploads
B=/tmp/dtbo_oc_x86
DTC=/usr/bin/dtc
W=/tmp/reg234; rm -rf $W; mkdir -p $W; cd $W
G144="130,132,138,141,144"; G165="130,132,138,141,144,148,150,158,165"
G185="130,132,138,141,144,148,150,158,165,170,178,185"
G195="130,132,138,141,144,148,150,158,165,170,178,185,190,195,198"
PASS=0; FAIL=0
run() {
    local img="$1" name="$2" hz="$3" extra="$4"
    [ -f "$img" ] || { echo "SKIP  $name (无镜像)"; return; }
    rm -rf $W/w_$name; mkdir -p $W/w_$name
    ID=$($B identify --img "$img" --dtc $DTC --workdir $W/w_$name 2>/dev/null)
    DEV=$(echo "$ID" | grep '^DEVICE=' | cut -d= -f2)
    STRIPV=$(echo "$ID" | grep '^STRIP_ABOVE=' | cut -d= -f2); [ -z "$STRIPV" ] && STRIPV=0
    $B patch --img "$img" --out $W/out_$name.img --dtc $DTC --workdir $W/w_$name --strip-above $STRIPV $extra --hz $hz > $W/log_$name.txt 2>&1
    local rc=$?
    CK=$($B checkoc --img $W/out_$name.img --stock-img "$img" --dtc $DTC --workdir $W/w_$name 2>/dev/null)
    NOC=$(echo "$CK" | grep '^NOC=' | cut -d= -f2); MISS=$(echo "$CK" | grep '^MISSING=' | cut -d= -f2); FRN=$(echo "$CK" | grep '^FOREIGN=' | cut -d= -f2)
    [ -z "$MISS" ] && MISS=0; [ -z "$FRN" ] && FRN=0
    OK="FAIL"; [ $rc -eq 0 -o $rc -eq 3 ] && [ "$MISS" = "0" ] && [ "$FRN" = "0" ] && [ -n "$NOC" ] && [ "$NOC" != "0" ] && OK="PASS"
    if [ "$OK" = "PASS" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
    printf "%-8s %-8s id=%-8s rc=%s NOC=%s MISS=%s FRN=%s\n" "$OK" "$name" "$DEV" "$rc" "${NOC:-?}" "$MISS" "$FRN"
}
run "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pro "$G185" ""
run "$U/a46c7974-e65b-42e7-bbcf-e91794771505_一加_13T_17.0.0.104_dtbo.img" op13t "$G144" "--multifam"
run "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15 "$G195" ""
run "$U/a1f05034-d8db-4d74-bb53-eab9df2f6e49_一加15t可超195.dtbo.img" op15t "$G195" ""
run "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6 "$G195" ""
run "$U/0bb81094-120b-4f24-a48d-ecce4e50f366_一加ace6t可超频185.dtbo.img" ace6t "$G185" ""
run "$U/59c8eba7-c34b-46ce-bbd3-3fdad67c0b5b_一加ace3pro可超144.dtbo.img" ace3pro "$G144" ""
run "$U/8836604a-7fce-4deb-919f-b440101bf631_一加ace3可超144.dtbo.img" ace3 "$G144" ""
run "$U/b527a8e3-eae6-4264-9e09-32748a7c0d08_一加Ace5可超144.dtbo.img" ace5 "$G144" ""
run "$U/546a08d5-f25e-48be-9ed5-386c4658ee2f_ace5pro.可超频144.dtbo.img" ace5p "$G144" ""
run "$U/31897c63-f086-417a-960f-1e4812be6755_一加13.dtbo.img" op13 "$G144" "--include-family wqhd_sdc"
run "$U/798682e4-4ade-4645-b3c4-dc5f2c3527b7_一加12可超144.dtbo_a.img" op12 "$G144" "--multifam"
run "$U/83ae6eb4-3f9e-4248-bdb0-89f90cf06007_真我gt8.dtbo.img" gt8 "$G195" ""
run "$U/a547f0f9-dea0-443b-abec-38a2f214734e_真我gt8pro可超频185.dtbo.img" gt8p "$G185" ""
run "$U/c64d3c24-bd71-4dd9-a920-6edc6752b070_真我GT7 Pro可超185dtbo.img" gt7s "$G185" ""
run "$U/fe1fffd6-3d36-425f-a8bd-a503ee7fadba_真我gt7Pro竞速版.可超频144.dtbo.img" gt7p2 "$G144" ""
run "$U/2255da35-e279-450d-8292-af0112c8dbd4_真我GT7Pro竞速版已修改dtbo.img" gt7p "130,142,144" "--gt7p"
echo "=== 电池方案抽查 (op15/ace6u) ==="
run "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15batt "$G195" "--battery 3"
run "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6batt "$G195" "--battery 4"
echo "=== avboff 必须不存在 ==="
$B avboff --img /dev/null --out /tmp/x.img >/tmp/avb.out 2>&1
ARC=$?; grep -q '未知命令' /tmp/avb.out && [ $ARC -ne 0 ] && echo "PASS avboff 已移除" || { echo "FAIL avboff 仍可调用"; FAIL=$((FAIL+1)); }
echo "=== 结果: PASS=$PASS FAIL=$FAIL ==="
echo "注: gt7p 项输入为用户已修改镜像 (含同数值 OC 节点), checkoc 相对该基准 NOC=0 属预期; v2.33 二进制同输入行为一致, 非 v2.34 回归"
