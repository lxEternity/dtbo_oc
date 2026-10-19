#!/bin/bash
# v2.37 回归: 自动验证 (本机QQ检测) + joingroup 跳转 + 安装时门禁
B=/tmp/dtbo_oc_x86_test      # LIC_TEST_MEMBERS 构建
SHIP=/tmp/dtbo_oc_x86_ship   # 正式构建
D=/data/adb/dtbo_oc
W=/tmp/reg237; rm -rf $W; mkdir -p $W
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
[ -x "$B" ] || { echo "缺少 $B"; exit 1; }
command -v dtc >/dev/null || { echo "缺少 dtc"; exit 1; }
rm -f "$D/license"

# 模拟本机QQ数据目录
mkdir -p $W/qq/databases $W/qq/shared_prefs $W/qq2/databases $W/empty
printf 'x' > $W/qq/databases/10001.db                 # 经典QQ: <uin>.db
printf 'x' > $W/qq/databases/slowtable_10001.db       # 慢表库 (前缀, 应忽略)
printf 'x' > $W/qq/databases/10002.db                 # 第二账号
printf 'x' > $W/qq2/databases/10002.db                # qq2: 只有不在群内的陌生QQ
printf '<string name="lastUin">1935400047</string>\n' > $W/qq/shared_prefs/prefs.xml  # NT风格
printf 'GROUP=1124737265\n10001\n1935400047\n' > $W/members.txt
printf 'GROUP=1124737265\n1935400047\n' > $W/members2.txt

echo "=== 1. auto 命中 (db候选在名单) ==="
OUT=$(LIC_AUTO_DIRS=$W/qq/databases $B verify --auto --members $W/members.txt 2>/dev/null)
echo "$OUT" | grep -q '^VERIFIED=1 QQ=10001 ' && echo "$OUT" | grep -q 'AUTO=1' && ok "命中 10001" || bad "输出: $OUT"
$B license 2>/dev/null | grep -q '^LICENSE=ok QQ=10001' && ok "license 已写入" || bad "license 未写入"

echo "=== 2. auto XML 探测 (NT QQ prefs) ==="
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/qq/shared_prefs $B verify --auto --members $W/members.txt 2>/dev/null)
echo "$OUT" | grep -q '^VERIFIED=1 QQ=1935400047' && ok "xml 探测命中 1935400047" || bad "输出: $OUT"

echo "=== 3. auto 多候选部分命中 ==="
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/qq/databases:$W/qq/shared_prefs $B verify --auto --members $W/members2.txt 2>/dev/null)
# 候选: 10001(不在members2), 10002(不在), 1935400047(在) → 命中
echo "$OUT" | grep -q '^VERIFIED=1 QQ=1935400047' && ok "多候选遍历命中" || bad "输出: $OUT"

echo "=== 4. auto 未入群 ==="
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/qq/databases $B verify --auto --members $W/members2.txt 2>/dev/null); RC=$?
[ "$RC" != "0" ] && echo "$OUT" | grep -q 'REASON=not_in_group' && ok "not_in_group 拒绝" || bad "输出: $OUT rc=$RC"

echo "=== 5. auto 无候选 ==="
OUT=$(LIC_AUTO_DIRS=$W/empty $B verify --auto --members $W/members.txt 2>/dev/null); RC=$?
[ "$RC" != "0" ] && echo "$OUT" | grep -q 'REASON=no_local_qq' && ok "no_local_qq 拒绝" || bad "输出: $OUT rc=$RC"
# 正式构建无 env 逃逸: --members 被拒 (仅测试构建支持); 真实路径无本机QQ → no_local_qq
OUT=$($SHIP verify --auto --members $W/members.txt 2>/dev/null); RC=$?
[ "$RC" != "0" ] && ok "正式构建拒绝 --members (rc=$RC)" || bad "正式构建接受 --members: $OUT"
OUT=$($SHIP verify --auto 2>/dev/null); RC=$?
[ "$RC" != "0" ] && echo "$OUT" | grep -q 'REASON=no_local_qq' && ok "正式构建沙箱无本机QQ → no_local_qq (env不可伪造)" || bad "输出: $OUT rc=$RC"

echo "=== 6. auto 授权后 patch 门禁放行 ==="
rm -f "$D/license"
LIC_AUTO_DIRS=$W/qq/databases $B verify --auto --members $W/members.txt >/dev/null 2>&1
$B license 2>/dev/null | grep -q '^LICENSE=ok' && ok "auto 授权有效" || bad "auto 授权无效"

echo "=== 7. joingroup 输出群卡片链接 ==="
OUT=$($B joingroup 2>/dev/null); RC=$?
echo "$OUT" | grep -q '^QQLINK=mqqapi://card/show_pslcard.*uin=1124737265.*card_type=group' && ok "QQLINK 含群号 (运行时拼接)" || bad "输出: $OUT"
[ "$RC" = "0" ] && ok "joingroup exit 0 (无 am 环境降级打印)" || bad "rc=$RC"

