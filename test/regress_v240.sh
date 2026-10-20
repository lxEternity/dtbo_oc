#!/bin/bash
# v2.40 回归: 天机平台主板ID回退 (cmdline oplusboot.serialno) + 查询脚本防护 + patch 无回归
# 核心修复: ACE6至尊版 (MT6993) 无 soc0/DT serial, 旧版 machineid 输出 0
# 方法: chroot + 静态二进制 + busybox 伪造 /proc/cmdline
S=/workspace/DTBO_OC_Module/src/dtbo_oc.c
T=/workspace/DTBO_OC_Module/test
ARM=/workspace/DTBO_OC_Module/module/arm64/dtbo_oc
W=/tmp/reg240; rm -rf $W; mkdir -p $W; cd $W
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (期望[$3] 实际[$2])"; fi; }
has()  { if echo "$2" | grep -q "$3"; then ok "$1"; else bad "$1 (输出: $2)"; fi; }

echo "== 0. 构建与 chroot 环境 =="
cc -O2 -static -DLIC_TEST_MEMBERS -o $W/dtbo_oc_test $S -lm 2>/dev/null && ok "测试构建(静态)" || bad "测试构建"
cc -O2 -static -o $W/dtbo_oc_x86 $S -lm 2>/dev/null && ok "正式x86构建(静态)" || bad "正式x86构建"
CH=$W/ch
mkdir -p $CH/proc $CH/bin $CH/dev $CH/tmp $CH/data/adb/dtbo_oc \
         $CH/data/adb/modules/dtbo_oc/arm64 $CH/data/local/tmp
: > $CH/dev/null   # 重定向用占位 (chroot 内无设备节点)
cp $W/dtbo_oc_test $CH/t_test
cp $W/dtbo_oc_x86   $CH/t_prod
cp /usr/bin/qemu-aarch64-static $CH/qemu
cp $ARM $CH/dtbo_oc_arm
cp /usr/bin/busybox $CH/bin/busybox
for a in sh tr sed cut cat mkdir grep env; do ln -sf busybox $CH/bin/$a; done
chr()    { chroot $CH "$@"; }                       # 环境无关执行
chrenv() { chroot $CH /bin/env "$@"; }               # 带环境变量执行
mkfake() { printf '%s' "$1" > $CH/proc/cmdline; }

S1="INIFDIZ94D4P8PQ4"   # ACE6至尊真机序列号 (16位)
S2="3B664H00W0T00000"   # 另一台 16 位序列号

echo "== 1. C 端 cmdline 回退 (正式x86) =="
mkfake "console=tty0 oplusboot.serialno=$S1 oplusboot.mode=normal"
chk "标准位置提取" "$(chr /t_prod machineid 2>/dev/null)" "MACHINE=$S1"
mkfake "oplusboot.serialno=$S1 console=tty0"
chk "首位token提取" "$(chr /t_prod machineid 2>/dev/null)" "MACHINE=$S1"
mkfake "console=tty0 oplusboot.serialno=ABCDEFGHIJKLMNOPQRST x=1"
chk "超16位截断" "$(chr /t_prod machineid 2>/dev/null)" "MACHINE=ABCDEFGHIJKLMNOP"
mkfake "console=tty0 oplusboot.mode=normal"
chk "无serial回退0" "$(chr /t_prod machineid 2>/dev/null)" "MACHINE=0"
sed -n '/=== \/proc\/cmdline ===/,/=== \/proc\/cpuinfo ===/p' /workspace/ko_dev/ace6u/info/device.txt | sed '1d;$d' | tr -d '\n' > $CH/proc/cmdline
chk "ACE6U真机cmdline" "$(chr /t_prod machineid 2>/dev/null)" "MACHINE=$S1"

echo "== 2. 发布 arm64 二进制 E2E (qemu in chroot) =="
mkfake "console=tty0 oplusboot.serialno=$S1 oplusboot.mode=normal"
chk "arm64 真机回退" "$(chr /qemu /dtbo_oc_arm machineid 2>/dev/null)" "MACHINE=$S1"
mkfake "console=tty0"
chk "arm64 无serial回退0" "$(chr /qemu /dtbo_oc_arm machineid 2>/dev/null)" "MACHINE=0"

echo "== 3. 授权绑定链路走新ID源 (默认license路径) =="
printf 'GROUP=1124737265\n10001\n' > $CH/members.txt
mkfake "console=tty0 oplusboot.serialno=$S1"
OUT=$(chr /t_test verify --qq 10001 --members /members.txt 2>/dev/null)
has "verify 通过" "$OUT" "VERIFIED=1"
grep -q "|$S1|" $CH/data/adb/dtbo_oc/license && ok "license 绑定 cmdline序列号" || bad "license 机器字段 ($(cat $CH/data/adb/dtbo_oc/license 2>/dev/null))"
has "本机license ok" "$(chr /t_test license 2>/dev/null)" "LICENSE=ok"
mkfake "console=tty0 oplusboot.serialno=$S2"
has "换机 wrongmachine" "$(chr /t_test license 2>/dev/null)" "LICENSE=wrongmachine"
mkfake "console=tty0"
has "ID=0 时 license 拒绝" "$(chr /t_test license 2>/dev/null)" "LICENSE=wrongmachine"

