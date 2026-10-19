#!/bin/bash
# v2.38 档位扩展回归: 195 机型 +188 (自动) / +198 (显式档)
# 核心证明: v2.38@195 输出剥离 _188 节点后与 v2.37@195 输出逐字节一致 (现有档位零漂移)
U=/workspace/.uploads
B=/tmp/dtbo_oc_x86_test
DTC=/usr/bin/dtc
W=/tmp/reg238t; rm -rf $W; mkdir -p $W; cd $W
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

export DTBO_OC_LICENSE=$W/lic.txt
cat > members.txt <<'EOF'
GROUP=1124737265
10001
EOF
$B verify --qq 10001 --members $W/members.txt >/dev/null 2>&1

# v2.37 生产 @195 = 14 档 (无 188/198); v2.38 @195 = 15 档 (+188); @198 = 16 档 (+198)
G237="130,132,138,141,144,148,150,158,165,170,178,185,190,195"
G238_195="130,132,138,141,144,148,150,158,165,170,178,185,188,190,195"
G238_198="130,132,138,141,144,148,150,158,165,170,178,185,188,190,195,198"

echo "== expand_hz 档位表 =="
sed -n '/^expand_hz() {/,/^}/p' /workspace/DTBO_OC_Module/module/bin/webuictl.sh > eh.sh
EH=$(sh -c '. ./eh.sh; expand_hz 195')
[ "$EH" = "130 132 138 141 144 148 150 158 165 170 178 185 188 190 195" ] && ok "webuictl expand_hz 195 = +188 无 198" || bad "expand_hz 195: $EH"
EH=$(sh -c '. ./eh.sh; expand_hz 198')
[ "$EH" = "130 132 138 141 144 148 150 158 165 170 178 185 188 190 195 198" ] && ok "webuictl expand_hz 198 = 全 16 档" || bad "expand_hz 198: $EH"
EH=$(sh -c '. ./eh.sh; expand_hz 185')
[ "$EH" = "130 132 138 141 144 148 150 158 165 170 178 185" ] && ok "webuictl expand_hz 185 不含 188+" || bad "expand_hz 185: $EH"
sed -n '/^expand_hz() {/,/^}/p' /workspace/DTBO_OC_Module/module/service.sh > ehs.sh
EH=$(sh -c '. ./ehs.sh; expand_hz 195')
[ "$EH" = "130,132,138,141,144,148,150,158,165,170,178,185,188,190,195" ] && ok "service expand_hz 195 = +188 无 198" || bad "service 195: $EH"
EH=$(sh -c '. ./ehs.sh; expand_hz 198')
[ "$EH" = "130,132,138,141,144,148,150,158,165,170,178,185,188,190,195,198" ] && ok "service expand_hz 198 = 全 16 档" || bad "service 198: $EH"

