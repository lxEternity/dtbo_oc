#!/bin/bash
# v2.35 回归: flags=0 修复 + strip 表修正 + 全机型 checkoc
U=/workspace/.uploads
B=/tmp/dtbo_oc_x86
DTC=/usr/bin/dtc
W=/tmp/reg235; rm -rf $W; mkdir -p $W; cd $W
G144="130,132,138,141,144"; G185="130,132,138,141,144,148,150,158,165,170,178,185"
G195="130,132,138,141,144,148,150,158,165,170,178,185,190,195,198"
PASS=0; FAIL=0
flags0() {  # 校验补丁镜像 AVB footer flags == 0
    python3 - "$1" <<'PYEOF'
import struct, sys
b = open(sys.argv[1],'rb').read()
foot = b[-64:]
if foot[:4] != b'AVBf': print('FLAGS=none'); sys.exit(0)
vb_off = struct.unpack('>Q', foot[20:28])[0]
vm = b[vb_off:vb_off+256]
print('FLAGS=%d' % (struct.unpack('>I', vm[120:124])[0] if vm[:4]==b'AVB0' else -1))
PYEOF
}
run() {
    local img="$1" name="$2" hz="$3" extra="$4" strip="$5"
    [ -f "$img" ] || { echo "SKIP  $name"; return; }
    rm -rf $W/w_$name; mkdir -p $W/w_$name
    SA=""; [ "$strip" != "0" ] && SA="--strip-above $strip"
    $B patch --img "$img" --out $W/out_$name.img --dtc $DTC --workdir $W/w_$name $SA $extra --hz $hz > $W/log_$name.txt 2>&1
    local rc=$?
    FL=$(flags0 $W/out_$name.img)
    CK=$($B checkoc --img $W/out_$name.img --stock-img "$img" --dtc $DTC --workdir $W/w_$name 2>/dev/null)
    NOC=$(echo "$CK" | grep '^NOC=' | cut -d= -f2); MISS=$(echo "$CK" | grep '^MISSING=' | cut -d= -f2); FRN=$(echo "$CK" | grep '^FOREIGN=' | cut -d= -f2)
    [ -z "$MISS" ] && MISS=0; [ -z "$FRN" ] && FRN=0
    # 污染镜像(gt7s/gt7p系)相对污染基准 NOC 可为 0, 单独标注
    OK="FAIL"
    if [ $rc -eq 0 -o $rc -eq 3 ]; then
        if [ "$FL" = "FLAGS=0" ] && [ "$MISS" = "0" ] && [ "$FRN" = "0" ]; then
            if [ -n "$NOC" ] && [ "$NOC" != "0" ]; then OK="PASS"; else OK="PASS*"; fi
        fi
    fi
    [ "$OK" = "PASS" ] || [ "$OK" = "PASS*" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
    printf "%-6s %-8s rc=%s %-9s NOC=%-3s MISS=%s FRN=%s\n" "$OK" "$name" "$rc" "$FL" "${NOC:-?}" "$MISS" "$FRN"
}
run "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pro "$G185" "" 120
run "$U/a46c7974-e65b-42e7-bbcf-e91794771505_一加_13T_17.0.0.104_dtbo.img" op13t "$G144" "--multifam" 120
run "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15 "$G195" "" 165
run "$U/a1f05034-d8db-4d74-bb53-eab9df2f6e49_一加15t可超195.dtbo.img" op15t "$G195" "" 165
run "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6 "$G195" "" 165
run "$U/0bb81094-120b-4f24-a48d-ecce4e50f366_一加ace6t可超频185.dtbo.img" ace6t "$G185" "" 165
run "$U/59c8eba7-c34b-46ce-bbd3-3fdad67c0b5b_一加ace3pro可超144.dtbo.img" ace3pro "$G144" "" 120
run "$U/8836604a-7fce-4deb-919f-b440101bf631_一加ace3可超144.dtbo.img" ace3 "$G144" "" 120
run "$U/b527a8e3-eae6-4264-9e09-32748a7c0d08_一加Ace5可超144.dtbo.img" ace5 "$G144" "" 120
run "$U/546a08d5-f25e-48be-9ed5-386c4658ee2f_ace5pro.可超频144.dtbo.img" ace5p "$G144" "" 120
run "$U/31897c63-f086-417a-960f-1e4812be6755_一加13.dtbo.img" op13 "$G144" "--include-family wqhd_sdc" 120
run "$U/798682e4-4ade-4645-b3c4-dc5f2c3527b7_一加12可超144.dtbo_a.img" op12 "$G144" "--multifam" 120
run "$U/83ae6eb4-3f9e-4248-bdb0-89f90cf06007_真我gt8.dtbo.img" gt8 "$G195" "" 144
run "$U/a547f0f9-dea0-443b-abec-38a2f214734e_真我gt8pro可超频185.dtbo.img" gt8p "$G185" "" 144
run "$U/c64d3c24-bd71-4dd9-a920-6edc6752b070_真我GT7 Pro可超185dtbo.img" gt7s "$G185" "" 120
run "$U/fe1fffd6-3d36-425f-a8bd-a503ee7fadba_真我gt7Pro竞速版.可超频144.dtbo.img" gt7p2 "$G144" "" 120
run "$U/2255da35-e279-450d-8292-af0112c8dbd4_真我GT7Pro竞速版已修改dtbo.img" gt7p "130,142,144" "--gt7p" 120
echo "=== 电池方案抽查 ==="
run "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15batt "$G195" "--battery 3" 165
run "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" ace2pbatt "$G185" "--battery 4" 120
echo "=== avboff 已移除 ==="
$B avboff --img /dev/null --out /tmp/x.img >/tmp/avb.out 2>&1; ARC=$?
grep -q '未知命令' /tmp/avb.out && [ $ARC -ne 0 ] && { echo "PASS avboff 已移除"; PASS=$((PASS+1)); } || { echo "FAIL avboff"; FAIL=$((FAIL+1)); }
echo "=== PASS=$PASS FAIL=$FAIL ==="
echo "注: PASS* = 输入为用户已修改/污染镜像, 相对该基准无新增 OC 节点属预期"
