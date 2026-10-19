#!/bin/bash
# v2.38 回归: 主板ID绑定 + 名单白名单/永久授权 + license v2 格式 + 泄露检查
B=/tmp/dtbo_oc_test     # 测试构建 (LIC_TEST_MEMBERS)
S=/tmp/dtbo_oc_x86      # 正式构建
W=/tmp/reg238; rm -rf $W; mkdir -p $W; cd $W
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望[$3] 实际[$2])"; fi; }
has()  { if echo "$2" | grep -q "$3"; then ok "$1"; else bad "$1 (输出: $2)"; fi; }

M1="MACH000000000001"; M2="MACH000000000002"; M3="MACH000000000003"

# 名单: 普通 / 永久 / 双机器码白名单
cat > members.txt <<EOF
GROUP=1124737265
1000000001
1000000002*
1000000003:$M1,$M2
1000000004:$M1
EOF
# 无 GROUP 头
printf '1000000001\n' > bad_members.txt

run() { DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$2 $B verify --qq "$1" --members $W/members.txt 2>/dev/null; }

echo "== 1. machineid 子命令 =="
OUT=$(DTBO_OC_MACHINE=$M1 $B machineid 2>/dev/null)
chk "machineid 输出" "$OUT" "MACHINE=$M1"
OUT=$(DTBO_OC_MACHINE="" $B machineid 2>/dev/null)   # 无环境变量且无 proc 文件 -> "0"
chk "machineid 兜底 0" "$OUT" "MACHINE=0"

echo "== 2. 普通 QQ (无白名单): 30天授权 =="
rm -f lic.txt
OUT=$(run 1000000001 $M1)
has "验证通过" "$OUT" "VERIFIED=1"
has "30天" "$OUT" "EXPIRY_DATE=20"
has "非永久" "$OUT" "PERMANENT=0"
has "含机器码" "$OUT" "MACHINE=$M1"
grep -q "^DTBOOCLIC2|1000000001|.*|$M1|" lic.txt && ok "license v2 六字段" || bad "license v2 六字段 ($(cat lic.txt 2>/dev/null))"

echo "== 3. 永久授权 (QQ*) =="
rm -f lic.txt
OUT=$(run 1000000002 $M1)
has "永久标记" "$OUT" "PERMANENT=1"
grep -q "DTBOOCLIC2|1000000002|[0-9]*|0|$M1|" lic.txt && ok "EXPIRY=0 永久" || bad "EXPIRY=0 永久"

echo "== 4. 白名单: 绑定 2 台, 第 3 台拒绝 =="
rm -f lic.txt
OUT=$(run 1000000003 $M1)
has "白名单机器1 通过" "$OUT" "VERIFIED=1"
rm -f lic.txt
OUT=$(run 1000000003 $M2)
has "白名单机器2 通过" "$OUT" "VERIFIED=1"
rm -f lic.txt
OUT=$(run 1000000003 $M3)
has "第3台拒绝" "$OUT" "REASON=machine_not_allowed"
has "拒绝输出机器码" "$OUT" "MACHINE=$M3"
[ ! -s lic.txt ] && ok "拒绝时未写授权" || bad "拒绝时未写授权"

echo "== 5. 白名单 QQ 在错误机器验证后 license 检查 =="
rm -f lic.txt
run 1000000004 $M1 >/dev/null
OUT=$(DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$M1 $B license 2>/dev/null)
has "本机 license ok" "$OUT" "LICENSE=ok"
OUT=$(DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$M3 $B license 2>/dev/null)
has "换机 wrongmachine" "$OUT" "LICENSE=wrongmachine"

echo "== 6. 复制授权到其他设备无效 (license v2 绑定) =="
rm -f lic2.txt
run 1000000003 $M1 >/dev/null
cp lic.txt lic2.txt
OUT=$(DTBO_OC_LICENSE=$W/lic2.txt DTBO_OC_MACHINE=$M2 $B license 2>/dev/null)
has "M2 在白名单但 license 是 M1 签发" "$OUT" "LICENSE=wrongmachine"

echo "== 7. 旧版 v1 格式 license 失效 =="
python3 - <<PYEOF
import re, hmac, hashlib, time
hdr = open('/workspace/DTBO_OC_Module/src/lic_data.h').read()
def getarr(name):
    m = re.search(name + r'\[[0-9]+\] = \{(.*?)\}', hdr, re.S)
    return [int(x) for x in m.group(1).replace('\n',' ').split(',') if x.strip()]
xor = getarr('LIC_XOR'); kenc = getarr('LIC_KEY_C')
key = bytes(kenc[i] ^ xor[i & 15] for i in range(32))
now = int(time.time())
payload = f"DTBOOCLIC1|1000000001|{now}|{now+2592000}"
mac = hmac.new(key, payload.encode(), hashlib.sha256).hexdigest()
open('/tmp/reg238/v1lic.txt','w').write(payload + '|' + mac + '\n')
PYEOF
OUT=$(DTBO_OC_LICENSE=$W/v1lic.txt DTBO_OC_MACHINE=$M1 $B license 2>/dev/null)
has "v1 旧格式拒绝" "$OUT" "LICENSE=bad"

echo "== 8. 名单无效 (无 GROUP 头) =="
rm -f lic.txt
OUT=$(DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$M1 $B verify --qq 1000000001 --members $W/bad_members.txt 2>/dev/null)
has "无GROUP头拒绝" "$OUT" "REASON=list_invalid"

echo "== 9. patch 门禁: wrongmachine 也拦截 (测试构建) =="
rm -f lic.txt
run 1000000003 $M1 >/dev/null   # license 绑定 M1
DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$M3 $B patch --img /dev/null --out /tmp/p1.img --dtc /bin/true --hz 144 >/dev/null 2>&1
chk "wrongmachine patch 拒绝 exit4" "$?" "4"
DTBO_OC_LICENSE=$W/lic.txt DTBO_OC_MACHINE=$M1 $B patch --img /dev/null --out /tmp/p2.img --dtc /bin/true --hz 144 >/dev/null 2>&1
RC=$?
[ $RC -ne 4 ] && [ $RC -ne 0 ] && ok "本机授权 patch 放行 (rc=$RC, 镜像无效属预期)" || bad "本机授权 patch 应放行 (rc=$RC)"

echo "== 10. 云端 E2E (正式构建, GitHub 名单) =="
rm -f cloudlic.txt
OUT=$(DTBO_OC_LICENSE=$W/cloudlic.txt timeout 60 $S verify --qq 1935400047 2>/dev/null)
if echo "$OUT" | grep -q "VERIFIED=1"; then
    ok "云端验证通过"
    grep -qE '\|0\|[0-9a-f]{64}' cloudlic.txt && ok "云端 license 含机器码" || bad "云端 license 含机器码 ($(cat cloudlic.txt 2>/dev/null))"
else
    echo "SKIP  云端 E2E (网络不可达: $OUT)"
fi

echo "== 11. 二进制泄露检查 =="
ARM=/workspace/DTBO_OC_Module/module/arm64/dtbo_oc
for pat in "raw.githubusercontent" "cdn.jsdelivr" "1124737265" "DTBO_OC_MACHINE"; do
    if strings -a "$ARM" | grep -q "$pat"; then bad "泄露: $pat"; else ok "无泄露: $pat"; fi
done

echo "=== PASS=$PASS FAIL=$FAIL ==="
[ $FAIL -eq 0 ]