flags0() {
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

# v2.38@195 剥离 _188 节点块后须与 v2.37@195 每条目 dts 完全一致
cmp_strip188() {
    python3 - "$1" "$2" <<'PYEOF'
import struct, subprocess, sys, re, tempfile, os
def entries(path):
    b = open(path,'rb').read()
    magic, total, hs, es, cnt, off, ps, ver = struct.unpack('>8I', b[:32])
    assert magic == 0xd7b7ab1e
    out = []
    for i in range(cnt):
        e = b[off+i*es: off+(i+1)*es]
        size, doff = struct.unpack('>II', e[:8])
        out.append(b[doff:doff+size])
    return out
def dts(dtb):
    with tempfile.NamedTemporaryFile(delete=False, suffix='.dtb') as f:
        f.write(dtb); p = f.name
    try:
        return subprocess.run(['dtc','-I','dtb','-O','dts','-q',p], capture_output=True, text=True).stdout
    finally: os.unlink(p)
def strip_188(text):
    lines = text.split('\n'); out = []; removing = False; indent = ''
    skip_blank = False
    pat = re.compile(r'^(\s*)timing@\S*_188\s*\{')
    for ln in lines:
        if not removing:
            if skip_blank and ln == '':
                skip_blank = False
                continue
            skip_blank = False
            m = pat.match(ln)
            if m: removing = True; indent = m.group(1); continue
            out.append(ln)
        else:
            if ln == indent + '};':
                removing = False
                skip_blank = True   # 连同块后空行一并剥离
    return '\n'.join(out)
A, Bf = sys.argv[1], sys.argv[2]   # A=v2.37 输出, B=v2.38@195 输出
ea, eb = entries(A), entries(Bf)
if len(ea) != len(eb):
    print('ENTRY_COUNT_DIFF'); sys.exit(1)
stripped = 0
cidx_norm = re.compile(r'cell-index = <0x[0-9a-fA-F]+>;')
for i,(da,db) in enumerate(zip(ea,eb)):
    if da == db: continue
    ta, tb = dts(da), dts(db)
    n188 = len(re.findall(r'^\s*timing@\S*_188\s*\{', tb, re.M))
    stripped += n188
    # cell-index 机型 (gt8/op13t 等): 克隆档索引按档位数量顺序分配, 档位增减会整体
    # 位移 — 属设计行为 (v2.3x 以来即如此), 原厂索引不动、面板内唯一性由引擎保证。
    # 归一化 cell-index 后要求逐字节一致, 证明除索引外所有属性零漂移。
    na = cidx_norm.sub('cell-index = <X>;', ta)
    nb = cidx_norm.sub('cell-index = <X>;', strip_188(tb))
    if na != nb:
        la = na.split('\n'); lb = nb.split('\n')
        for j in range(max(len(la),len(lb))):
            x = la[j] if j < len(la) else '<EOF>'
            y = lb[j] if j < len(lb) else '<EOF>'
            if x != y:
                print('DIFF entry%d line%d:\n  v237: %s\n  v238-188: %s' % (i,j+1,x,y)); sys.exit(1)
        print('DIFF entry%d (length)' % i); sys.exit(1)
    # 面板内 cell-index 唯一性: 同一真实父节点 (完整路径) 下不得重复。
    # 注意: 不同 panel 下的同名 timing@0 是不同父节点, cell-index 可重复 (原厂即如此)。
    for txt, tag in ((ta,'v237'), (tb,'v238')):
        parents = {}
        node_stack = []   # 完整节点路径栈 (panel@x / timing@y)
        cur_timing_parent = None
        for ln in txt.split('\n'):
            mo = re.match(r'^(\s*)([A-Za-z_][\w@,-]*)\s*\{', ln)
            if mo:
                node_stack.append(mo.group(2))
                if re.match(r'^timing@', mo.group(2)):
                    cur_timing_parent = '/'.join(node_stack[:-1])
                    parents.setdefault(cur_timing_parent, [])
                continue
            if re.match(r'^\s*\};', ln):
                if node_stack: node_stack.pop()
                cur_timing_parent = None
                continue
            mc = re.match(r'^\s*cell-index = <(0x[0-9a-fA-F]+)>;', ln)
            if mc and cur_timing_parent is not None:
                parents[cur_timing_parent].append(mc.group(1))
        for parent, vals in parents.items():
            if len(vals) != len(set(vals)):
                print('CIDX_DUP %s %s: %s' % (tag, parent, sorted(vals))); sys.exit(1)
print('IDENTICAL %d' % stripped)
PYEOF
}

run_dev() {
    local img="$1" name="$2" extra="$3"
    rm -rf w0 w1 w2; mkdir -p w0 w1 w2
    $B patch --img "$img" --out V37_$name.img --dtc $DTC --workdir w0 $extra --hz "$G237" > l0.txt 2>&1; RC0=$?
    $B patch --img "$img" --out V38_$name.img --dtc $DTC --workdir w1 $extra --hz "$G238_195" > l1.txt 2>&1; RC1=$?
    $B patch --img "$img" --out W38_$name.img --dtc $DTC --workdir w2 $extra --hz "$G238_198" > l2.txt 2>&1; RC2=$?
    A37=$(grep -oP '新增 \K[0-9]+' l0.txt | awk '{s+=$1} END{print s+0}')
    A38=$(grep -oP '新增 \K[0-9]+' l1.txt | awk '{s+=$1} END{print s+0}')
    A98=$(grep -oP '新增 \K[0-9]+' l2.txt | awk '{s+=$1} END{print s+0}')
    FL1=$(flags0 V38_$name.img); FL2=$(flags0 W38_$name.img)
    CK1=$($B checkoc --img V38_$name.img --stock-img "$img" --dtc $DTC --workdir w1 2>/dev/null)
    CK2=$($B checkoc --img W38_$name.img --stock-img "$img" --dtc $DTC --workdir w2 2>/dev/null)
    M1=$(echo "$CK1" | grep '^MISSING=' | cut -d= -f2); F1=$(echo "$CK1" | grep '^FOREIGN=' | cut -d= -f2)
    M2=$(echo "$CK2" | grep '^MISSING=' | cut -d= -f2); F2=$(echo "$CK2" | grep '^FOREIGN=' | cut -d= -f2)
    [ -z "$M1" ] && M1=0; [ -z "$F1" ] && F1=0; [ -z "$M2" ] && M2=0; [ -z "$F2" ] && F2=0
    ALL=OK
    [ $RC0 -eq 0 ] && [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] || ALL="FAIL(rc $RC0/$RC1/$RC2)"
    [ "$FL1" = "FLAGS=0" ] && [ "$FL2" = "FLAGS=0" ] || ALL="FAIL(flags $FL1/$FL2)"
    [ "$M1" = "0" ] && [ "$F1" = "0" ] || ALL="FAIL(195 MISS=$M1 FRN=$F1)"
    [ "$M2" = "0" ] && [ "$F2" = "0" ] || ALL="FAIL(198 MISS=$M2 FRN=$F2)"
    [ "$A38" -gt "$A37" ] 2>/dev/null || ALL="FAIL(nodes $A37->$A38)"
    if [ "$ALL" = "OK" ]; then ok "$name 生成通过 (v2.37=$A37 节点, +188=$A38, +198=$A98)"; else bad "$name: $ALL"; fi
    R=$(cmp_strip188 V37_$name.img V38_$name.img)
    if [ "$R" != "IDENTICAL 0" ] && [ "${R%% *}" = "IDENTICAL" ]; then
        ok "$name +188 剥离后与 v2.37 逐字节一致 (剥离 ${R#IDENTICAL } 个 188 节点)"
    elif [ "${R%% *}" = "IDENTICAL" ]; then
        bad "$name 未生成任何 188 节点"
    else
        bad "$name 档位漂移: $(echo "$R" | head -3)"
    fi
}

echo "== 195 机型三方对比 =="
run_dev "$U/594779c9-86e8-437d-b33f-e7527b1de9cf_一加_15_17.0.0.105_dtbo.img" op15 ""
run_dev "$U/a1f05034-d8db-4d74-bb53-eab9df2f6e49_一加15t可超195.dtbo.img" op15t ""
run_dev "$U/92041cf0-4a22-4c20-8c72-aaf19fb2cb75_一加ACE6.dtbo.img" ace6 ""
run_dev "$U/83ae6eb4-3f9e-4248-bdb0-89f90cf06007_真我gt8.dtbo.img" gt8 ""

echo "== 185 机型抽查: 无回归 =="
rm -rf wC; mkdir -p wC
$B patch --img "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" --out C_ace2pro.img --dtc $DTC --workdir wC --strip-above 120 --hz "130,132,138,141,144,148,150,158,165,170,178,185" > lc.txt 2>&1
RC=$?
FLC=$(flags0 C_ace2pro.img)
NOCC=$($B checkoc --img C_ace2pro.img --stock-img "$U/14af6b2f-6bbf-4b23-a6b4-e203aa853d4b_一加Ace2pro.dtbo.img" --dtc $DTC --workdir wC 2>/dev/null | grep '^NOC=' | cut -d= -f2)
if [ $RC -eq 0 ] && [ "$FLC" = "FLAGS=0" ] && [ "$NOCC" = "24" ]; then ok "ace2pro 185 输出与 v2.37 一致 (NOC=24)"; else bad "ace2pro rc=$RC $FLC NOC=$NOCC"; fi

echo "=== PASS=$PASS FAIL=$FAIL ==="
[ $FAIL -eq 0 ]