echo "== 4. 查询脚本回退 + 防旧版0覆盖 (busybox chroot) =="
for scr in machineid.sh 主板ID查询.sh; do
    printf '#!/bin/sh\necho MACHINE=0\n' > $CH/data/adb/modules/dtbo_oc/arm64/dtbo_oc   # 旧版二进制行为
    chmod +x $CH/data/adb/modules/dtbo_oc/arm64/dtbo_oc
    cp /workspace/DTBO_OC_Module/$scr $CH/$scr
    mkfake "console=tty0 oplusboot.serialno=$S1 oplusboot.mode=normal"
    OUT=$(chr /bin/sh /$scr /out.txt 2>&1)
    has "$scr 提取cmdline序列号" "$OUT" "主板唯一ID: $S1"
    chk  "$scr 不被旧版0覆盖" "$(cat $CH/out.txt)" "$S1"
    printf '#!/bin/sh\necho MACHINE=OTHERID12345678\n' > $CH/data/adb/modules/dtbo_oc/arm64/dtbo_oc
    chmod +x $CH/data/adb/modules/dtbo_oc/arm64/dtbo_oc
    OUT=$(chr /bin/sh /$scr /out2.txt 2>&1)
    has "$scr 采用模块ID" "$OUT" "模块授权使用的ID为 OTHERID12345678"
    chk  "$scr 最终ID=模块ID" "$(cat $CH/out2.txt)" "OTHERID12345678"
done

echo "== 5. patch 流程无回归 (一加13 / ACE6U 真机镜像, 宿主 dtc) =="
export DTBO_OC_LICENSE=$W/lic2.txt DTBO_OC_MACHINE=$S1
$W/dtbo_oc_test verify --qq 10001 --members $CH/members.txt >/dev/null 2>&1
OP13="/workspace/.uploads/31897c63-f086-417a-960f-1e4812be6755_一加13.dtbo.img"
DTC=/usr/bin/dtc
OUT=$($W/dtbo_oc_test identify --img "$OP13" --dtc $DTC 2>&1)
has "op13 identify" "$OUT" "DEVICE=op13"
$W/dtbo_oc_test patch --img "$OP13" --out $W/op13_oc.img --dtc $DTC --hz 150 --min-clone >/dev/null 2>&1
[ $? -eq 0 ] && [ -s $W/op13_oc.img ] && ok "op13 patch 150 成功" || bad "op13 patch 150"
# DTBO 镜像按条目拆分后反编译 (整体镜像非单 dtb)
python3 - "$W/op13_oc.img" "$W/op13_entries" <<'PYEOF'
import struct, sys, os
b = open(sys.argv[1],'rb').read()
magic, total, hs, es, cnt, off, ps, ver = struct.unpack('>8I', b[:32])
assert magic == 0xd7b7ab1e
os.makedirs(sys.argv[2], exist_ok=True)
for i in range(cnt):
    e = b[off+i*es: off+(i+1)*es]
    dsz, doff = struct.unpack('>II', e[0:8])
    open(f'{sys.argv[2]}/e{i}.dtb','wb').write(b[doff:doff+dsz])
PYEOF
cat $W/op13_entries/e*.dtb > $W/op13_all.dtb
$DTC -I dtb -O dts -q $W/op13_all.dtb -o $W/op13_oc.dts 2>/dev/null || $DTC -I dtb -O dts -q --concat -i $W/op13_entries -o $W/op13_oc.dts 2>/dev/null
[ -s $W/op13_oc.dts ] || for f in $W/op13_entries/e*.dtb; do $DTC -I dtb -O dts -q "$f" >> $W/op13_oc.dts 2>/dev/null; done
N150=$(grep -c 'framerate = <0x96>' $W/op13_oc.dts)
[ "${N150:-0}" -ge 1 ] && ok "op13 输出含 150Hz 节点" || bad "op13 150Hz 节点数=$N150"
BASE120=$(grep -c 'framerate = <0x78>' $W/op13_oc.dts)
[ "${BASE120:-0}" -ge 4 ] && ok "op13 原厂120基准保留" || bad "op13 基准120节点数=$BASE120"
OUT=$($W/dtbo_oc_test identify --img $T/ace6u.img --dtc $DTC 2>&1)
has "ace6u identify" "$OUT" "DEVICE=ace6u"
$W/dtbo_oc_test patch --img $T/ace6u.img --out $W/ace6u_oc.img --dtc $DTC --hz 185 >/dev/null 2>&1
[ $? -eq 0 ] && [ -s $W/ace6u_oc.img ] && ok "ace6u patch 185 成功" || bad "ace6u patch 185"

echo "== 6. 发布二进制泄露检查 =="
for pat in "DTBO_OC_MACHINE" "raw.githubusercontent" "1124737265"; do
    if strings -a "$ARM" | grep -q "$pat"; then bad "泄露: $pat"; else ok "无泄露: $pat"; fi
done

echo "=== PASS=$PASS FAIL=$FAIL ==="
[ $FAIL -eq 0 ]