echo "=== 8. 二进制明文泄露检查 ==="
STR=$(strings module/arm64/dtbo_oc)
echo "$STR" | grep -q '1124737265' && bad "arm64 二进制泄露群号" || ok "arm64 无群号明文"
echo "$STR" | grep -qE 'jsdelivr|raw\.githubusercontent' && bad "arm64 二进制泄露URL" || ok "arm64 无URL明文"

echo "=== 9. webuictl verify auto=1 ==="
MOD=/tmp/wui237; rm -rf $MOD; mkdir -p $MOD/bin $MOD/arm64
cp module/bin/webuictl.sh $MOD/bin/
cp $B $MOD/arm64/dtbo_oc; chmod 755 $MOD/arm64/dtbo_oc
mkdir -p $D/work
cp $W/members.txt $D/members.txt   # 测试构建无 --members 时读缓存 (模拟正式构建联网拉取后的名单)
OUT=$(LIC_AUTO_DIRS=$W/qq/databases sh $MOD/bin/webuictl.sh verify auto=1 2>/dev/null)
echo "$OUT" | grep -q '"ok":true' && echo "$OUT" | grep -q '"state":"ok"' && ok "webuictl auto 成功 (简洁文案)" || bad "输出: $OUT"
rm -f "$D/license"
OUT=$(sh $MOD/bin/webuictl.sh verify auto=1 2>/dev/null)
echo "$OUT" | grep -q '未在本机检测到QQ/TIM账号' && ok "webuictl no_local_qq 映射" || bad "输出: $OUT"
echo "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && ok "JSON 合法" || bad "JSON 非法"

echo "=== 10. customize.sh 安装时门禁模拟 ==="
runinst() {  # env... ; 模拟 Magisk 安装环境
    rm -rf $W/fakemod; mkdir -p $W/fakemod/arm64
    cp module/customize.sh $W/fakemod/
    cp $B $W/fakemod/arm64/dtbo_oc; cp /usr/bin/dtc $W/fakemod/arm64/dtc
    env MODPATH=$W/fakemod ui_print='echo' "$@" sh $W/fakemod/customize.sh 2>&1
}
cp $W/members.txt $D/members.txt   # 预置名单缓存 (模拟正式构建联网拉取成功)
# 10a: auto 命中 → 安装继续且验证通过
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/qq/databases runinst)
echo "$OUT" | grep -q '验证通过: 本机QQ 10001 在群内' && ok "安装自动验证通过" || bad "输出片段: $(echo "$OUT" | grep -i '验证' | head -3)"
# 10b: 未入群 → abort + 打开群卡片提示
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/qq2/databases runinst); RC=$?
echo "$OUT" | grep -q '本机QQ未加入指定QQ群, 禁止刷入' && ok "未入群阻止提示" || bad "无阻止提示"
echo "$OUT" | grep -q '正在打开QQ群卡片' && ok "跳转QQ群提示" || bad "无跳转提示"
[ "$RC" != "0" ] && ok "安装 abort (rc=$RC)" || bad "未 abort"
# 10c: license 已有效 → 跳过
rm -f "$D/license"
LIC_AUTO_DIRS=$W/qq/databases $B verify --auto --members $W/members.txt >/dev/null 2>&1
OUT=$(runinst)
echo "$OUT" | grep -q '已通过.*跳过' && ok "已有授权跳过验证" || bad "输出: $(echo "$OUT" | grep -i 验证 | head -2)"
# 10d: 无法检测 → 继续安装不 abort
rm -f "$D/license"
OUT=$(LIC_AUTO_DIRS=$W/empty runinst); RC=$?
echo "$OUT" | grep -q '未检测到本机QQ账号' && ok "no_local_qq 提示" || bad "输出: $(echo "$OUT" | grep -i 验证 | head -2)"
[ "$RC" = "0" ] && ok "无法检测时继续安装" || bad "被误 abort (rc=$RC)"

echo "=== 11. service.sh 自动重验证 ==="
grep -q 'verify --auto' module/service.sh && ok "service.sh 含自动重验证" || bad "service.sh 缺自动重验证"
grep -q 'verify --auto' module/menu.sh && ok "menu.sh 含自动验证" || bad "menu.sh 缺自动验证"
sh -n module/service.sh && sh -n module/menu.sh && sh -n module/customize.sh && sh -n module/bin/webuictl.sh && ok "四脚本语法 OK" || bad "脚本语法错误"
node --check module/webroot/app.js && ok "app.js 语法 OK" || bad "app.js 语法错误"

rm -f "$D/license"
echo "=== PASS=$PASS FAIL=$FAIL ==="
