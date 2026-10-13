/*
 * dtbo_oc.c — Magisk 模块核心：DTBO 刷新率超频工具
 *
 * 功能：
 *   - 解析/重建 Android DTBO 镜像表 (v0/v1, 未压缩条目；v2/压缩条目安全拒绝)
 *   - 移植 DTBORefreshOverclocker 的 AVB 信封重建逻辑(哈希描述符 + 认证摘要 + footer)
 *   - 调用 dtc 完成 dtb<->dts 转换，仅重编译被修改的条目，未修改条目逐字节保留
 *   - 按"教程锚点模型"克隆时序节点生成超频档位(保留原档位)
 *
 * 算法依据：网友实测教程数据 (120Hz 基准 -> 144/165 已验证)
 *   - porch/phy/transfer: 以 p=hz/base 为自变量的分段线性插值(锚点 1.0/1.2/1.375)
 *   - clock: old * (hz/base) * (HV_new/HV_old) * margin (margin 默认 <160Hz:1.0122, >=160Hz:1.0215,
 *     在 120Hz 基准上恰好复现教程实机镜像的 144:1315674752 / 165:1505156480)
 *   - oplus,apollo-panel-vsync-width: round(old * base / hz)
 *   - oplus,adfr-min-fps-mapping-table: 首单元改为目标刷新率
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <poll.h>
#include <dirent.h>
#include <stdarg.h>
#include <ctype.h>

/* ------------------------------------------------------------------ */
/* 基础工具                                                            */
/* ------------------------------------------------------------------ */

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[FATAL] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static void *xmalloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) die("OOM"); return p; }
static void *xrealloc(void *p, size_t n) { p = realloc(p, n ? n : 1); if (!p) die("OOM"); return p; }
static char *xstrdup(const char *s) { char *p = strdup(s); if (!p) die("OOM"); return p; }

static uint8_t *read_file(const char *path, size_t *out_n) {
    FILE *f = fopen(path, "rb");
    if (!f) die("无法读取 %s: %s", path, strerror(errno));
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n < 0) die("ftell 失败 %s", path);
    uint8_t *b = xmalloc((size_t)n + 1);
    if (n > 0 && fread(b, 1, (size_t)n, f) != (size_t)n) die("读取不完整 %s", path);
    b[n] = 0;
    fclose(f);
    *out_n = (size_t)n;
    return b;
}

static void write_file(const char *path, const uint8_t *b, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) die("无法写入 %s: %s", path, strerror(errno));
    if (n && fwrite(b, 1, n, f) != n) die("写入不完整 %s", path);
    fclose(f);
}

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p)<<32)|be32(p+4); }
static void put32(uint8_t *p, uint32_t v) { p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)(v>>32)); put32(p+4, (uint32_t)v); }

/* ------------------------------------------------------------------ */
/* SHA-256 / SHA-512 (AVB 摘要与认证哈希)                              */
/* ------------------------------------------------------------------ */

typedef struct { uint32_t s[8]; uint64_t len; uint8_t buf[64]; size_t buflen; } Sha256;
static const uint32_t K256[64] = {
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROR32(x,n) (((x)>>(n))|((x)<<(32-(n))))
static void sha256_init(Sha256 *c){ static const uint32_t iv[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19}; memcpy(c->s,iv,32); c->len=0; c->buflen=0; }
static void sha256_block(Sha256 *c, const uint8_t blk[64]) {
    uint32_t w[64], a,b,d,e,f,g,h,cc, t1,t2; int i;
    for (i=0;i<16;i++) w[i]=be32(blk+i*4);
    for (;i<64;i++){ uint32_t s0=ROR32(w[i-15],7)^ROR32(w[i-15],18)^(w[i-15]>>3); uint32_t s1=ROR32(w[i-2],17)^ROR32(w[i-2],19)^(w[i-2]>>10); w[i]=w[i-16]+s0+w[i-7]+s1; }
    a=c->s[0];b=c->s[1];cc=c->s[2];d=c->s[3];e=c->s[4];f=c->s[5];g=c->s[6];h=c->s[7];
    for (i=0;i<64;i++){
        uint32_t S1=ROR32(e,6)^ROR32(e,11)^ROR32(e,25); uint32_t ch=(e&f)^((~e)&g);
        t1=h+S1+ch+K256[i]+w[i];
        uint32_t S0=ROR32(a,2)^ROR32(a,13)^ROR32(a,22); uint32_t mj=(a&b)^(a&cc)^(b&cc);
        t2=S0+mj; h=g;g=f;f=e;e=d+t1;d=cc;cc=b;b=a;a=t1+t2;
    }
    c->s[0]+=a;c->s[1]+=b;c->s[2]+=cc;c->s[3]+=d;c->s[4]+=e;c->s[5]+=f;c->s[6]+=g;c->s[7]+=h;
}
static void sha256_update(Sha256 *c, const void *data, size_t n) {
    const uint8_t *p = data; c->len += n;
    while (n) { size_t t = 64 - c->buflen; if (t > n) t = n; memcpy(c->buf + c->buflen, p, t); c->buflen += t; p += t; n -= t;
        if (c->buflen == 64) { sha256_block(c, c->buf); c->buflen = 0; } }
}
static void sha256_final(Sha256 *c, uint8_t out[32]) {
    uint64_t bits = c->len * 8; uint8_t pad = 0x80; sha256_update(c, &pad, 1);
    uint8_t z = 0; while (c->buflen != 56) sha256_update(c, &z, 1);
    uint8_t l[8]; for (int i=0;i<8;i++) l[i]=(uint8_t)(bits>>(56-8*i)); c->len -= 8; /* 防重复计数 */
    sha256_update(c, l, 8);
    for (int i=0;i<8;i++) put32(out+i*4, c->s[i]);
}
static void sha256_buf(const void *data, size_t n, uint8_t out[32]) { Sha256 c; sha256_init(&c); sha256_update(&c, data, n); sha256_final(&c, out); }
static void sha256_2buf(const void *a, size_t an, const void *b, size_t bn, uint8_t out[32]) { Sha256 c; sha256_init(&c); sha256_update(&c,a,an); sha256_update(&c,b,bn); sha256_final(&c,out); }

typedef struct { uint64_t s[8]; uint64_t len; uint8_t buf[128]; size_t buflen; } Sha512;
static const uint64_t K512[80] = {
0x428a2f98d728ae22ULL,0x7137449123ef65cdULL,0xb5c0fbcfec4d3b2fULL,0xe9b5dba58189dbbcULL,
0x3956c25bf348b538ULL,0x59f111f1b605d019ULL,0x923f82a4af194f9bULL,0xab1c5ed5da6d8118ULL,
0xd807aa98a3030242ULL,0x12835b0145706fbeULL,0x243185be4ee4b28cULL,0x550c7dc3d5ffb4e2ULL,
0x72be5d74f27b896fULL,0x80deb1fe3b1696b1ULL,0x9bdc06a725c71235ULL,0xc19bf174cf692694ULL,
0xe49b69c19ef14ad2ULL,0xefbe4786384f25e3ULL,0x0fc19dc68b8cd5b5ULL,0x240ca1cc77ac9c65ULL,
0x2de92c6f592b0275ULL,0x4a7484aa6ea6e483ULL,0x5cb0a9dcbd41fbd4ULL,0x76f988da831153b5ULL,
0x983e5152ee66dfabULL,0xa831c66d2db43210ULL,0xb00327c898fb213fULL,0xbf597fc7beef0ee4ULL,
0xc6e00bf33da88fc2ULL,0xd5a79147930aa725ULL,0x06ca6351e003826fULL,0x142929670a0e6e70ULL,
0x27b70a8546d22ffcULL,0x2e1b21385c26c926ULL,0x4d2c6dfc5ac42aedULL,0x53380d139d95b3dfULL,
0x650a73548baf63deULL,0x766a0abb3c77b2a8ULL,0x81c2c92e47edaee6ULL,0x92722c851482353bULL,
0xa2bfe8a14cf10364ULL,0xa81a664bbc423001ULL,0xc24b8b70d0f89791ULL,0xc76c51a30654be30ULL,
0xd192e819d6ef5218ULL,0xd69906245565a910ULL,0xf40e35855771202aULL,0x106aa07032bbd1b8ULL,
0x19a4c116b8d2d0c8ULL,0x1e376c085141ab53ULL,0x2748774cdf8eeb99ULL,0x34b0bcb5e19b48a8ULL,
0x391c0cb3c5c95a63ULL,0x4ed8aa4ae3418acbULL,0x5b9cca4f7763e373ULL,0x682e6ff3d6b2b8a3ULL,
0x748f82ee5defb2fcULL,0x78a5636f43172f60ULL,0x84c87814a1f0ab72ULL,0x8cc702081a6439ecULL,
0x90befffa23631e28ULL,0xa4506cebde82bde9ULL,0xbef9a3f7b2c67915ULL,0xc67178f2e372532bULL,
0xca273eceea26619cULL,0xd186b8c721c0c207ULL,0xeada7dd6cde0eb1eULL,0xf57d4f7fee6ed178ULL,
0x06f067aa72176fbaULL,0x0a637dc5a2c898a6ULL,0x113f9804bef90daeULL,0x1b710b35131c471bULL,
0x28db77f523047d84ULL,0x32caab7b40c72493ULL,0x3c9ebe0a15c9bebcULL,0x431d67c49c100d4cULL,
0x4cc5d4becb3e42b6ULL,0x597f299cfc657e2aULL,0x5fcb6fab3ad6faecULL,0x6c44198c4a475817ULL};
#define ROR64(x,n) (((x)>>(n))|((x)<<(64-(n))))
static void sha512_init(Sha512 *c){ static const uint64_t iv[8]={0x6a09e667f3bcc908ULL,0xbb67ae8584caa73bULL,0x3c6ef372fe94f82bULL,0xa54ff53a5f1d36f1ULL,0x510e527fade682d1ULL,0x9b05688c2b3e6c1fULL,0x1f83d9abfb41bd6bULL,0x5be0cd19137e2179ULL}; memcpy(c->s,iv,64); c->len=0; c->buflen=0; }
static void sha512_block(Sha512 *c, const uint8_t blk[128]) {
    uint64_t w[80],v[8],t1,t2; int i;
    for (i=0;i<16;i++) w[i]=be64(blk+i*8);
    for (;i<80;i++){ uint64_t s0=ROR64(w[i-15],1)^ROR64(w[i-15],8)^(w[i-15]>>7); uint64_t s1=ROR64(w[i-2],19)^ROR64(w[i-2],61)^(w[i-2]>>6); w[i]=w[i-16]+s0+w[i-7]+s1; }
    memcpy(v,c->s,64);
    for (i=0;i<80;i++){
        uint64_t S1=ROR64(v[4],14)^ROR64(v[4],18)^ROR64(v[4],41); uint64_t ch=(v[4]&v[5])^((~v[4])&v[6]);
        t1=v[7]+S1+ch+K512[i]+w[i];
        uint64_t S0=ROR64(v[0],28)^ROR64(v[0],34)^ROR64(v[0],39); uint64_t mj=(v[0]&v[1])^(v[0]&v[2])^(v[1]&v[2]);
        t2=S0+mj; v[7]=v[6];v[6]=v[5];v[5]=v[4];v[4]=v[3]+t1;v[3]=v[2];v[2]=v[1];v[1]=v[0];v[0]=t1+t2;
    }
    for (i=0;i<8;i++) c->s[i]+=v[i];
}
static void sha512_update(Sha512 *c, const void *data, size_t n) {
    const uint8_t *p = data; c->len += n;
    while (n) { size_t t = 128 - c->buflen; if (t > n) t = n; memcpy(c->buf + c->buflen, p, t); c->buflen += t; p += t; n -= t;
        if (c->buflen == 128) { sha512_block(c, c->buf); c->buflen = 0; } }
}
static void sha512_final(Sha512 *c, uint8_t out[64]) {
    uint64_t bits = c->len * 8; uint8_t pad = 0x80; sha512_update(c, &pad, 1);
    uint8_t z = 0; while (c->buflen != 112) sha512_update(c, &z, 1);
    uint8_t l[16]; for (int i=0;i<16;i++) l[i]=(uint8_t)(bits>>(120-8*i)); c->len -= 16;
    sha512_update(c, l, 16);
    for (int i=0;i<8;i++) put64(out+i*8, c->s[i]);
}
static void sha512_2buf(const void *a, size_t an, const void *b, size_t bn, uint8_t out[64]) { Sha512 c; sha512_init(&c); sha512_update(&c,a,an); sha512_update(&c,b,bn); sha512_final(&c,out); }

/* ------------------------------------------------------------------ */
/* DTBO 表解析/重建 (v0/v1; 压缩条目安全拒绝)                          */
/* ------------------------------------------------------------------ */

#define DTBO_MAGIC 0xd7b7ab1eu

typedef struct {
    uint32_t dt_size, dt_offset, id, rev;
    uint32_t flags; int has_flags;      /* v1 */
    uint32_t custom[4]; int custom_count; /* v0:4 v1:3 */
    int comp;                            /* flags & 0xf */
    const uint8_t *stored;               /* 指向镜像内数据 */
} DtboEntry;

typedef struct {
    uint8_t *b; size_t n;
    uint32_t magic, total, hdr_size, entry_size, count, entries_off, page_size, version;
    DtboEntry *e;
    size_t prefix_len;
} DtboImg;

static void dtbo_parse(DtboImg *img, uint8_t *bytes, size_t n) {
    memset(img, 0, sizeof(*img));
    img->b = bytes; img->n = n;
    if (n < 32) die("DTBO 文件小于 32 字节");
    img->magic = be32(bytes);
    img->total = be32(bytes+4);
    img->hdr_size = be32(bytes+8);
    img->entry_size = be32(bytes+12);
    img->count = be32(bytes+16);
    img->entries_off = be32(bytes+20);
    img->page_size = be32(bytes+24);
    img->version = be32(bytes+28);
    if (img->magic != DTBO_MAGIC) die("不是 DTBO 镜像: magic=0x%x", img->magic);
    if (img->hdr_size != 32) die("不支持的 DTBO header_size=%u", img->hdr_size);
    if (img->version == 2) die("DTBO version=2 暂不支持 (AOSP 主线亦无 v2 设备)");
    if (img->version > 1) die("不支持的 DTBO version=%u", img->version);
    uint32_t expect = 32;
    if (img->entry_size != expect) die("DTBO v%u 的 dt_entry_size 应为 %u, 实际 %u", img->version, expect, img->entry_size);
    if (img->count < 1 || img->count > 4096) die("异常的 DTBO entry_count=%u", img->count);
    if (img->entries_off < 32 || img->entries_off % 4) die("异常的 dt_entries_offset=%u", img->entries_off);
    uint64_t mend = (uint64_t)img->entries_off + (uint64_t)img->entry_size * img->count;
    if (mend > n) die("DTBO entry table 越界");
    if (img->total < mend || img->total > n) die("DTBO total_size=%u 与文件长度 %zu 不匹配", img->total, n);
    img->e = xmalloc(sizeof(DtboEntry) * img->count);
    size_t first_payload = img->total;
    for (uint32_t i = 0; i < img->count; i++) {
        const uint8_t *p = bytes + img->entries_off + (size_t)i * img->entry_size;
        DtboEntry *e = &img->e[i];
        memset(e, 0, sizeof(*e));
        e->dt_size = be32(p); e->dt_offset = be32(p+4); e->id = be32(p+8); e->rev = be32(p+12);
        if (img->version == 0) { e->has_flags = 0; e->custom_count = 4; for (int k=0;k<4;k++) e->custom[k]=be32(p+16+4*k); }
        else { e->has_flags = 1; e->flags = be32(p+16); e->custom_count = 3; for (int k=0;k<3;k++) e->custom[k]=be32(p+20+4*k); }
        if (e->dt_size == 0) die("entry[%u] dt_size=0", i);
        uint64_t end = (uint64_t)e->dt_offset + e->dt_size;
        if (e->dt_offset < mend || end > img->total) die("entry[%u] 数据区越界", i);
        e->comp = e->has_flags ? (int)(e->flags & 0xfu) : 0;
        e->stored = bytes + e->dt_offset;
        if (e->dt_offset < first_payload) first_payload = e->dt_offset;
    }
    if (first_payload < mend) die("DTBO payload 与 entry table 重叠");
    img->prefix_len = first_payload;
}

/* ------------------------------------------------------------------ */
/* AVB 信封 (移植自 DTBORefreshOverclocker AvbImageEnvelope.kt)         */
/* ------------------------------------------------------------------ */

typedef struct {
    int footer, vbmeta, size, orig_size;
    int detached;
    uint32_t major, minor;
} AvbLayout;

typedef struct {
    int footer_off[32]; int footer_cnt;
    AvbLayout layout; int has_layout;
    int signed_; char algo[32];
    /* hash descriptor 位置(绝对偏移) */
    int hash_desc_off;           /* 描述符起始(vbmeta 文件内) */
    int hash_digest_off;         /* 摘要起始(镜像内绝对) */
    int hash_salt_off;           /* 盐起始(镜像内绝对) */
    int hash_salt_len, hash_digest_len, hash_alg; /* 0=sha256 1=sha512 */
    int64_t auth_hash_off; int auth_hash_len;    /* 认证哈希(镜像内绝对), -1 无 */
    int64_t auth_size, aux_size;
} AvbInfo;

static int avb_bounded(int64_t v, int64_t limit) { return v >= 0 && v <= limit; }

static int avb_parse_footer_at(const uint8_t *b, size_t n, int64_t total, int f, AvbLayout *out) {
    if ((size_t)f + 64 > n) return -1;
    uint32_t major = be32(b+f+4), minor = be32(b+f+8);
    if (major == 0) return -1;
    for (int i = f+36; i < f+64; i++) if (b[i]) return -1;   /* 保留区非零 */
    int64_t orig = (int64_t)be64(b+f+12);
    if (orig < 32) return -1;
    int64_t off = (int64_t)be64(b+f+20);
    int64_t size = (int64_t)be64(b+f+28);
    if (size < 256) return -1;
    int64_t m = total > orig ? total : orig;
    if (off < m || off + size > f) return -1;
    if (!avb_bounded(off, (int64_t)n) || !avb_bounded(size, (int64_t)n)) return -1;
    out->footer = f; out->orig_size = (int)orig; out->major = major; out->minor = minor;
    out->vbmeta = (int)off; out->size = (int)size;
    /* detached 判定: vbmeta 区全零 */
    int allz = 1;
    for (int64_t i = off; i < off + size; i++) if (b[i]) { allz = 0; break; }
    out->detached = allz;
    if (allz) return 0;
    if (be32(b + off) != 0x41564230u) return -1;  /* AVB0 */
    int64_t auth = (int64_t)be64(b+off+12);
    int64_t aux = (int64_t)be64(b+off+20);
    if (auth % 64 || aux % 64 || 256 + auth + aux != size) return -1;
    int64_t lim;
    lim = size - 256;
    int64_t ho=(int64_t)be64(b+off+32), hs=(int64_t)be64(b+off+40);
    if (!avb_bounded(ho,auth)||!avb_bounded(hs,auth-ho)) return -1;
    int64_t so=(int64_t)be64(b+off+48), ss=(int64_t)be64(b+off+56);
    if (!avb_bounded(so,auth)||!avb_bounded(ss,auth-so)) return -1;
    int64_t po=(int64_t)be64(b+off+64), ps=(int64_t)be64(b+off+72);
    if (!avb_bounded(po,aux)||!avb_bounded(ps,aux-po)) return -1;
    int64_t pmo=(int64_t)be64(b+off+80), pms=(int64_t)be64(b+off+88);
    if (!avb_bounded(pmo,aux)||!avb_bounded(pms,aux-pmo)) return -1;
    int64_t doff=(int64_t)be64(b+off+96), dsz=(int64_t)be64(b+off+104);
    if (!avb_bounded(doff,aux)||!avb_bounded(dsz,aux-doff)) return -1;
    /* descriptor 逐个走查 */
    int64_t p = off + 256 + auth + doff, end = p + dsz;
    while (p < end) {
        if (end - p < 16) return -1;
        int64_t rem = (int64_t)be64(b+p+8);
        if (rem < 0 || rem > end - p - 16 || rem % 8) return -1;
        p += 16 + rem;
    }
    return 0;
}

static void avb_inspect(const uint8_t *b, size_t n, int64_t total, AvbInfo *info) {
    memset(info, 0, sizeof(*info));
    info->auth_hash_off = -1;
    if (total < 32 || (size_t)total > n) die("无效的 DTBO 长度");
    int candidates = 0;
    AvbLayout layouts[32]; int layout_cnt = 0;
    for (int64_t off = total; off <= (int64_t)n - 4; off++) {
        if (b[off]!=0x41||b[off+1]!=0x56||b[off+2]!=0x42||b[off+3]!=0x66) continue;
        candidates++;
        AvbLayout l;
        if (avb_parse_footer_at(b, n, total, (int)off, &l) == 0) {
            if (layout_cnt < 32) layouts[layout_cnt++] = l;
            info->footer_off[info->footer_cnt < 32 ? info->footer_cnt++ : 31] = (int)off;
        }
    }
    if (candidates == 0) { info->has_layout = 0; return; }
    if (layout_cnt == 0) die("找到 AVBf magic，但没有任何候选通过结构验证");
    AvbLayout *sel = &layouts[0];
    for (int i = 1; i < layout_cnt; i++) {
        AvbLayout *o = &layouts[i];
        if (o->vbmeta != sel->vbmeta || o->size != sel->size || o->orig_size != sel->orig_size ||
            o->major != sel->major || o->minor != sel->minor || o->detached != sel->detached)
            die("找到多个有效 AVB footer，且内容不一致，无法安全重建");
    }
    if (sel->major != 1 || sel->minor != 0) die("不支持的 AVB footer 版本 %u.%u", sel->major, sel->minor);
    /* 区域间必须全零 */
    for (int64_t i = total; i < sel->vbmeta; i++) if (b[i]) die("AVB 区域外存在未知数据 (0x%llx)", (unsigned long long)i);
    int64_t pe = (int64_t)sel->vbmeta + sel->size;
    for (int i = 0; i < layout_cnt; i++) {
        if (layouts[i].footer < pe) die("AVB 区域外存在未知数据或 footer 重叠");
        for (int64_t j = pe; j < layouts[i].footer; j++) if (b[j]) die("AVB 区域外存在未知数据 (0x%llx)", (unsigned long long)j);
        pe = layouts[i].footer + 64;
    }
    for (size_t j = (size_t)pe; j < n; j++) if (b[j]) die("AVB 区域外存在未知数据 (0x%zx)", j);
    info->layout = *sel; info->has_layout = 1;
    if (sel->detached) return;
    /* vbmeta 头 */
    const uint8_t *v = b + sel->vbmeta;
    if (be32(v+4) != 1 || be32(v+8) > 3) die("不支持的 AVB vbmeta required version");
    int64_t auth = (int64_t)be64(v+12), aux = (int64_t)be64(v+20);
    info->auth_size = auth; info->aux_size = aux;
    int32_t algo = (int32_t)be32(v+28);
    int signed_ = (algo != 0 || auth != 0);
    info->signed_ = signed_;
    snprintf(info->algo, sizeof(info->algo), "AVB_ALGORITHM_%d", algo);
    if (algo==1) strcpy(info->algo,"SHA256_RSA2048");
    else if (algo==2) strcpy(info->algo,"SHA256_RSA4096");
    else if (algo==3) strcpy(info->algo,"SHA256_RSA8192");
    else if (algo==4) strcpy(info->algo,"SHA512_RSA2048");
    else if (algo==5) strcpy(info->algo,"SHA512_RSA4096");
    else if (algo==6) strcpy(info->algo,"SHA512_RSA8192");
    else if (algo==0) strcpy(info->algo,"NONE");
    int64_t hash_off = (int64_t)be64(v+32), hash_size = (int64_t)be64(v+40);
    int64_t sig_off = (int64_t)be64(v+48), sig_size = (int64_t)be64(v+56);
    int64_t doff = (int64_t)be64(v+96), dsz = (int64_t)be64(v+104);
    if (signed_) {
        int alg512 = (algo >= 4 && algo <= 6);
        int expect = alg512 ? 64 : 32;
        if (hash_size != expect) die("AVB 认证摘要长度无效: %lld", (long long)hash_size);
        if (sig_size <= 0) die("AVB 标记为已签名，但签名数据为空");
        info->auth_hash_off = sel->vbmeta + 256 + hash_off;
        info->auth_hash_len = expect;
        /* 校验认证哈希 */
        Sha256 c1; Sha512 c2;
        if (!alg512) { sha256_init(&c1); sha256_update(&c1, v, 256); sha256_update(&c1, v+256+auth, aux); sha256_final(&c1, (uint8_t[32]){0}); }
        uint8_t calc[64];
        if (alg512) sha512_2buf(v, 256, v+256+auth, aux, calc);
        else sha256_2buf(v, 256, v+256+auth, aux, calc);
        if (memcmp(calc, b + info->auth_hash_off, expect)) die("AVB vbmeta 认证摘要校验失败");
    }
    /* 遍历 descriptor, 取唯一的 dtbo hash descriptor */
    int64_t p = sel->vbmeta + 256 + auth + doff;
    int64_t end = p + dsz;
    int fields = 0;
    while (p < end) {
        int64_t tag = (int64_t)be64(b+p);
        int64_t rem = (int64_t)be64(b+p+8);
        int64_t next = p + 16 + rem;
        if (tag == 2) {
            if (rem < 116) die("AVB hash descriptor 截断");
            int64_t name_sz = be32(b+p+56), salt_sz = be32(b+p+60), dig_sz = be32(b+p+64);
            int64_t budget = next - p - 132;
            if (name_sz < 0 || salt_sz < 0 || dig_sz < 0 || name_sz + salt_sz + dig_sz > budget) die("AVB hash descriptor 长度越界");
            if (memcmp(b+p+132, "dtbo", 4) || name_sz != 4) die("不支持修改分区名称非 dtbo 的 AVB 描述符");
            char alg[33]; memset(alg, 0, sizeof(alg));
            memcpy(alg, b+p+24, 32);
            for (int k=0;k<32;k++) if (alg[k]==0) { alg[k]=0; break; }
            if (!strcmp(alg, "sha256")) { info->hash_alg = 0; if (dig_sz != 32) die("AVB 摘要长度无效"); }
            else if (!strcmp(alg, "sha512")) { info->hash_alg = 1; if (dig_sz != 64) die("AVB 摘要长度无效"); }
            else die("不支持的 AVB 哈希算法: %s", alg);
            info->hash_desc_off = (int)p;
            info->hash_salt_off = (int)(p + 132 + name_sz);
            info->hash_salt_len = (int)salt_sz;
            info->hash_digest_off = (int)(p + 132 + name_sz + salt_sz);
            info->hash_digest_len = (int)dig_sz;
            /* 长度字段必须与 total 一致 */
            if ((int64_t)be64(b+p+16) != total) die("AVB 哈希覆盖范围与 DTBO total_size 不一致");
            fields++;
        } else if (tag != 0) {
            if (!signed_) die("暂不支持重建 AVB descriptor 类型 %lld", (long long)tag);
        }
        p = next;
    }
    if (fields != 1) die("需要唯一的 dtbo AVB hash descriptor (实际 %d)", fields);
    /* 摘要校验 */
    uint8_t calc[64];
    if (info->hash_alg == 0) sha256_2buf(b + info->hash_salt_off, info->hash_salt_len, b, total, calc);
    else sha512_2buf(b + info->hash_salt_off, info->hash_salt_len, b, total, calc);
    if (memcmp(calc, b + info->hash_digest_off, info->hash_digest_len)) die("AVB 摘要校验失败");
}

/* AVB 重建: 返回新镜像(保持原容器大小与布局) */
static uint8_t *avb_rebuild(const uint8_t *orig, size_t orig_n, int orig_total,
                            const uint8_t *payload, size_t payload_n, size_t *out_n) {
    AvbInfo info;
    avb_inspect(orig, orig_n, orig_total, &info);   /* 输入必须是合法信封 */
    int signed_ = info.signed_;
    if (!info.has_layout) {
        /* 无 AVB 结构 */
        if (orig_n != (size_t)orig_total && payload_n > orig_n) die("新 DTBO 超出原分区镜像容量");
        uint8_t *r = xmalloc(orig_n == (size_t)orig_total ? payload_n : orig_n);
        memcpy(r, payload, payload_n);
        if (orig_n != (size_t)orig_total) memset(r + payload_n, 0, orig_n - payload_n);
        *out_n = orig_n == (size_t)orig_total ? payload_n : orig_n;
        /* 输出自检 */
        AvbInfo chk; avb_inspect(r, *out_n, (int)payload_n, &chk);
        return r;
    }
    AvbLayout *L = &info.layout;
    if (L->orig_size != orig_total) die("AVB footer 原始大小与 DTBO 不匹配");
    uint8_t *vbmeta = xmalloc((size_t)L->size);
    memcpy(vbmeta, orig + L->vbmeta, (size_t)L->size);
    if (!L->detached) {
        /* 更新 hash descriptor 的 image_size 与 digest(偏移相对镜像 → 相对 vbmeta) */
        int64_t ds_off = (int64_t)info.hash_desc_off - L->vbmeta;
        put64(vbmeta + ds_off + 16, payload_n);
        uint8_t dig[64];
        if (info.hash_alg == 0) sha256_2buf(orig + info.hash_salt_off, info.hash_salt_len, payload, payload_n, dig);
        else sha512_2buf(orig + info.hash_salt_off, info.hash_salt_len, payload, payload_n, dig);
        memcpy(vbmeta + (info.hash_digest_off - L->vbmeta), dig, (size_t)info.hash_digest_len);
    }
    if (signed_ && info.auth_hash_off >= 0) {
        uint8_t ad[64];
        if (info.auth_hash_len == 32) sha256_2buf(vbmeta, 256, vbmeta + 256 + info.auth_size, info.aux_size, ad);
        else sha512_2buf(vbmeta, 256, vbmeta + 256 + info.auth_size, info.aux_size, ad);
        memcpy(vbmeta + (info.auth_hash_off - L->vbmeta), ad, (size_t)info.auth_hash_len);
    }
    int64_t new_off = ((int64_t)payload_n + 4095) / 4096 * 4096;
    if (new_off + L->size > info.footer_off[0]) die("新 DTBO 与 AVB 尾部重叠，超出可用容量");
    uint8_t *r = xmalloc(orig_n);
    memset(r, 0, orig_n);
    memcpy(r, payload, payload_n);
    memcpy(r + new_off, vbmeta, (size_t)L->size);
    for (int i = 0; i < info.footer_cnt; i++) {
        int f = info.footer_off[i];
        memcpy(r + f, orig + f, 64);
        put64(r + f + 12, payload_n);
        put64(r + f + 20, new_off);
    }
    free(vbmeta);
    /* 输出自检 */
    AvbInfo chk; avb_inspect(r, orig_n, (int)payload_n, &chk);
    *out_n = orig_n;
    return r;
}

/* ------------------------------------------------------------------ */
/* DTS 解析与时序模型                                                  */
/* ------------------------------------------------------------------ */

#define MAX_LINES 262144
#define MAX_NODES 8192

typedef struct {
    int start, end;                 /* 行区间 [start,end) */
    char name[160];                 /* timing@ 后的名字 */
    int is_dynamic;
    int has_rate, has_width, has_height, has_clock, has_vfp, has_vbp, has_vpw, has_hfp, has_hbp, has_hpw;
    int has_phy, has_transfer, has_vsync, has_adfr;
    uint32_t rate, width, height, clock, vfp, vbp, vpw, hfp, hbp, hpw, transfer, vsync;
    uint8_t phy[128]; int phy_len;
    int adfr_cells[8]; int adfr_n;          /* 解析出的 cell 值 */
    char adfr_rest[256];                    /* 第二个 cell 起的原始文本 */
    char adfr_rest2[256];                   /* 第三个 cell 起的原始文本 (gt7p 144 档第二 cell 需替换) */
} TNode;

typedef struct {
    char **lines; int n;
} Dts;

static void dts_load(Dts *d, const char *path) {
    size_t n; uint8_t *b = read_file(path, &n);
    int cap = 4096; d->lines = xmalloc(sizeof(char*) * cap); d->n = 0;
    char *cur = (char*)b; 
    for (size_t i = 0; i <= n; i++) {
        if ((i == n || b[i] == '\n')) {
            if (d->n == cap) { cap *= 2; d->lines = xrealloc(d->lines, sizeof(char*) * cap); }
            size_t len = (char*)b + i - cur;
            while (len > 0 && (cur[len-1]=='\r')) len--;
            cur[len] = 0;
            d->lines[d->n++] = xstrdup(cur);
            cur = (char*)b + i + 1;
        }
    }
    if (d->n >= MAX_LINES) die("dts 行数过多");
    free(b);
}

static void dts_free(Dts *d) { for (int i=0;i<d->n;i++) free(d->lines[i]); free(d->lines); }

static void dts_save(Dts *d, const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) die("无法写入 %s", path);
    for (int i = 0; i < d->n; i++) { fputs(d->lines[i], f); fputc('\n', f); }
    fclose(f);
}

/* 统计一行中字符串外的大括号数量 */
static int brace_delta(const char *s, int *open_at_end) {
    int delta = 0, in_str = 0;
    *open_at_end = 0;
    for (const char *p = s; *p; p++) {
        if (in_str) {
            if (*p == '\\') { if (p[1]) p++; }
            else if (*p == '"') in_str = 0;
            continue;
        }
        if (*p == '"') { in_str = 1; continue; }
        if (*p == '{') { delta++; *open_at_end = 1; }
        else if (*p == '}') { delta--; *open_at_end = 0; }
        else if (*p == ';' && delta == 0) { /* 无关 */ }
    }
    return delta;
}

/* 解析属性行: 成功返回 1 并填充 name(<=127) 与 value(指向行内首个非空白 value, 已去除尾部分号) */
static int parse_prop_line(const char *line, char *name, size_t namesz, const char **val) {
    const char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (!*p) return 0;
    const char *e = p;
    while (*e && *e != ' ' && *e != '\t' && *e != '=') e++;
    size_t nl = (size_t)(e - p);
    if (nl == 0 || nl >= namesz) return 0;
    memcpy(name, p, nl); name[nl] = 0;
    const char *q = e;
    while (*q == ' ' || *q == '\t') q++;
    if (*q == '=') {
        q++;
        while (*q == ' ' || *q == '\t') q++;
        /* 去尾空白与分号 */
        const char *ve = q + strlen(q);
        while (ve > q && (ve[-1]==' '||ve[-1]=='\t'||ve[-1]==';')) ve--;
        if (ve == q) return 0;
        *val = q;
        /* value 长度限制内拷贝到静态缓冲由调用者处理; 这里只给指针(行内容以 \0 结尾) */
        return 2;
    }
    return 1; /* 布尔属性 */
}

static uint32_t parse_u32_from_val(const char *v) {
    /* "<0x90>" / "<144>" / "0x90" / "144" */
    if (*v == '<') v++;
    while (*v == ' ') v++;
    if (!strncmp(v, "0x", 2) || !strncmp(v, "0X", 2)) return (uint32_t)strtoul(v+2, NULL, 16);
    return (uint32_t)strtoul(v, NULL, 10);
}

static int parse_string_bytes(const char *v, uint8_t *out, int max) {
    /* "A;8" — 返回字符串原始字节数(不含结尾 NUL) */
    if (*v != '"') return -1;
    v++;
    int n = 0;
    while (*v && *v != '"') {
        uint8_t c;
        if (*v == '\\') {
            v++;
            switch (*v) {
                case '0': c = 0; break;
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'r': c = '\r'; break;
                case '\\': c = '\\'; break;
                case '"': c = '"'; break;
                case 'x': { char h[3] = {v[1], v[2], 0}; c = (uint8_t)strtoul(h, NULL, 16); v += 2; break; }
                default: c = (uint8_t)*v;
            }
            v++;
        } else c = (uint8_t)*v++;
        if (n < max) out[n] = c;
        n++;
    }
    return n;
}

static int parse_hex_array(const char *v, uint8_t *out, int max) {
    /* "[00 25 09]" */
    if (*v != '[') return -1;
    v++;
    int n = 0;
    while (*v && *v != ']') {
        if (*v == ' ' || *v == '\t') { v++; continue; }
        char h[3] = { v[0], v[1], 0 };
        if (!isxdigit((unsigned char)h[0]) || !isxdigit((unsigned char)h[1])) return -1;
        if (n < max) out[n] = (uint8_t)strtoul(h, NULL, 16);
        n++; v += 2;
    }
    return (*v == ']') ? n : -1;
}

static int scan_timing_nodes(Dts *d, TNode *nodes, int max_nodes) {
    /* 第一遍: 深度 */
    int *depth_after = xmalloc(sizeof(int) * (d->n + 1));
    int depth = 0;
    for (int i = 0; i < d->n; i++) {
        int oe;
        depth += brace_delta(d->lines[i], &oe);
        if (depth < 0) die("大括号失衡 (行 %d)", i + 1);
        depth_after[i] = depth;
    }
    int cnt = 0;
    for (int i = 0; i < d->n; i++) {
        const char *l = d->lines[i];
        const char *p = l;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "timing@", 7)) continue;
        const char *brace = strchr(p, '{');
        if (!brace) continue;
        /* 名字 = 行首到 '{' 之间的非空白部分 (dtc 输出形如 "timing@sa_fhd_120 {") */
        size_t nl = (size_t)(brace - p);
        while (nl > 0 && (p[nl-1] == ' ' || p[nl-1] == '\t')) nl--;
        /* 名字与 '{' 之间只允许空白 */
        int gap_ok = 1;
        for (const char *g = p + nl; g < brace; g++)
            if (*g != ' ' && *g != '\t') { gap_ok = 0; break; }
        if (!gap_ok) continue;
        if (nl < 8 || nl >= 160) continue;
        int d0 = (i == 0) ? 0 : depth_after[i-1];
        if (d0 + 1 != depth_after[i]) continue;   /* 本行恰开一个大括号 */
        /* 找闭合行 */
        int end = -1;
        for (int j = i + 1; j < d->n; j++) {
            if (depth_after[j] <= d0) { end = j + 1; break; }
        }
        if (end < 0) die("timing 节点未闭合 (行 %d)", i + 1);
        TNode *tn = &nodes[cnt++];
        memset(tn, 0, sizeof(*tn));
        memcpy(tn->name, p + 7, nl - 7); tn->name[nl - 7] = 0;
        tn->start = i; tn->end = end;
        /* 属性扫描 */
        for (int j = i + 1; j < end; j++) {
            char pn[160]; const char *val;
            int r = parse_prop_line(d->lines[j], pn, sizeof(pn), &val);
            if (r != 2) {
                if (r == 1 && !strcmp(pn, "qcom,dsi-dyn-clk-list")) tn->is_dynamic = 1;
                continue;
            }
            if (!strcmp(pn, "qcom,dsi-dyn-clk-list")) tn->is_dynamic = 1;
            else if (strstr(pn, "dyn-clk")) tn->is_dynamic = 1;
            else if (!strcmp(pn, "qcom,mdss-dsi-panel-framerate")) { tn->has_rate = 1; tn->rate = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-panel-width")) { tn->has_width = 1; tn->width = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-panel-height")) { tn->has_height = 1; tn->height = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-panel-clockrate")) {
                if (*val == '"') {
                    uint8_t sb[8]; int sn = parse_string_bytes(val, sb, 8);
                    if (sn < 1 || sn > 4) { tn->has_clock = -1; continue; }
                    uint32_t c = 0;
                    for (int k = 0; k < 4; k++) c = (c << 8) | (k < sn ? sb[k] : 0);
                    tn->clock = c;
                } else tn->clock = parse_u32_from_val(val);
                tn->has_clock = 1;
            }
            else if (!strcmp(pn, "qcom,mdss-dsi-v-front-porch")) { tn->has_vfp = 1; tn->vfp = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-v-back-porch")) { tn->has_vbp = 1; tn->vbp = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-v-pulse-width")) { tn->has_vpw = 1; tn->vpw = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-h-front-porch")) { tn->has_hfp = 1; tn->hfp = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-h-back-porch")) { tn->has_hbp = 1; tn->hbp = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-h-pulse-width")) { tn->has_hpw = 1; tn->hpw = parse_u32_from_val(val); }
            else if (!strcmp(pn, "qcom,mdss-dsi-panel-phy-timings")) {
                int pn2 = parse_hex_array(val, tn->phy, 128);
                if (pn2 < 0) { tn->has_phy = -1; continue; }
                tn->phy_len = pn2; tn->has_phy = 1;
            }
            else if (!strcmp(pn, "qcom,mdss-mdp-transfer-time-us")) { tn->has_transfer = 1; tn->transfer = parse_u32_from_val(val); }
            else if (!strcmp(pn, "oplus,apollo-panel-vsync-width")) { tn->has_vsync = 1; tn->vsync = parse_u32_from_val(val); }
            else if (!strcmp(pn, "oplus,adfr-min-fps-mapping-table")) {
                tn->has_adfr = 1;
                /* 解析所有 cell, 记录第二个起的原始文本 */
                const char *q = val;
                if (*q == '<') q++;
                int ci = 0;
                while (*q && *q != '>' && ci < 8) {
                    while (*q == ' ') q++;
                    if (!*q || *q == '>') break;
                    tn->adfr_cells[ci++] = (int)parse_u32_from_val(q);
                    while (*q && *q != ' ' && *q != '>') q++;
                }
                tn->adfr_n = ci;
                /* 第二个 cell 起的原文 */
                const char *r = val;
                if (*r == '<') r++;
                int sp = 0;
                while (*r && *r != '>') {
                    if (sp == 0 && *r == ' ') sp = 1;
                    else if (sp == 1 && *r != ' ') break;
                    r++;
                }
                snprintf(tn->adfr_rest, sizeof(tn->adfr_rest), "%s", r);
                /* 去掉结尾 '>' */
                char *gt = strchr(tn->adfr_rest, '>');
                if (gt) *gt = 0;
                /* 去尾空白 */
                int L = strlen(tn->adfr_rest);
                while (L > 0 && tn->adfr_rest[L-1] == ' ') tn->adfr_rest[--L] = 0;
                /* 第三个 cell 起的原文 (gt7p: 142/144 档需替换第二 cell 60->72);
                   adfr_rest 从第二 cell 起, 故只需再跳过一个 cell */
                const char *r2 = tn->adfr_rest;
                int cell2 = 0;   /* 已跳过的 cell 数 */
                while (*r2 && cell2 < 1) {
                    if (*r2 == ' ') { cell2++; while (*r2 == ' ') r2++; }
                    else r2++;
                }
                snprintf(tn->adfr_rest2, sizeof(tn->adfr_rest2), "%s", cell2 >= 1 ? r2 : "");
            }
        }
        if (cnt >= max_nodes) break;
    }
    free(depth_after);
    return cnt;
}

/* ---------- 教程锚点插值模型 ---------- */

static double interp3(double p, double f144, double f165) {
    if (p <= 1.0) return 1.0;
    if (p <= 1.2) return 1.0 + (p - 1.0) / 0.2 * (f144 - 1.0);
    if (p <= 1.375) return f144 + (p - 1.2) / 0.175 * (f165 - f144);
    double f = f165 + (p - 1.375) / 0.175 * (f165 - f144) * 0.5;
    if (f < f165 - 0.10) f = f165 - 0.10;
    if (f < 0.35) f = 0.35;
    if (f > 1.0) f = 1.0;
    return f;
}

/* 教程实测 phy-timings 逐字节比例 (120Hz 原始 [00 25 09 0a 1a 25 09 0a 09 02 04 00 1e 0f]) */
static const double PHY_F144[14] = {0,0.757,0.778,0.700,0.885,0.919,0.778,0.700,0.889,1.0,1.0,0,0.800,0.800};
static const double PHY_F165[14] = {0,0.703,0.778,0.600,0.846,0.892,0.778,0.700,0.889,1.0,1.0,0,0.767,0.867};
static const double PHY_F144_AVG = 0.834, PHY_F165_AVG = 0.759;

static int clamp_round(double v, int lo, int hi) {
    int r = (int)(v + 0.5);
    if (r < lo) r = lo;
    if (r > hi) r = hi;
    return r;
}

typedef struct {
    int hz[16]; int n;
    double margin_low, margin_high;
    int modify_phy;
    int wxh_filter; uint32_t wx, wy;
    char exclude[256];
    char include[256];
    uint32_t ov_hz[16]; uint64_t ov_clk[16]; int ov_n;
    int gt7p;   /* GT7 Pro 竞速版 (piloti/AE035): 简单克隆模式 — 基准 sa_fhd 动态节点,
                   保留 dyn-clk-list (改首项), porch/phy/vsync 保持原值;
                   时钟/transfer/adfr 用 GT7P_RATES 实测表 (实机 120->130/142/144 已验证),
                   --clock-override 可覆盖时钟 */
} PatchCfg;

static uint64_t clock_override(const PatchCfg *c, int hz) {
    for (int i = 0; i < c->ov_n; i++) if (c->ov_hz[i] == (uint32_t)hz) return c->ov_clk[i];
    return 0;
}

/* GT7P 竞速版实测档位表 (实机验证镜像逐属性提取):
   clk    = qcom,mdss-dsi-panel-clockrate
   dyn0   = qcom,dsi-dyn-clk-list 首项 (130 档 dyn 时钟高于静态时钟, 142/144 与静态一致)
   adfr1  = oplus,adfr-min-fps-mapping-table 首 cell (130 档实测 131, 142/144 为档位值)
   adfr2  = 次 cell (0=保持基准 60; 142/144 实测 60->72)
   transfer = qcom,mdss-mdp-transfer-time-us (0=保持基准 6290; 142/144 实测 -> 5900) */
typedef struct { int hz; uint64_t clk, dyn0; uint32_t adfr1, adfr2, transfer; } Gt7pRate;
static const Gt7pRate GT7P_RATES[] = {
    { 130, 1205000000ull, 1214000000ull, 131,  0,    0 },
    { 142, 1316000000ull, 1316000000ull, 142, 72, 5900 },
    { 144, 1362200000ull, 1362200000ull, 144, 72, 5900 },
};
static const Gt7pRate *gt7p_rate(int hz) {
    for (size_t i = 0; i < sizeof(GT7P_RATES) / sizeof(GT7P_RATES[0]); i++)
        if (GT7P_RATES[i].hz == hz) return &GT7P_RATES[i];
    return NULL;
}

/* 生成克隆行块: 返回行数组 */
typedef struct { char **lines; int n; } LineBlock;

static char *lead_ws(const char *src) {
    size_t n = 0;
    while (src[n] == ' ' || src[n] == '\t') n++;
    char *w = xmalloc(n + 1); memcpy(w, src, n); w[n] = 0;
    return w;
}

static char *fmt_line(const char *src_ws, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char body[512];
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);
    char *l = xmalloc(strlen(src_ws) + strlen(body) + 4);
    strcpy(l, src_ws); strcat(l, body);
    return l;
}

static int name_has_hz_suffix(const char *name, char *base, size_t basesz) {
    size_t n = strlen(name);
    int i = (int)n - 1;
    while (i >= 0 && name[i] >= '0' && name[i] <= '9') i--;
    if (i < 0 || name[i] != '_') { snprintf(base, basesz, "%s", name); return 0; }
    snprintf(base, basesz, "%.*s", i, name);
    return 1;
}

/* 解析 <...> 内的 u32 cell 数组 (电池补丁节定义, patch_dts 的 dyn-clk 改写亦使用) */
static int parse_u32_cells(const char *val, uint32_t *cells, int max);

/* 对一个 dts 执行补丁; 返回新增节点数 */
static int patch_dts(Dts *d, const PatchCfg *cfg, int verbose,
                     char (*stock_names)[160], int stock_n) {
    TNode *nodes = xmalloc(sizeof(TNode) * MAX_NODES);
    int nn = scan_timing_nodes(d, nodes, MAX_NODES);
    /* 家族分组: 第一遍仅静态节点; 若整个镜像无静态时序 (如 ace3/ace3pro 全部
       带 dyn-clk-list), 第二遍允许动态节点作为基准 (克隆产物删除 dyn-clk-list 转静态) */
    typedef struct { char fam[160]; int base_idx; } Fam;
    Fam fams[512]; int nf = 0;
    for (int pass = 0; pass < 2 && nf == 0; pass++) {
    for (int i = 0; i < nn; i++) {
        TNode *t = &nodes[i];
        if (cfg->gt7p) {
            /* GT7P 竞速版: 仅 AE035 面板的 sa_fhd 动态节点作为基准
               (静态 sim 面板家族全部排除); pass0 直接允许动态 */
            if (!t->is_dynamic) continue;
            if (!strstr(t->name, "sa_fhd")) continue;
        } else if (pass == 0 && t->is_dynamic) continue;
        /* 纯数字名节点 (timing@0/1 等) 为 sim/bridge 面板或 dyn-clk 占位索引, 不作克隆基准 */
        if (t->name[0] >= '0' && t->name[0] <= '9') continue;
        /* 提供 stock 节点名集合时, 仅 stock 中存在的节点可作为克隆基准
           (排除本模块或其他工具先前追加的 OC 节点, 保证插值模型始终基于原厂时序) */
        if (stock_n >= 0) {
            int in_stock = 0;
            for (int s = 0; s < stock_n; s++)
                if (!strcmp(stock_names[s], t->name)) { in_stock = 1; break; }
            if (!in_stock) continue;
        }
        if (!t->has_rate || t->has_rate < 0) continue;
        if (t->has_clock < 0 || t->has_phy < 0) { 
            fprintf(stderr, "[WARN] 节点 %s 的 clockrate/phy 属性格式无法解析，跳过该节点\n", t->name);
            continue;
        }
        if (!t->has_width || !t->has_height || !t->has_clock) {
            fprintf(stderr, "[WARN] 节点 %s 缺少 width/height/clockrate，跳过\n", t->name);
            continue;
        }
        if (cfg->wxh_filter && (t->width != cfg->wx || t->height != cfg->wy)) continue;
        char fam[160];
        name_has_hz_suffix(t->name, fam, sizeof(fam));
        if (cfg->exclude[0]) {
            /* 逗号分隔任一匹配即排除 */
            char tmp[256]; snprintf(tmp, sizeof(tmp), "%s", cfg->exclude);
            int skip = 0; char *save, *tok;
            for (tok = strtok_r(tmp, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
                if (strstr(fam, tok)) { skip = 1; break; }
            if (skip) continue;
        }
        if (cfg->include[0]) {
            /* 逗号分隔任一匹配 */
            char tmp[256]; snprintf(tmp, sizeof(tmp), "%s", cfg->include);
            int ok = 0; char *save, *tok;
            for (tok = strtok_r(tmp, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
                if (strstr(fam, tok)) { ok = 1; break; }
            if (!ok) continue;
        }
        int found = -1;
        for (int k = 0; k < nf; k++) if (!strcmp(fams[k].fam, fam)) { found = k; break; }
        if (found < 0) { if (nf >= 512) break; strcpy(fams[nf].fam, fam); fams[nf].base_idx = i; nf++; continue; }
        if (cfg->gt7p) {
            /* gt7p: 基准固定为原厂 120 档 (sa_fhd 家族唯一克隆源, 实机验证基准);
               防止已含 OC 档 (130/142/144) 的镜像把克隆档误选为基准 */
            if (t->rate == 120) fams[found].base_idx = i;
        } else if (nodes[fams[found].base_idx].rate < t->rate) fams[found].base_idx = i;
    }
    } /* end pass */
    if (!nf) { free(nodes); return 0; }

    /* 收集插入块 */
    typedef struct { int at; char **lines; int n; } Ins;
    Ins ins[512]; int nins = 0;
    int added = 0;
    for (int k = 0; k < nf; k++) {
        TNode *B = &nodes[fams[k].base_idx];
        if (B->rate < 60) continue;
        /* 该家族生成的名字需检查冲突: 全文件所有节点名 */
        for (int ti = 0; ti < cfg->n; ti++) {
            int hz = cfg->hz[ti];
            if (hz <= (int)B->rate) { if (verbose) fprintf(stderr, "[INFO] %s: %d <= 基准 %d，跳过\n", fams[k].fam, hz, B->rate); continue; }
            double ratio = (double)hz / B->rate;
            if (ratio > 1.60) { if (verbose) fprintf(stderr, "[INFO] %s: %dHz 倍率 %.2f 过高，跳过\n", fams[k].fam, hz, ratio); continue; }
            char newname[192];
            snprintf(newname, sizeof(newname), "%s_%d", fams[k].fam, hz);
            int exists_same = 0, suffix = 0;
            for (int attempt = 0; attempt < 8; attempt++) {
                exists_same = 0;
                for (int j = 0; j < nn; j++) {
                    if (!strcmp(nodes[j].name, newname + 0)) {
                        /* gt7p 克隆档保留 dyn-clk-list (is_dynamic=1), 幂等判定不查动态标志 */
                        if ((int)nodes[j].rate == hz && (!nodes[j].is_dynamic || cfg->gt7p)) { exists_same = 1; break; }
                        break;
                    }
                }
                if (exists_same) break;
                /* 名字存在但刷新率不同(或不存在) → 尝试后缀 */
                int clash = 0;
                for (int j = 0; j < nn; j++) if (!strcmp(nodes[j].name, newname)) { clash = 1; break; }
                if (!clash) break;
                snprintf(newname, sizeof(newname), "%s_%d_%d", fams[k].fam, hz, ++suffix);
            }
            if (exists_same) { if (verbose) fprintf(stderr, "[INFO] %s 已存在 %dHz 档位，跳过\n", newname, hz); continue; }
            /* 计算新参数 */
            double p = ratio;
            uint32_t nvfp = B->has_vfp ? (uint32_t)clamp_round(B->vfp * interp3(p, 1.0, 0.5), 1, (int)B->vfp) : 0;
            uint32_t nvbp = B->has_vbp ? (uint32_t)clamp_round(B->vbp * interp3(p, 0.75, 0.5), 1, (int)B->vbp) : 0;
            uint32_t nhfp = B->has_hfp ? (uint32_t)clamp_round(B->hfp * interp3(p, 0.875, 0.75), 1, (int)B->hfp) : 0;
            uint32_t nhbp = B->has_hbp ? (uint32_t)clamp_round(B->hbp * interp3(p, 0.9, 0.8), 1, (int)B->hbp) : 0;
            uint64_t newclk = clock_override(cfg, hz);
            const Gt7pRate *tr = cfg->gt7p ? gt7p_rate(hz) : NULL;
            uint64_t dyn0 = newclk;   /* gt7p: dyn-clk-list 首项 (默认同静态时钟) */
            if (!newclk && B->has_clock) {
                if (cfg->gt7p) {
                    /* GT7P: porch 保持原值 (hvn==hvo), 时钟线性缩放;
                       实测档位 (130/142/144) 直接用实机验证值, 未实测档位用拟合 margin
                       (由实测值反推: 144:1.0208, 142:1.0001, 130:1.0003) */
                    double margin = hz >= 144 ? 1.0208 : (hz >= 140 ? 1.0001 : 1.0003);
                    newclk = (uint64_t)((double)B->clock * ratio * margin + 0.5);
                    if (tr) { newclk = tr->clk; dyn0 = tr->dyn0; }
                } else {
                    double margin = hz >= 160 ? cfg->margin_high : cfg->margin_low;
                    double hvn = (B->width + (B->has_hfp ? nhfp : B->hfp) + (B->has_hbp ? nhbp : B->hbp) + (B->has_hpw ? B->hpw : 0));
                    double hvn_v = (B->height + (B->has_vfp ? nvfp : B->vfp) + (B->has_vbp ? nvbp : B->vbp) + (B->has_vpw ? B->vpw : 0));
                    double hvo = (B->width + B->hfp + B->hbp + B->hpw);
                    double hvo_v = (B->height + B->vfp + B->vbp + B->vpw);
                    newclk = (uint64_t)((double)B->clock * ratio * (hvn * hvn_v) / (hvo * hvo_v) * margin);
                }
            }
            uint32_t ntransfer = 0;
            if (B->has_transfer) {
                ntransfer = (uint32_t)clamp_round(B->transfer * interp3(p, 0.89030, 0.76312), 100, 1000000 / hz - 1);
            }
            uint32_t nvsync = B->has_vsync ? (uint32_t)((double)B->vsync * B->rate / hz + 0.5) : 0;
            /* 生成克隆行 */
            int cap = B->end - B->start + 16;
            char **cl = xmalloc(sizeof(char*) * cap); int cn = 0;
            for (int j = B->start; j < B->end; j++) {
                const char *src = d->lines[j];
                char *ws = lead_ws(src);
                char pn[160]; const char *val;
                int pr = parse_prop_line(src, pn, sizeof(pn), &val);
                int patched = 0;
                if (j == B->start) {
                    /* 节点名行: 替换名字 */
                    const char *np = src; while (*np == ' ' || *np == '\t') np++;
                    char *brace = strchr((char*)np, '{');
                    size_t pre = (size_t)(np - src);
                    char *l = xmalloc(pre + 8 + strlen(newname) + 8);
                    memcpy(l, src, pre);
                    sprintf(l + pre, "timing@%s {", newname);
                    cl[cn++] = l; patched = 1;
                }
                else if (pr == 2) {
                    if (!strcmp(pn, "phandle") || !strcmp(pn, "linux,phandle")) {
                        /* 克隆节点不携带 phandle: 原节点 phandle 保持不变, 新节点无引用,
                           保留会导致 dtc duplicated phandle 错误 (如一加15 wqhd_plus 时序) */
                        patched = 1; /* 置位即跳过该行 */
                    }
                    else if (cfg->gt7p && !strcmp(pn, "qcom,dsi-dyn-clk-list")) {
                        /* GT7P: 保留 dyn-clk-list, 首项替换为实测 dyn 时钟 (130 档 dyn 与静态时钟不同) */
                        uint32_t dcells[32];
                        int dn = parse_u32_cells(val, dcells, 32);
                        if (dn >= 1 && dyn0) {
                            dcells[0] = (uint32_t)dyn0;
                            char body[512]; int off = 0;
                            off += snprintf(body + off, sizeof(body) - off, "qcom,dsi-dyn-clk-list = <");
                            for (int ci = 0; ci < dn; ci++)
                                off += snprintf(body + off, sizeof(body) - off, "%s0x%x", ci ? " " : "", dcells[ci]);
                            snprintf(body + off, sizeof(body) - off, ">;");
                            cl[cn++] = fmt_line(ws, "%s", body);
                            patched = 1;
                        } else patched = 1;   /* 解析失败也删除原行, 避免残留 120Hz 动态时钟 */
                    }
                    else if (!cfg->gt7p && B->is_dynamic && strstr(pn, "dyn-clk")) {
                        /* 动态基准克隆: 删除 dyn-clk-list 等动态时钟属性, 产物转为纯静态节点 */
                        patched = 1;
                    }
                    else if (!strcmp(pn, "qcom,mdss-dsi-panel-framerate")) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-panel-framerate = <0x%x>;", hz); patched = 1; }
                    else if (!strcmp(pn, "qcom,mdss-dsi-panel-clockrate") && newclk) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-panel-clockrate = <0x%llx>;", (unsigned long long)newclk); patched = 1; }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-dsi-v-front-porch") && B->has_vfp) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-v-front-porch = <0x%x>;", nvfp); patched = 1; }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-dsi-v-back-porch") && B->has_vbp) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-v-back-porch = <0x%x>;", nvbp); patched = 1; }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-dsi-h-front-porch") && B->has_hfp) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-h-front-porch = <0x%x>;", nhfp); patched = 1; }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-dsi-h-back-porch") && B->has_hbp) { cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-h-back-porch = <0x%x>;", nhbp); patched = 1; }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-mdp-transfer-time-us") && ntransfer) { cl[cn++] = fmt_line(ws, "qcom,mdss-mdp-transfer-time-us = <0x%x>;", ntransfer); patched = 1; }
                    else if (cfg->gt7p && tr && tr->transfer && !strcmp(pn, "qcom,mdss-mdp-transfer-time-us")) {
                        /* GT7P 实测: 142/144 档 transfer 6290->5900; 130 档保持基准 */
                        cl[cn++] = fmt_line(ws, "qcom,mdss-mdp-transfer-time-us = <0x%x>;", tr->transfer); patched = 1;
                    }
                    else if (!cfg->gt7p && !strcmp(pn, "oplus,apollo-panel-vsync-width") && nvsync) { cl[cn++] = fmt_line(ws, "oplus,apollo-panel-vsync-width = <0x%x>;", nvsync); patched = 1; }
                    else if (!strcmp(pn, "oplus,adfr-min-fps-mapping-table") && B->has_adfr) {
                        /* GT7P adfr: 首 cell 用实测值 (130 档为 131), 142/144 档次 cell 60->72 */
                        int g2 = cfg->gt7p && (tr ? tr->adfr2 != 0 : hz >= 142);
                        if (cfg->gt7p && g2 && B->adfr_rest2[0])
                            cl[cn++] = fmt_line(ws, "oplus,adfr-min-fps-mapping-table = <0x%x 0x%x %s>;",
                                tr ? tr->adfr1 : (uint32_t)hz, tr ? tr->adfr2 : 72u, B->adfr_rest2);
                        else if (cfg->gt7p && g2)
                            cl[cn++] = fmt_line(ws, "oplus,adfr-min-fps-mapping-table = <0x%x 0x%x>;",
                                tr ? tr->adfr1 : (uint32_t)hz, tr ? tr->adfr2 : 72u);
                        else if (cfg->gt7p)
                            cl[cn++] = fmt_line(ws, "oplus,adfr-min-fps-mapping-table = <0x%x %s>;",
                                tr ? tr->adfr1 : (uint32_t)hz, B->adfr_rest);
                        else
                            cl[cn++] = fmt_line(ws, "oplus,adfr-min-fps-mapping-table = <0x%x %s>;", hz, B->adfr_rest);
                        patched = 1;
                    }
                    else if (!cfg->gt7p && !strcmp(pn, "qcom,mdss-dsi-panel-phy-timings") && B->has_phy == 1 && cfg->modify_phy) {
                        char hex[512]; int off = 0;
                        off += snprintf(hex + off, sizeof(hex) - off, "[");
                        for (int bi = 0; bi < B->phy_len; bi++) {
                            double f144 = (bi < 14 && PHY_F144[bi] > 0) ? PHY_F144[bi] : PHY_F144_AVG;
                            double f165 = (bi < 14 && PHY_F165[bi] > 0) ? PHY_F165[bi] : PHY_F165_AVG;
                            double f = interp3(p, f144, f165);
                            int nb = B->phy[bi] == 0 ? 0 : clamp_round(B->phy[bi] * f, 1, (int)B->phy[bi]);
                            off += snprintf(hex + off, sizeof(hex) - off, "%s%02x", bi ? " " : "", nb);
                        }
                        snprintf(hex + off, sizeof(hex) - off, "]");
                        cl[cn++] = fmt_line(ws, "qcom,mdss-dsi-panel-phy-timings = %s;", hex);
                        patched = 1;
                    }
                }
                if (!patched) cl[cn++] = xstrdup(src);
                free(ws);
                if (cn >= cap) { cap *= 2; cl = xrealloc(cl, sizeof(char*) * cap); }
            }
            /* 记录插入(倒序加入同一位置: 目标从大到小 → 先插最大, 后插小的会排前面…我们希望列表降序: 先加小的再加大的? */
            /* 简化: 按 hz 升序生成, 依次插到 base 前 → 最终顺序为 …, 小, 大, base? 不对。
               依次插入同一位置: 插入序 hz 升序 → 每次新行放在上一个克隆之前 → 最终呈现降序? 
               直接收集: 同一 base 的多个克隆, 生成时按 hz 降序追加到同一个块里。 */
            if (nins > 0 && ins[nins-1].at == B->start) {
                /* 追加到已有块: 保持降序 → 新的 hz 若更小应插在前面? 我们在外层 ti 从大到小遍历 cfg->hz, 因此后到的更小, 应排在已有块之后? 教程顺序: 165,144,120(降序) */
                ins[nins-1].lines = xrealloc(ins[nins-1].lines, sizeof(char*) * (ins[nins-1].n + cn));
                memcpy(ins[nins-1].lines + ins[nins-1].n, cl, sizeof(char*) * cn);
                ins[nins-1].n += cn;
                free(cl);
            } else {
                ins[nins].at = B->start;
                ins[nins].lines = cl; ins[nins].n = cn;
                nins++;
                if (nins >= 512) die("插入块过多");
            }
            added++;
            if (verbose) {
                if (cfg->gt7p)
                    fprintf(stderr, "[OK] %s -> 新增 %s (clock=%llu dyn-clk0=%llu adfr=%u%s transfer=%s)\n",
                        B->name, newname, (unsigned long long)newclk, (unsigned long long)dyn0,
                        tr ? tr->adfr1 : (uint32_t)hz,
                        (tr ? tr->adfr2 : (hz >= 142 ? 72 : 0)) ? "/72" : "/原值",
                        (tr && tr->transfer) ? "5900(实测)" : "原值");
                else
                    fprintf(stderr, "[OK] %s -> 新增 %s (clock=%llu rate=%d vfp=%u vbp=%u hfp=%u hbp=%u tr=%u vs=%u)\n",
                        B->name, newname, (unsigned long long)newclk, hz, nvfp, nvbp, nhfp, nhbp, ntransfer, nvsync);
            }
        }
    }
    if (!added) { free(nodes); return 0; }
    /* 合并插入(位置升序, 从后往前 splice 避免位移) */
    for (int i = nins - 1; i >= 0; i--) {
        int at = ins[i].at;
        char **nl = xmalloc(sizeof(char*) * (d->n + ins[i].n));
        memcpy(nl, d->lines, sizeof(char*) * at);
        memcpy(nl + at, ins[i].lines, sizeof(char*) * ins[i].n);
        memcpy(nl + at + ins[i].n, d->lines + at, sizeof(char*) * (d->n - at));
        free(d->lines); d->lines = nl; d->n += ins[i].n;
    }
    free(nodes);
    return added;
}

/* ------------------------------------------------------------------ */
/* 电池补丁 (ACE2Pro 6100mAh 魔改电池)                                  */
/* ------------------------------------------------------------------ */

/* 电池参数: 容量 5000->6100, 关机电压 3300->3000mV, 1% 电压 3310->3050mV */
#define BATT_CAP_OLD    5000u
#define BATT_CAP_NEW    6100u
#define BATT_VOFF_OLD   3300u
#define BATT_VOFF_NEW   3000u
#define BATT_V1P_OLD    3310u
#define BATT_V1P_NEW    3050u
/* 充电策略表末两段电压: 4510mV->4530mV, 4520mV->4540mV (满充 4.54V) */
#define VMAP_4510_NEW   4530u
#define VMAP_4520_NEW   4540u
/* UFCS 策略表 5 元组首 cell 标识 (0x2af8) */
#define UFCS_TUPLE_TAG  11000u

/* oplus 策略表解除输入限流: 电流位 x2 上限 (mA) */
#define BATT_STRAT_ICLMAX  8000u
/* 策略表电流位放大下限 (mA): 低于此值视为涓流/异常表, 不放大 */
#define BATT_STRAT_IMIN    100u

typedef struct {
    /* mode: 0=关闭
             1=解除充电限流 (全机型: 老平台删 qcom 限流节点,
                新平台 oplus 策略表电流位 x2 cap 8000)
             2=解除充电限流+关机电压2800 电池解容 (全机型)
             3=6100mAh 魔改电池 (容量6100/关机3.0V/1%3.05V/满充4.54V)
             4=6100mAh 魔改电池+解除充电限流
             5=原版电池+关机电压2800 电池解容 (全机型:
                老平台替换/插入 qcom,vbatt_power_off,
                新平台 gt7s/gt8p/ace6t/gt7p 替换 oplus,chg_shutdown_max_mv)
             6=GT7 Pro 竞速版解容 (满充4.55V/关机2.85V/解除充电限流):
                pps/ufcs full_ffc_vbat 与 normal 策略表末段 -> 4550mV,
                chg_shutdown_max_mv/vbat_uv_thr_mv -> 2850mV,
                pd/qc-iclmax-ma -> 8000mA, 策略表电流位 x2 (cap 8000) */
    int mode;
    int cap_hits, voff_hits, v1p_hits;   /* 魔改替换计数 */
    int v2800_hits, v2800_ins;           /* 关机电压2800: 替换/插入计数 */
    int vmap_hits, removed_lines;
    int strat_hits;         /* oplus 策略表电流位放大计数 (新平台解除限流) */
    int saw_cap;            /* 见到 qcom,batt_capacity_mah 属性 (魔改机型指纹) */
    int gt7p_hits;          /* gt7p 解容: 替换/放大计数 (电压/电流/iclmax) */
} BattCfg;

/* 电池方案模式分组 */
#define BATT_DEL_LIMIT(m)  ((m) == 1 || (m) == 2 || (m) == 4 || (m) == 6)   /* 删除充电限流节点 */
#define BATT_MODIFY(m)     ((m) == 3 || (m) == 4)               /* 6100 魔改替换 */
#define BATT_V2800(m)      ((m) == 2 || (m) == 5)               /* 关机电压 2800 (电池解容) */
#define BATT_GT7P(m)       ((m) == 6)                           /* GT7P 竞速版解容 */
#define BATT_VOFF_2800     2800u

/* GT7P 竞速版解容参数 */
#define GT7P_FULL_VBAT     4550u   /* 满充 4.55V */
#define GT7P_VOFF_MV       2850u   /* 关机 2.85V */
#define GT7P_ICLMAX_MA     8000u   /* 输入限流上限 8A */

/* 解析 <...> 内的 u32 cell 数组; 返回 cell 数, 失败返回 -1 */
static int parse_u32_cells(const char *val, uint32_t *cells, int max) {
    const char *q = val;
    if (*q == '<') q++;
    int n = 0;
    while (*q && *q != '>' && n < max) {
        while (*q == ' ' || *q == '\t') q++;
        if (!*q || *q == '>') break;
        cells[n++] = parse_u32_from_val(q);
        while (*q && *q != ' ' && *q != '\t' && *q != '>') q++;
    }
    if (*q != '>') return -1;
    return n;
}

/* 单 cell 属性替换: 命中返回新值, 未命中返回 0
   电池参数按属性名替换 (不做旧值精确匹配): 一加12 原厂容量 5400mAh ≠ 5000,
   方案目标值一致 (6100/3000/3050), 无论原值是多少
   一加12 (oplus gauge) 满充系列 +20mV: hw 4480→4500, sw/cool 4470→4490,
   ffc 4520→4540 (与 ACE2Pro 策略表 4520→4540 同款, 满充最高 4.54V) */
static uint32_t batt_map_single(const char *prop, uint32_t v) {
    if (!strcmp(prop, "qcom,batt_capacity_mah")) return BATT_CAP_NEW;
    if (!strcmp(prop, "oplus,batt_capacity_mah")) return BATT_CAP_NEW;
    if (!strcmp(prop, "qcom,vbatt_power_off")) return BATT_VOFF_NEW;
    if (!strcmp(prop, "qcom,vbatt_soc_1")) return BATT_V1P_NEW;
    /* 一加12 满充判定节点 (+20mV, 按名+精确值) */
    if (strstr(prop, "full_normal_hw_vbat") && v == 4480u) return 4500u;
    if (strstr(prop, "full_normal_sw_vbat") && v == 4470u) return 4490u;
    if (strstr(prop, "full_cool_sw_vbat")  && v == 4470u) return 4490u;
    if (strstr(prop, "full_ffc_vbat")      && v == 4520u) return 4540u;
    if (strstr(prop, "full-pre-ffc-mv")    && v == 4465u) return 4485u;
    /* 满充/切换电压类属性 (含 full_voltage / full_*_sw_vbat 等): 仅替换 4510/4520 段 */
    if ((strstr(prop, "full_voltage") || strstr(prop, "low_curr_full") ||
         (strstr(prop, "full") && strstr(prop, "vbat")))) {
        if (v == 4510u) return VMAP_4510_NEW;
        if (v == 4520u) return VMAP_4520_NEW;
    }
    return 0;
}

/* boost 模式删除的充电限流节点
   前 3 个: ACE2Pro 实测教程的冷却降流/异常适配器限流 (oplus svooc 方案)
   qcom,thermal-mitigation: 高通标准充电热限流表 (一加11/新机型充电 DT 为该方案) */
static const char *BATT_REMOVE_PROPS[] = {
    "qcom,svooc_cool_down_current_limit",
    "qcom,vooc_cool_down_current_limit",
    "qcom,abnormal_adapter_current",
    "qcom,thermal-mitigation",
    NULL
};

static int batt_should_remove(const char *prop) {
    for (int i = 0; BATT_REMOVE_PROPS[i]; i++)
        if (!strcmp(prop, BATT_REMOVE_PROPS[i])) return 1;
    return 0;
}

/* 从节点头行 (如 "\t\tufcs_charge_low_curr_full {") 提取节点名 */
static void extract_node_name(const char *line, char *out, size_t outsz) {
    const char *br = strchr(line, '{');
    if (!br) { out[0] = 0; return; }
    /* '{' 前最后一个非空白 token */
    const char *p = br - 1;
    while (p >= line && (*p == ' ' || *p == '\t')) p--;
    const char *end = p + 1;
    while (p >= line && *p != ' ' && *p != '\t') p--;
    p++;
    size_t tlen = (size_t)(end - p);
    if (tlen > outsz - 1) tlen = outsz - 1;
    memcpy(out, p, tlen);
    out[tlen] = 0;
    /* 去掉 label: 前缀与 @unit-address 后缀 */
    char *c = strchr(out, ':'); if (c) memmove(out, c + 1, strlen(c + 1) + 1);
    c = strchr(out, '@'); if (c) *c = 0;
}

/* 对一个 dts 执行电池补丁; 返回修改+删除+插入的总行数 */
static int patch_battery_dts(Dts *d, BattCfg *bc, int verbose) {
    if (!bc->mode) return 0;
    int changed = 0;
    /* 分组标志 */
    const int del_limit = BATT_DEL_LIMIT(bc->mode);
    const int modify    = BATT_MODIFY(bc->mode);
    const int v2800     = BATT_V2800(bc->mode);
    const int gt7p      = BATT_GT7P(bc->mode);
    /* 新平台指纹: 含 oplus,chg_shutdown_max_mv 的充电 DT (gt7s/gt8p/ace6t 等)
       解除限流走 oplus 策略表电流位放大; 老平台 (qcom 限流节点删除) 不受影响 */
    int new_plat = 0;
    if (del_limit && !gt7p) {
        for (int i = 0; i < d->n && !new_plat; i++)
            if (strstr(d->lines[i], "oplus,chg_shutdown_max_mv")) new_plat = 1;
    }
    /* 第一遍: 行替换 (电池参数 + 电压段 + 关机电压2800); 解除限流模式同时收集待删行 */
    int *del = NULL, ndel = 0, delcap = 0;
    if (del_limit) { delcap = 64; del = xmalloc(sizeof(int) * delcap); }
    /* 节点路径跟踪: 用于区分 5 元组策略表与 low_curr_full 内的 (I,V,f) 三元组表 */
    char *nstack[64]; int ndepth = 0;
    for (int i = 0; i < d->n; i++) {
        const char *line = d->lines[i];
        char *open_br = strchr(line, '{');
        char *close_br = strchr(line, '}');
        if (open_br && !close_br) {
            /* 节点头: 先压栈, 节点自身不是属性行 */
            char nm[128];
            extract_node_name(line, nm, sizeof(nm));
            if (ndepth < 64) nstack[ndepth++] = xstrdup(nm);
            continue;
        }
        char pn[160]; const char *val;
        int r = parse_prop_line(line, pn, sizeof(pn), &val);
        if (r != 2) {
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        /* 魔改机型指纹: 见到容量属性即置位 (无论是否修改)
           ACE2Pro(qcom gauge)/一加11: qcom,batt_capacity_mah; 一加12(oplus gauge): oplus,batt_capacity_mah */
        if (!strcmp(pn, "qcom,batt_capacity_mah") || !strcmp(pn, "oplus,batt_capacity_mah")) bc->saw_cap = 1;
        /* 判断是否处于 *low_curr_full* 节点内 */
        int in_lowcurr = 0;
        for (int k = 0; k < ndepth; k++)
            if (strstr(nstack[k], "low_curr_full")) { in_lowcurr = 1; break; }
        if (del_limit && batt_should_remove(pn)) {
            if (ndel >= delcap) { delcap *= 2; del = xrealloc(del, sizeof(int) * delcap); }
            del[ndel++] = i;
            if (verbose) fprintf(stderr, "[BATT] 删除限流节点: %s\n", pn);
            continue;
        }
        /* 关机电压 2800 (电池解容): 已有节点直接替换为 2800 (无论原值)
           老平台 qcom,vbatt_power_off / 新平台 (gt7s/gt8p/ace6t 等) oplus,chg_shutdown_max_mv */
        if (v2800 && (!strcmp(pn, "qcom,vbatt_power_off") || !strcmp(pn, "oplus,chg_shutdown_max_mv"))) {
            char body[256];
            char *ws = lead_ws(line);
            snprintf(body, sizeof(body), "%s%s = <0x%x>;", ws, pn, BATT_VOFF_2800);
            free(ws);
            free(d->lines[i]);
            d->lines[i] = xstrdup(body);
            changed++;
            bc->v2800_hits++;
            if (verbose) fprintf(stderr, "[BATT] 关机电压 -> 2800mV (电池解容)\n");
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        if (!modify && !gt7p) {
            /* 非魔改模式: 其余电池参数保持不动;
               例外 — 新平台解除限流 (mode 1/2): oplus 策略表电流位 x2 (cap 8000) */
            if (new_plat && !strncmp(pn, "strategy_temp_", 14)) {
                /* strategy_temp_range_curves 内为 (I,V,f) 三元组表, 其余为 5 元组表:
                   UFCS (0x2af8,V,I,f,f) 电流位=base+2; 无 tag (V,I,f,f,f) 首 cell 为
                  电池电压 (3800-4900mV) 时电流位=base+1, 首 cell 非电压的模糊表跳过 */
                int in_curves = 0;
                for (int k = 0; k < ndepth; k++)
                    if (!strcmp(nstack[k], "strategy_temp_range_curves")) { in_curves = 1; break; }
                uint32_t sc[512];
                int sn = parse_u32_cells(val, sc, 512);
                int nhit = 0;
                if (sn >= 3) {
                    if (in_curves) {
                        for (int j = 0; j + 3 <= sn; j += 3) {
                            uint32_t cur = sc[j];
                            if (cur >= BATT_STRAT_IMIN && cur < BATT_STRAT_ICLMAX) {
                                uint32_t ni = cur * 2;
                                if (ni > BATT_STRAT_ICLMAX) ni = BATT_STRAT_ICLMAX;
                                sc[j] = ni; nhit++;
                            }
                        }
                    } else {
                        for (int base = 0; base + 5 <= sn; base += 5) {
                            int ipos;
                            if (sc[base] == UFCS_TUPLE_TAG) ipos = base + 2;
                            else if (sc[base] >= 3800 && sc[base] <= 4900) ipos = base + 1;
                            else continue;
                            uint32_t cur = sc[ipos];
                            if (cur >= BATT_STRAT_IMIN && cur < BATT_STRAT_ICLMAX) {
                                uint32_t ni = cur * 2;
                                if (ni > BATT_STRAT_ICLMAX) ni = BATT_STRAT_ICLMAX;
                                sc[ipos] = ni; nhit++;
                            }
                        }
                    }
                }
                if (nhit) {
                    char body[8192]; int off = 0;
                    off += snprintf(body + off, sizeof(body) - off, "%s = <", pn);
                    for (int j = 0; j < sn; j++)
                        off += snprintf(body + off, sizeof(body) - off, "%s0x%x", j ? " " : "", sc[j]);
                    off += snprintf(body + off, sizeof(body) - off, ">;");
                    char *ws = lead_ws(line);
                    char *nl = xmalloc(strlen(ws) + strlen(body) + 2);
                    strcpy(nl, ws); strcat(nl, body);
                    free(ws);
                    free(d->lines[i]);
                    d->lines[i] = nl;
                    changed++;
                    bc->strat_hits += nhit;
                    if (verbose) fprintf(stderr, "[BATT][新平台] 策略表电流位 x%d: %s\n", nhit, body);
                }
            }
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        if (gt7p) {
            /* ---- GT7 Pro 竞速版解容 (mode 6) ---- */
            int is_strat_g = !strncmp(pn, "strategy_temp_", 14);
            int is_normal_g = !strncmp(pn, "strategy_temp_normal", 20);
            int is_ffc_g = strstr(pn, "full_ffc_vbat") != NULL;
            int is_voff_g = !strcmp(pn, "oplus,chg_shutdown_max_mv") ||
                            !strcmp(pn, "oplus_spec,vbat_uv_thr_mv") ||
                            !strcmp(pn, "qcom,vbatt_power_off");
            int is_icl_g = !strcmp(pn, "oplus_spec,pd-iclmax-ma") ||
                           !strcmp(pn, "oplus_spec,qc-iclmax-ma");
            if (is_strat_g || is_ffc_g || is_voff_g || is_icl_g) {
                uint32_t cells_g[512];
                int ng = parse_u32_cells(val, cells_g, 512);
                int hit_g = 0;
                if (ng >= 1 && is_strat_g) {
                    /* 0x2af8/普通 5 元组: 电流位 x2 (cap 8000, 全温度段解除输入限流);
                       normal 段末元组电压位 -> 4550 (常温满充 4.55V, 低温段保持原厂) */
                    int last_base = -1;
                    for (int base = 0; base + 5 <= ng; base += 5) {
                        int vpos = (cells_g[base] == UFCS_TUPLE_TAG) ? base + 1 : base;
                        if (cells_g[vpos + 1] < GT7P_ICLMAX_MA) {
                            uint32_t ni = cells_g[vpos + 1] * 2;
                            if (ni > GT7P_ICLMAX_MA) ni = GT7P_ICLMAX_MA;
                            cells_g[vpos + 1] = ni; hit_g++;
                        }
                        last_base = base;
                    }
                    if (is_normal_g && last_base >= 0) {
                        int vpos = (cells_g[last_base] == UFCS_TUPLE_TAG) ? last_base + 1 : last_base;
                        if (cells_g[vpos] != GT7P_FULL_VBAT) { cells_g[vpos] = GT7P_FULL_VBAT; hit_g++; }
                    }
                } else if (ng >= 1 && is_ffc_g) {
                    /* pps/ufcs full_ffc_vbat -> 4550 */
                    if (cells_g[0] != GT7P_FULL_VBAT) { cells_g[0] = GT7P_FULL_VBAT; hit_g++; }
                } else if (is_voff_g || is_icl_g) {
                    /* 关机系电压 -> 2850 / 输入限流 -> 8000 */
                    uint32_t nv_g = is_voff_g ? GT7P_VOFF_MV : GT7P_ICLMAX_MA;
                    if (cells_g[0] != nv_g) { cells_g[0] = nv_g; hit_g++; }
                }
                if (hit_g) {
                    char body_g[8192]; int off_g = 0;
                    off_g += snprintf(body_g + off_g, sizeof(body_g) - off_g, "%s = <", pn);
                    for (int j = 0; j < ng; j++)
                        off_g += snprintf(body_g + off_g, sizeof(body_g) - off_g, "%s0x%x", j ? " " : "", cells_g[j]);
                    off_g += snprintf(body_g + off_g, sizeof(body_g) - off_g, ">;");
                    char *ws_g = lead_ws(line);
                    char *nl_g = xmalloc(strlen(ws_g) + strlen(body_g) + 2);
                    strcpy(nl_g, ws_g); strcat(nl_g, body_g);
                    free(ws_g);
                    free(d->lines[i]);
                    d->lines[i] = nl_g;
                    changed++;
                    bc->gt7p_hits += hit_g;
                    if (verbose) fprintf(stderr, "[BATT][GT7P] %s\n", body_g);
                }
            }
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        int is_strat = !strncmp(pn, "strategy_temp_", 14);
        int is_fullv = strstr(pn, "full_voltage") != NULL;
        int is_lowcurrfull = strstr(pn, "low_curr_full") != NULL;
        if (!is_strat && !is_fullv && !is_lowcurrfull &&
            strcmp(pn, "qcom,batt_capacity_mah") && strcmp(pn, "qcom,vbatt_power_off") &&
            strcmp(pn, "qcom,vbatt_soc_1") && strcmp(pn, "oplus,batt_capacity_mah") &&
            !strstr(pn, "full-pre-ffc-mv") &&
            !(strstr(pn, "full") && strstr(pn, "vbat"))) {
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        uint32_t cells[512];
        int n = parse_u32_cells(val, cells, 512);
        if (n < 1) {
            if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
            continue;
        }
        int hit = 0;
        if (is_strat && in_lowcurr) {
            /* (I,V,f) 三元组: 电压位 = 3k+1 */
            for (int j = 1; j < n; j += 3) {
                if (cells[j] == 4510u) { cells[j] = VMAP_4510_NEW; hit++; bc->vmap_hits++; }
                else if (cells[j] == 4520u) { cells[j] = VMAP_4520_NEW; hit++; bc->vmap_hits++; }
            }
        } else if (is_strat) {
            /* 策略表: 按 5 元组处理, 仅替换电压位 cell
               SVOOC 元组: (V, I, f, f, f) 电压位 = 组首
               UFCS  元组: (0x2af8, V, I, f, f) 电压位 = 组首+1 */
            for (int base = 0; base + 5 <= n; base += 5) {
                int vpos = (cells[base] == UFCS_TUPLE_TAG) ? base + 1 : base;
                if (cells[vpos] == 4510u) { cells[vpos] = VMAP_4510_NEW; hit++; bc->vmap_hits++; }
                else if (cells[vpos] == 4520u) { cells[vpos] = VMAP_4520_NEW; hit++; bc->vmap_hits++; }
            }
        } else if (is_lowcurrfull) {
            /* (电流,电压) 对: 电压在偶数下标 (1,3,5...) */
            for (int j = 1; j < n; j += 2) {
                if (cells[j] == 4510u) { cells[j] = VMAP_4510_NEW; hit++; bc->vmap_hits++; }
                else if (cells[j] == 4520u) { cells[j] = VMAP_4520_NEW; hit++; bc->vmap_hits++; }
            }
        } else {
            /* 单 cell 属性 (魔改: 容量 6100 / 关机 3.0V / 1% 3.05V) */
            uint32_t nv = batt_map_single(pn, cells[0]);
            if (nv) {
                cells[0] = nv; hit++;
                if (!strcmp(pn, "qcom,batt_capacity_mah") || !strcmp(pn, "oplus,batt_capacity_mah")) bc->cap_hits++;
                else if (!strcmp(pn, "qcom,vbatt_power_off")) bc->voff_hits++;
                else if (!strcmp(pn, "qcom,vbatt_soc_1")) bc->v1p_hits++;
                else bc->vmap_hits++;
            }
        }
        if (hit) {
            /* 重新生成该行 (保持缩进) */
            char body[8192]; int off = 0;
            off += snprintf(body + off, sizeof(body) - off, "%s = <", pn);
            for (int j = 0; j < n; j++)
                off += snprintf(body + off, sizeof(body) - off, "%s0x%x", j ? " " : "", cells[j]);
            off += snprintf(body + off, sizeof(body) - off, ">;");
            char *ws = lead_ws(line);
            char *nl = xmalloc(strlen(ws) + strlen(body) + 2);
            strcpy(nl, ws); strcat(nl, body);
            free(ws);
            free(d->lines[i]);
            d->lines[i] = nl;
            changed++;
            if (verbose) fprintf(stderr, "[BATT] %s\n", body);
        }
        if (close_br && ndepth > 0) { free(nstack[--ndepth]); }
    }
    while (ndepth > 0) free(nstack[--ndepth]);
    /* 第二遍: 从后往前删除收集的行 (解除限流模式) */
    for (int k = ndel - 1; k >= 0; k--) {
        int i = del[k];
        free(d->lines[i]);
        memmove(d->lines + i, d->lines + i + 1, sizeof(char*) * (d->n - i - 1));
        d->n--;
        changed++;
        bc->removed_lines++;
    }
    free(del);
    /* 第三遍: 关机电压 2800 无现成节点时, 插入到 oplus,mms_wired 充电节点内 (电池解容) */
    if (v2800 && bc->v2800_hits == 0) {
        for (int i = 0; i + 1 < d->n; i++) {
            const char *line = d->lines[i];
            char *br = strchr(line, '{');
            if (!br || strchr(line, '}')) continue;
            char nm[128];
            extract_node_name(line, nm, sizeof(nm));
            if (strcmp(nm, "oplus,mms_wired")) continue;
            /* 缩进 = 节点头缩进 + 1 个 tab */
            char *ws = lead_ws(line);
            char *prop = xmalloc(strlen(ws) + 64);
            sprintf(prop, "%s\tqcom,vbatt_power_off = <0x%x>;", ws, BATT_VOFF_2800);
            free(ws);
            d->lines = xrealloc(d->lines, sizeof(char*) * (d->n + 1));
            memmove(d->lines + i + 2, d->lines + i + 1, sizeof(char*) * (d->n - i - 1));
            d->lines[i + 1] = prop;
            d->n++;
            changed++;
            bc->v2800_ins = 1;
            if (verbose) fprintf(stderr, "[BATT] oplus,mms_wired 内插入关机电压 2800mV (电池解容)\n");
            break;
        }
    }
    return changed;
}

/* 校验电池补丁结果
   容量: 魔改必须为 6100 (qcom/oplus 两种前缀); 非魔改仅要求存在 (不同机型原值不同)
   关机/1% 电压、oplus 满充: 存在则必须为新值 (机型可能缺个别节点) */
static int verify_battery_dts(Dts *d, const BattCfg *bc) {
    int cap_ok = 0, off_ok = 0, p1_ok = 0, bad_removed = 0;
    int off_seen = 0, p1_seen = 0;
    int oplus_full_seen = 0, oplus_full_ok = 0;
    int v2800_ok = 0, v2800_bad = 0, v2800_seen = 0;
    int gt7p_ffc_ok = 0, gt7p_ffc_bad = 0;
    int gt7p_voff_ok = 0, gt7p_voff_bad = 0;
    const int modify    = BATT_MODIFY(bc->mode);
    const int del_limit = BATT_DEL_LIMIT(bc->mode);
    const int v2800     = BATT_V2800(bc->mode);
    const int gt7p      = BATT_GT7P(bc->mode);
    for (int i = 0; i < d->n; i++) {
        char pn[160]; const char *val;
        int r = parse_prop_line(d->lines[i], pn, sizeof(pn), &val);
        if (r != 2) continue;
        if (gt7p && strstr(pn, "full_ffc_vbat")) {
            uint32_t v = parse_u32_from_val(val);
            if (v == GT7P_FULL_VBAT) gt7p_ffc_ok = 1;
            else gt7p_ffc_bad++;
        } else if (gt7p && (!strcmp(pn, "oplus,chg_shutdown_max_mv") ||
                            !strcmp(pn, "oplus_spec,vbat_uv_thr_mv") ||
                            !strcmp(pn, "qcom,vbatt_power_off"))) {
            uint32_t v = parse_u32_from_val(val);
            if (v == GT7P_VOFF_MV) gt7p_voff_ok = 1;
            else gt7p_voff_bad++;
        } else if (!strcmp(pn, "qcom,batt_capacity_mah") || !strcmp(pn, "oplus,batt_capacity_mah")) {
            uint32_t v = parse_u32_from_val(val);
            if (modify) { if (v == BATT_CAP_NEW) cap_ok = 1; }
            else cap_ok = 1;   /* 非魔改: 容量保持原厂 (5000/5400 等机型各异) */
        } else if (!strcmp(pn, "qcom,vbatt_power_off") ||
                   (v2800 && !strcmp(pn, "oplus,chg_shutdown_max_mv"))) {
            uint32_t v = parse_u32_from_val(val);
            if (v2800) {
                v2800_seen = 1;
                if (v == BATT_VOFF_2800) v2800_ok = 1;
                else v2800_bad++;
            } else if (modify) {
                off_seen = 1;
                if (v == BATT_VOFF_NEW) off_ok = 1;
            } else if (v == BATT_VOFF_OLD) off_ok = 1;
        } else if (!strcmp(pn, "qcom,vbatt_soc_1")) {
            uint32_t v = parse_u32_from_val(val);
            if (modify) {
                p1_seen = 1;
                if (v == BATT_V1P_NEW) p1_ok = 1;
            } else if (v == BATT_V1P_OLD) p1_ok = 1;
        } else if (modify && strstr(pn, "full_ffc_vbat")) {
            /* ffc 满充: 原值 4520 (一加12) 应替换为 4540;
               其他原值 (ACE2Pro 4455 等) 非本方案替换目标, 忽略 */
            uint32_t v = parse_u32_from_val(val);
            if (v == 4520u) oplus_full_seen = 1;
            else if (v == 4540u) oplus_full_ok = 1;
        } else if (del_limit && batt_should_remove(pn)) {
            bad_removed++;
        }
    }
    if (modify && (!cap_ok || (off_seen && !off_ok) || (p1_seen && !p1_ok) ||
                   (oplus_full_seen && !oplus_full_ok))) {
        fprintf(stderr, "[VERIFY][FAIL] 魔改电池参数校验失败 (cap=%d voff=%d/%d v1pct=%d/%d oplus_full=%d/%d)\n",
            cap_ok, off_ok, off_seen, p1_ok, p1_seen, oplus_full_ok, oplus_full_seen);
        return -1;
    }
    if (v2800 && v2800_seen && (!v2800_ok || v2800_bad)) {
        /* 该 entry 存在关机电压节点才校验 (部分 entry 完全无电池节点, 跳过;
           全局零命中由 cmd_patch 末尾统一报错) */
        fprintf(stderr, "[VERIFY][FAIL] 关机电压2800校验失败 (存在=%d 异常值=%d)\n", v2800_ok, v2800_bad);
        return -1;
    }
    if (gt7p && (gt7p_ffc_bad || gt7p_voff_bad || !gt7p_ffc_ok)) {
        /* 满充节点必须全部 4550; 关机系节点必须 2850; 至少命中满充节点 */
        fprintf(stderr, "[VERIFY][FAIL] GT7P 解容校验失败 (满充=%d 异常=%d 关机=%d 异常=%d)\n",
            gt7p_ffc_ok, gt7p_ffc_bad, gt7p_voff_ok, gt7p_voff_bad);
        return -1;
    }
    if (del_limit && bad_removed) {
        fprintf(stderr, "[VERIFY][FAIL] 限流节点仍存在 (%d 行)\n", bad_removed);
        return -1;
    }
    return 0;
}

/* 校验补丁后的 dts: 期望的 (family, hz) 都存在且参数正确 */
static int verify_dts(Dts *d, const PatchCfg *cfg, int expect_added) {
    TNode *nodes = xmalloc(sizeof(TNode) * MAX_NODES);
    int nn = scan_timing_nodes(d, nodes, MAX_NODES);
    /* 统计非动态节点数增量: 期望 nn = 原数 + added — 这里简单验证所有目标档存在
       (gt7p 克隆档保留 dyn-clk-list 仍为动态节点, 不跳过) */
    int found = 0;
    for (int i = 0; i < nn; i++) {
        if (nodes[i].is_dynamic && !cfg->gt7p) continue;
        for (int t = 0; t < cfg->n; t++) {
            if ((int)nodes[i].rate == cfg->hz[t]) {
                /* 名字必须带该 hz 后缀(粗检) */
                char tmp[32]; snprintf(tmp, sizeof(tmp), "_%d", cfg->hz[t]);
                if (strstr(nodes[i].name, tmp)) { found++; break; }
            }
        }
    }
    free(nodes);
    if (found < expect_added) { fprintf(stderr, "[VERIFY][FAIL] 期望 %d 个新档位, 只找到 %d 个\n", expect_added, found); return -1; }
    return 0;
}

/* ------------------------------------------------------------------ */
/* dtc 子进程                                                          */
/* ------------------------------------------------------------------ */

static void run_dtc(const char *dtc, const char *in, const char *out, int to_dts) {
    pid_t pid = fork();
    if (pid == 0) {
        freopen("/dev/null", "r", stdin);
        execl(dtc, dtc, "-q", to_dts ? "-I" : "-I", to_dts ? "dtb" : "dts",
              "-O", to_dts ? "dts" : "dtb", "-o", out, in, (char*)NULL);
        _exit(127);
    }
    int st; waitpid(pid, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) die("dtc 转换失败 (%s -> %s) exit=%d", in, out, WIFEXITED(st)?WEXITSTATUS(st):-1);
    struct stat sb;
    if (stat(out, &sb) || sb.st_size < 4) die("dtc 输出无效: %s", out);
    if (!to_dts) {
        uint8_t *b = read_file(out, &(size_t){0});
        uint32_t m = be32(b);
        free(b);
        if (m != 0xd00dfeedu) die("dtc 输出不是有效 DTB: %s", out);
    }
}

/* ------------------------------------------------------------------ */
/* 主流程                                                              */
/* ------------------------------------------------------------------ */

static void cmd_info(const char *img_path, const char *dtc, const char *workdir) {
    size_t n; uint8_t *b = read_file(img_path, &n);
    DtboImg img; dtbo_parse(&img, b, n);
    mkdir(workdir, 0755);
    printf("DTBO: ver=%u total=%u entries=%u page=%u file=%zu\n", img.version, img.total, img.count, img.page_size, n);
    AvbInfo ai; avb_inspect(b, n, img.total, &ai);
    if (ai.has_layout) {
        printf("AVB: footer@%d vbmeta@%d+%d orig=%d detached=%d signed=%d algo=%s footers=%d\n",
            ai.layout.footer, ai.layout.vbmeta, ai.layout.size, ai.layout.orig_size,
            ai.layout.detached, ai.signed_, ai.algo, ai.footer_cnt);
    } else printf("AVB: 无\n");
    for (uint32_t i = 0; i < img.count; i++) {
        DtboEntry *e = &img.e[i];
        printf("entry[%u]: size=%u off=%u id=%08x rev=%08x comp=%d\n", i, e->dt_size, e->dt_offset, e->id, e->rev, e->comp);
    }
    if (!dtc) { free(b); free(img.e); return; }
    /* 列出各 entry 的时序家族 */
    char path[4096];
    for (uint32_t i = 0; i < img.count; i++) {
        DtboEntry *e = &img.e[i];
        if (e->comp != 0) { printf("entry[%u]: 压缩条目(comp=%d), 跳过分析\n", i, e->comp); continue; }
        snprintf(path, sizeof(path), "%s/e%u_a.dtb", workdir, i);
        write_file(path, e->stored, e->dt_size);
        char dts_path[4096];
        snprintf(dts_path, sizeof(dts_path), "%s/e%u_a.dts", workdir, i);
        run_dtc(dtc, path, dts_path, 1);
        Dts d; dts_load(&d, dts_path);
        TNode *nodes = xmalloc(sizeof(TNode) * MAX_NODES);
        int nn = scan_timing_nodes(&d, nodes, MAX_NODES);
        printf("entry[%u] 时序节点:\n", i);
        for (int j = 0; j < nn; j++) {
            TNode *t = &nodes[j];
            printf("  %-28s rate=%-4u %ux%u clock=%u(%.3fMHz) %s\n", t->name, t->rate,
                t->width, t->height, t->clock, t->clock / 1000000.0,
                t->is_dynamic ? "[动态]" : "");
        }
        free(nodes); dts_free(&d);
    }
    free(b); free(img.e);
}

/* ------------------------------------------------------------------ */
/* 机型识别: model codename 优先, 时序节点家族指纹兜底                   */
/* ------------------------------------------------------------------ */

/* codename -> 机型 (model = "Qualcomm Technologies, Inc. XXX MTP,codename")
   batt_mod: 是否开放 6100 魔改电池选项 (仅 ACE2Pro/一加11/一加12; 其他新机型虽有
   oplus,batt_capacity_mah 节点但非本方案目标, 容量各异无法按值区分, 按机型白名单) */
static const struct { const char *codename, *code, *name; int batt_mod; } CODE_DEVS[] = {
    { "xigua",    "ace2pro", "一加 ACE2Pro",  1 },
    { "salami",   "op11",    "一加 11",       1 },
    { "waffle",   "op12",    "一加 12",       1 },
    { "pagani",   "op13t",   "一加 13T",      0 },
    { "fairlady", "op15t",   "一加 15T",      0 },
    { "giulia",   "ace5",    "一加 Ace5",     0 },
    { "corvette", "ace3pro", "一加 Ace3 Pro", 0 },
    { "aston",    "ace3",    "一加 Ace3",     0 },
    { "piloti",   "gt7p",    "真我 GT7 Pro 竞速版", 0 },
    { "pista",    "gt7s",    "真我 GT7 Pro",  0 },   /* Sun 平台标准版 (sa_fhd 静态 120 基准) */
    { "lafa",     "gt8p",    "真我 GT8 Pro",  0 },   /* Canoe 平台 (fhd/sdc/wqhd_sdc 144 基准) */
    { "macan",    "ace6t",   "一加 ACE6T",    0 },   /* Alor 平台 (sdc_fhd 165 基准, 同 ace6) */
    { NULL, NULL, NULL, 0 }
};

/* codename 匹配: 全等或 codename-XXX 变体 (macan-CN / macan-EU-US 等) */
static int cn_match(const char *cn, const char *codename) {
    size_t l = strlen(codename);
    if (strncmp(cn, codename, l)) return 0;
    return cn[l] == '\0' || cn[l] == '-';
}

/* 从 model 行提取 codename (最后一个逗号后的部分); 非已知 codename 返回 NULL */
static const char *model_codename(const char *model) {
    if (!model) return NULL;
    const char *last_comma = strrchr(model, ',');
    const char *cn = last_comma ? last_comma + 1 : model;
    /* 去空白 */
    while (*cn == ' ' || *cn == '\t') cn++;
    for (int i = 0; CODE_DEVS[i].codename; i++)
        if (cn_match(cn, CODE_DEVS[i].codename)) return CODE_DEVS[i].codename;
    return NULL;
}

static void cmd_identify(const char *img_path, const char *dtc, const char *workdir) {
    size_t n; uint8_t *b = read_file(img_path, &n);
    DtboImg img; dtbo_parse(&img, b, n);
    mkdir(workdir, 0755);
    int has_sa = 0, has_oa = 0, has_raw = 0, has_wqhd_oplus = 0, has_oplus_fhd = 0;
    int has_fhd_sdc = 0, has_wqhd_sdc = 0, has_sdc_fhd = 0;
    uint32_t max_rate = 0, max_rate_dyn = 0;
    uint32_t max_sa_fhd = 0;   /* gt7p: sa_fhd 家族最高档 (含动态节点, AE035 全动态) */
    char codename[64] = "";
    char path[4096], dts_path[4096];
    for (uint32_t i = 0; i < img.count; i++) {
        DtboEntry *e = &img.e[i];
        if (e->comp != 0) continue;
        snprintf(path, sizeof(path), "%s/ide%u.dtb", workdir, i);
        snprintf(dts_path, sizeof(dts_path), "%s/ide%u.dts", workdir, i);
        write_file(path, e->stored, e->dt_size);
        run_dtc(dtc, path, dts_path, 1);
        Dts d; dts_load(&d, dts_path);
        /* codename 检测: root model 行 */
        if (!codename[0]) {
            for (int li = 0; li < d.n; li++) {
                const char *l = d.lines[li];
                const char *mp = strstr(l, "model = \"");
                if (!mp) continue;
                char model[256];
                snprintf(model, sizeof(model), "%s", mp + 9);
                char *q = strchr(model, '"');
                if (q) *q = 0;
                const char *cn = model_codename(model);
                if (cn) { snprintf(codename, sizeof(codename), "%s", cn); break; }
            }
        }
        TNode *nodes = xmalloc(sizeof(TNode) * MAX_NODES);
        int nn = scan_timing_nodes(&d, nodes, MAX_NODES);
        for (int j = 0; j < nn; j++) {
            TNode *t = &nodes[j];
            if (!t->has_rate) continue;
            if (strstr(t->name, "sa_fhd") && t->rate > max_sa_fhd) max_sa_fhd = t->rate;
            if (t->is_dynamic) {
                /* 全动态镜像 (ace3/ace3pro): 动态节点档位作为 MAX_RATE 兜底 */
                if (t->rate > max_rate_dyn) max_rate_dyn = t->rate;
                continue;
            }
            if (t->rate > max_rate) max_rate = t->rate;
            if (strstr(t->name, "sa_fhd")) has_sa = 1;
            else if (strstr(t->name, "oa_fhd")) has_oa = 1;
            else if (strstr(t->name, "raw_fhd")) has_raw = 1;
            else if (strstr(t->name, "wqhd_oplus")) has_wqhd_oplus = 1;
            else if (strstr(t->name, "oplus_fhd")) has_oplus_fhd = 1;
            else if (strstr(t->name, "fhd_sdc")) has_fhd_sdc = 1;
            else if (strstr(t->name, "wqhd_sdc")) has_wqhd_sdc = 1;
            else if (strstr(t->name, "sdc_fhd")) has_sdc_fhd = 1;
        }
        free(nodes); dts_free(&d);
    }
    const char *code = "unknown", *name = "未知机型";
    int batt_mod = 0;   /* 6100 魔改电池: 机型白名单 (ACE2Pro/一加11/一加12) */
    if (codename[0]) {
        /* codename 优先: 精确机型 */
        for (int i = 0; CODE_DEVS[i].codename; i++) {
            if (!strcmp(codename, CODE_DEVS[i].codename)) {
                code = CODE_DEVS[i].code; name = CODE_DEVS[i].name;
                batt_mod = CODE_DEVS[i].batt_mod;
                break;
            }
        }
    }
    if (!strcmp(code, "unknown")) {
        /* 家族指纹兜底 (旧机型: 无 codename 表条目) */
        if (has_sa || has_oa || has_raw) { code = "ace2pro"; name = "一加 ACE2Pro"; batt_mod = 1; }
        else if (has_wqhd_oplus) { code = "op13"; name = "一加 13"; }
        else if (has_oplus_fhd) { code = "op15"; name = "一加 15"; }
        else if (has_fhd_sdc || has_wqhd_sdc) { code = "gt8"; name = "真我 GT8"; }
        else if (has_sdc_fhd) { code = "ace6"; name = "一加 ACE6"; }
    }
    if (!strcmp(code, "gt7p")) {
        /* GT7P 竞速版: AE035 活动面板时序全为动态 (带 dyn-clk-list),
           静态 sim 面板的 240Hz 不代表面板能力, 取 sa_fhd 家族实际最高档 */
        if (max_sa_fhd) max_rate = max_sa_fhd;
    }
    if (max_rate == 0) max_rate = max_rate_dyn;
    int oc_capable = strcmp(code, "op11") != 0;   /* 一加11 仅电池/充电方案 */
    printf("DEVICE=%s\n", code);
    printf("NAME=%s\n", name);
    printf("MAX_RATE=%u\n", max_rate);
    printf("BATT_MOD_CAPABLE=%d\n", batt_mod);
    printf("OC_CAPABLE=%d\n", oc_capable);
    fprintf(stderr, "[识别] %s (%s) 原厂最高档 %uHz%s%s, 超频: %s, 电池方案: 解除限流/电池解容(全机型)%s\n",
        name, code, max_rate, codename[0] ? " codename=" : "", codename[0] ? codename : "",
        oc_capable ? "支持" : "不支持(一加11)", batt_mod ? "/6100mAh魔改" : "");
    free(b); free(img.e);
}

/* ------------------------------------------------------------------ */
/* 按键监听: EVIOCGRAB 拦截音量/电源键, 电源键不会传给系统导致息屏      */
/* ------------------------------------------------------------------ */

#define KEV_TYPE_KEY 0x01
#define KEV_VOLDN 114
#define KEV_VOLUP 115
#define KEV_POWER 116

struct kev {
    uint64_t sec, usec;
    uint16_t type, code;
    int32_t value;
};

/* 计算 Linux ioctl 命令字 (_IOC(dir,size,type,nr)), 避免依赖 linux/input.h */
static unsigned long kev_ioc(int dir, int size, char type, int nr) {
    return ((unsigned long)dir << 30) | ((unsigned long)size << 16) |
           ((unsigned long)(unsigned char)type << 8) | (unsigned long)nr;
}

/* keys 子命令: 打开并 GRAB 含音量/电源键的输入设备, 阻塞等待一次有效按键。
   GRAB 期间按键事件被本进程独占, 系统收不到 -> 电源键确认不会息屏, 音量键不会弹音量条。
   输出: up / down / select; 失败 (无设备/权限) 返回 1, 调用方回退 getevent。 */
static int cmd_keys(void) {
    enum { MAXFD = 32 };
    int fds[MAXFD]; int nf = 0;
    const char *dir = getenv("DTBO_KEYS_INPUT_DIR");   /* 测试钩子, 设备上留空 */
    if (!dir || !*dir) dir = "/dev/input";
    DIR *d = opendir(dir);
    if (!d) return 1;
    struct dirent *de;
    char path[512];
    while ((de = readdir(d)) != NULL && nf < MAXFD) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        unsigned char bits[96];
        memset(bits, 0, sizeof(bits));
        /* EVIOCGBIT(EV_KEY): 查询设备上报的按键位图 */
        if (ioctl(fd, kev_ioc(2, (int)sizeof(bits), 'E', 0x20 + KEV_TYPE_KEY), bits) < 0) {
            close(fd); continue;
        }
        int codes[3] = { KEV_VOLDN, KEV_VOLUP, KEV_POWER };
        int has = 0;
        for (int i = 0; i < 3; i++)
            if (bits[codes[i] >> 3] & (1 << (codes[i] & 7))) has = 1;
        if (!has) { close(fd); continue; }   /* 触摸屏等无关设备不拦截 */
        if (ioctl(fd, kev_ioc(1, 4, 'E', 0x90), 1) < 0) { close(fd); continue; } /* EVIOCGRAB */
        fds[nf++] = fd;
    }
    closedir(d);
    if (nf == 0) return 1;
    struct pollfd pf[MAXFD];
    for (int i = 0; i < nf; i++) { pf[i].fd = fds[i]; pf[i].events = POLLIN; pf[i].revents = 0; }
    const char *out = NULL;
    int alive = nf;
    while (!out && alive > 0) {
        int pr = poll(pf, (nfds_t)nf, -1);
        if (pr <= 0) { if (errno == EINTR) continue; break; }
        for (int i = 0; i < nf && !out; i++) {
            if (pf[i].fd < 0) continue;
            if (pf[i].revents & POLLIN) {
                for (;;) {
                    struct kev ev;
                    ssize_t r = read(fds[i], &ev, sizeof(ev));
                    if (r != (ssize_t)sizeof(ev)) break;   /* EAGAIN/异常 */
                    if (ev.type == KEV_TYPE_KEY && ev.value == 1) {  /* 仅按下, 忽略释放/长按重复 */
                        if (ev.code == KEV_VOLUP) out = "up";
                        else if (ev.code == KEV_VOLDN) out = "down";
                        else if (ev.code == KEV_POWER) out = "select";
                        if (out) break;
                    }
                }
            }
            if ((pf[i].revents & (POLLERR | POLLHUP)) && !out) {
                close(fds[i]); fds[i] = -1; pf[i].fd = -1; pf[i].events = 0; alive--;
            }
        }
    }
    for (int i = 0; i < nf; i++) if (fds[i] >= 0) close(fds[i]);  /* 关闭即自动解除 GRAB */
    if (!out) return 1;
    puts(out);
    return 0;
}

static void parse_hz_list(const char *s, PatchCfg *cfg) {
    cfg->n = 0;
    char tmp[512]; snprintf(tmp, sizeof(tmp), "%s", s);
    char *save, *tok;
    for (tok = strtok_r(tmp, ", ", &save); tok; tok = strtok_r(NULL, ", ", &save)) {
        int hz = atoi(tok);
        if (hz < 30 || hz > 360) die("非法刷新率: %d", hz);
        if (cfg->n >= 16) die("刷新率列表过长 (<=16)");
        cfg->hz[cfg->n++] = hz;
    }
    /* 降序排序(从大到小应用) */
    for (int i = 0; i < cfg->n; i++) for (int j = i + 1; j < cfg->n; j++)
        if (cfg->hz[j] > cfg->hz[i]) { int t = cfg->hz[i]; cfg->hz[i] = cfg->hz[j]; cfg->hz[j] = t; }
}

static void parse_clock_override(const char *s, PatchCfg *cfg) {
    cfg->ov_n = 0;
    if (!s || !s[0]) return;
    char tmp[1024]; snprintf(tmp, sizeof(tmp), "%s", s);
    char *save, *tok;
    for (tok = strtok_r(tmp, ", ", &save); tok; tok = strtok_r(NULL, ", ", &save)) {
        char *colon = strchr(tok, ':');
        if (!colon) die("clock-override 格式错误: %s (应为 hz:clock)", tok);
        *colon = 0;
        cfg->ov_hz[cfg->ov_n] = (uint32_t)atoi(tok);
        cfg->ov_clk[cfg->ov_n] = strtoull(colon + 1, NULL, 10);
        if (++cfg->ov_n >= 16) die("clock-override 过多");
    }
}

static int cmd_patch(const char *in_path, const char *out_path, const char *dtc,
                     const char *workdir, PatchCfg *cfg, int verbose, const char *stock_path,
                     BattCfg *bc) {
    size_t n; uint8_t *b = read_file(in_path, &n);
    DtboImg img; dtbo_parse(&img, b, n);
    /* 输入 AVB 校验(分析级) */
    AvbInfo ai; avb_inspect(b, n, img.total, &ai);
    mkdir(workdir, 0755);
    char path[4096];
    /* 可选: 加载原始(stock)镜像, 用于排除 OC 节点作为克隆基准 */
    uint8_t *stock_b = NULL; DtboImg stock_img; memset(&stock_img, 0, sizeof(stock_img));
    int have_stock = 0;
    if (stock_path && strcmp(stock_path, in_path)) {
        size_t sn; stock_b = read_file(stock_path, &sn);
        dtbo_parse(&stock_img, stock_b, sn);
        have_stock = 1;
        if (verbose) fprintf(stderr, "[INFO] stock 镜像: %s (entries=%u)\n", stock_path, stock_img.count);
    }
    /* 替换表 */
    uint8_t **repl = xmalloc(sizeof(uint8_t*) * img.count);
    size_t *repl_n = xmalloc(sizeof(size_t) * img.count);
    int *replaced = xmalloc(sizeof(int) * img.count);
    int total_added = 0;
    for (uint32_t i = 0; i < img.count; i++) {
        repl[i] = NULL; repl_n[i] = 0; replaced[i] = 0;
        DtboEntry *e = &img.e[i];
        if (e->comp != 0) {
            fprintf(stderr, "[WARN] entry[%u] 为压缩条目 (comp=%d), 模块暂不支持修改压缩条目, 保持原样\n", i, e->comp);
            continue;
        }
        /* stock 条目的节点名集合 (无 stock 信息时传 -1 = 不过滤) */
        char (*stock_names)[160] = NULL;
        int stock_n = -1;
        if (have_stock && i < stock_img.count && stock_img.e[i].comp == 0) {
            char s_dtb[4096], s_dts[4096];
            snprintf(s_dtb, sizeof(s_dtb), "%s/e%u_stock.dtb", workdir, i);
            snprintf(s_dts, sizeof(s_dts), "%s/e%u_stock.dts", workdir, i);
            write_file(s_dtb, stock_img.e[i].stored, stock_img.e[i].dt_size);
            run_dtc(dtc, s_dtb, s_dts, 1);
            Dts sd; dts_load(&sd, s_dts);
            TNode *sn = xmalloc(sizeof(TNode) * MAX_NODES);
            int snn = scan_timing_nodes(&sd, sn, MAX_NODES);
            stock_names = xmalloc(sizeof(char[160]) * (snn > 0 ? snn : 1));
            stock_n = 0;
            for (int k = 0; k < snn; k++) {
                /* 静态节点必须收录; 动态节点也收录 (ace3/ace3pro 全动态镜像需要
                   它们作为克隆基准), patch_dts 的两遍分组会正确处理优先级 */
                snprintf(stock_names[stock_n], 160, "%s", sn[k].name);
                stock_n++;
            }
            free(sn); dts_free(&sd);
        }
        char in_dtb[4096], in_dts[4096], out_dts[4096], out_dtb[4096], chk_dts[4096];
        snprintf(in_dtb, sizeof(in_dtb), "%s/e%u_in.dtb", workdir, i);
        snprintf(in_dts, sizeof(in_dts), "%s/e%u_in.dts", workdir, i);
        snprintf(out_dts, sizeof(out_dts), "%s/e%u_out.dts", workdir, i);
        snprintf(out_dtb, sizeof(out_dtb), "%s/e%u_out.dtb", workdir, i);
        snprintf(chk_dts, sizeof(chk_dts), "%s/e%u_chk.dts", workdir, i);
        write_file(in_dtb, e->stored, e->dt_size);
        run_dtc(dtc, in_dtb, in_dts, 1);
        Dts d; dts_load(&d, in_dts);
        /* 电池补丁先于时序克隆 (行替换/删除不影响后续重扫描) */
        int batt_changed = patch_battery_dts(&d, bc, verbose);
        int added = patch_dts(&d, cfg, verbose, stock_names, stock_n);
        free(stock_names);
        if (added <= 0 && batt_changed <= 0) { dts_free(&d); continue; }
        dts_save(&d, out_dts);
        dts_free(&d);
        run_dtc(dtc, out_dts, out_dtb, 0);
        /* 编译后校验 */
        run_dtc(dtc, out_dtb, chk_dts, 1);
        Dts vd; dts_load(&vd, chk_dts);
        if (verify_dts(&vd, cfg, added) != 0) die("entry[%u] 补丁后校验失败, 中止", i);
        if (bc->mode && verify_battery_dts(&vd, bc) != 0) die("entry[%u] 电池补丁校验失败, 中止", i);
        dts_free(&vd);
        repl[i] = read_file(out_dtb, &repl_n[i]);
        replaced[i] = 1;
        total_added += added;
        if (batt_changed > 0)
            fprintf(stderr, "[OK] entry[%u]: 电池补丁 %d 处 (%u -> %zu 字节)\n", i, batt_changed, e->dt_size, repl_n[i]);
        if (added > 0)
            fprintf(stderr, "[OK] entry[%u]: 新增 %d 个超频档位 (%u -> %zu 字节)\n", i, added, e->dt_size, repl_n[i]);
    }
    if (BATT_MODIFY(bc->mode) && !bc->saw_cap)
        die("魔改电池模式开启但未找到 qcom,batt_capacity_mah 节点 (仅 ACE2Pro/一加12 支持魔改, 请勿在其他机型使用)");
    if (BATT_V2800(bc->mode) && bc->v2800_hits == 0 && bc->v2800_ins == 0)
        die("关机电压2800模式未找到可修改的关机电压节点 (qcom,vbatt_power_off / oplus,chg_shutdown_max_mv)");
    if ((bc->mode == 1 || bc->mode == 2) && bc->removed_lines == 0 && bc->strat_hits == 0)
        die("解除充电限流模式未找到可修改的限流节点 (qcom 限流节点 / oplus 策略表)");
    if (total_added == 0 &&
        !(bc->mode && (bc->cap_hits || bc->vmap_hits || bc->removed_lines || bc->strat_hits || bc->v2800_hits || bc->v2800_ins || bc->gt7p_hits))) {
        fprintf(stderr, "[DONE] 没有任何条目被修改 (无需档位或已有档位)\n");
        write_file(out_path, b, n);
        free(b); free(img.e); free(repl); free(repl_n); free(replaced);
        if (have_stock) { free(stock_b); free(stock_img.e); }
        return 3;
    }
    /* 重建 DTBO 表 */
    size_t payload_cap = img.prefix_len + 64;
    for (uint32_t i = 0; i < img.count; i++)
        payload_cap += replaced[i] ? repl_n[i] : img.e[i].dt_size;
    uint8_t *payload = xmalloc(payload_cap);
    memcpy(payload, b, img.prefix_len);
    size_t off = img.prefix_len;
    for (uint32_t i = 0; i < img.count; i++) {
        DtboEntry *e = &img.e[i];
        size_t sz = replaced[i] ? repl_n[i] : e->dt_size;
        uint8_t *ep = payload + img.entries_off + (size_t)i * img.entry_size;
        put32(ep, (uint32_t)sz);
        put32(ep + 4, (uint32_t)off);
        if (replaced[i]) {
            if (e->has_flags) put32(ep + 16, e->flags & ~0xfu);  /* 修改条目一律不压缩 */
        }
        const uint8_t *src = replaced[i] ? repl[i] : e->stored;
        memcpy(payload + off, src, sz);
        off += sz;
    }
    put32(payload + 4, (uint32_t)off);  /* total_size */
    /* AVB 重建 */
    size_t out_n;
    uint8_t *out = avb_rebuild(b, n, (int)img.total, payload, off, &out_n);
    write_file(out_path, out, out_n);
    if (bc->mode) {
        static const char *mdesc[7] = {
            "关闭",
            "解除充电限流",
            "解除充电限流+关机电压2800(电池解容)",
            "6100mAh魔改",
            "6100mAh魔改+解除限流",
            "原版电池+关机电压2800(电池解容)",
            "GT7P解容(满充4.55V/关机2.85V/解除限流)"
        };
        if (bc->mode == 6)
            printf("[DONE] 已生成 %s (%zu 字节, 新增 %d 个档位, 电池=%s: 解容替换/放大 x%d)\n",
                out_path, out_n, total_added, mdesc[6], bc->gt7p_hits);
        else
            printf("[DONE] 已生成 %s (%zu 字节, 新增 %d 个档位, 电池=%s: 容量x%d 关机3.0V x%d 1%%电压x%d 电压段x%d 关机2800替换x%d插入x%d 删限流x%d 策略电流x%d)\n",
                out_path, out_n, total_added, mdesc[bc->mode], bc->cap_hits, bc->voff_hits, bc->v1p_hits, bc->vmap_hits,
                bc->v2800_hits, bc->v2800_ins, bc->removed_lines, bc->strat_hits);
    }
    else
        printf("[DONE] 已生成 %s (%zu 字节, 新增 %d 个档位, DTBO total %zu)\n", out_path, out_n, total_added, off);
    free(out); free(payload);
    for (uint32_t i = 0; i < img.count; i++) free(repl[i]);
    free(repl); free(repl_n); free(replaced);
    if (have_stock) { free(stock_b); free(stock_img.e); }
    free(b); free(img.e);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "dtbo_oc — DTBO 刷新率超频 + 电池/充电方案 (保留原档位, 追加新档位)\n"
            "用法:\n"
            "  dtbo_oc identify --img X --dtc PATH [--workdir D]\n"
            "      输出 DEVICE=ace2pro|op12|op13|op13t|op15|op15t|ace3|ace3pro|ace5|ace6|ace6t|gt8|gt8p|gt7p|gt7s|op11|unknown\n"
            "  dtbo_oc info --img X [--dtc PATH --workdir D]\n"
            "  dtbo_oc patch --img IN --out OUT --dtc PATH --hz 130,132,138,141,144,150\n"
            "      [--workdir D] [--wxh WxH] [--exclude-family raw] [--include-family sa,sdc]\n"
            "      [--clock-override 144:1315000000,165:1505156480]\n"
            "      [--stock-img 原始镜像 (排除已有OC节点作为克隆基准)]\n"
            "      [--margin-low 1.012205] [--margin-high 1.021537] [--no-phy]\n"
            "      [--gt7p]  GT7 Pro 竞速版简单克隆模式 (sa_fhd 动态基准, 保留 dyn-clk, porch/phy 原值)\n"
            "      [--battery 0-6]  0=不改(默认)\n"
            "                      1=解除充电限流 (全机型: 老平台删qcom限流节点/新平台策略表电流x2)\n"
            "                      2=解除充电限流+关机电压2800 电池解容 (全机型)\n"
            "                      3=6100mAh魔改电池 (关机3.0V/1%3.05V/满充4.54V)\n"
            "                      4=6100mAh魔改电池+解除充电限流\n"
            "                      5=原版电池+关机电压2800 电池解容 (全机型)\n"
            "                      6=GT7P竞速版解容: 满充4.55V+关机2.85V+解除充电限流 (仅 gt7p 机型)\n"
            "      [-v]\n");
        return 2;
    }
    const char *cmd = argv[1];
    const char *img = NULL, *out = NULL, *dtc = NULL, *workdir = "/tmp/dtbo_oc_work";
    const char *hz = NULL, *wxh = NULL, *exclude = "raw,oa", *include = "", *cov = "";
    const char *stock = NULL;
    int battery = 0;
    double mlow = 1.012205, mhigh = 1.021537;
    int no_phy = 0, verbose = 0, gt7p = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--img") && i+1 < argc) img = argv[++i];
        else if (!strcmp(argv[i], "--stock-img") && i+1 < argc) stock = argv[++i];
        else if (!strcmp(argv[i], "--out") && i+1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--dtc") && i+1 < argc) dtc = argv[++i];
        else if (!strcmp(argv[i], "--workdir") && i+1 < argc) workdir = argv[++i];
        else if (!strcmp(argv[i], "--hz") && i+1 < argc) hz = argv[++i];
        else if (!strcmp(argv[i], "--wxh") && i+1 < argc) wxh = argv[++i];
        else if (!strcmp(argv[i], "--exclude-family") && i+1 < argc) exclude = argv[++i];
        else if (!strcmp(argv[i], "--include-family") && i+1 < argc) include = argv[++i];
        else if (!strcmp(argv[i], "--clock-override") && i+1 < argc) cov = argv[++i];
        else if (!strcmp(argv[i], "--margin-low") && i+1 < argc) mlow = atof(argv[++i]);
        else if (!strcmp(argv[i], "--margin-high") && i+1 < argc) mhigh = atof(argv[++i]);
        else if (!strcmp(argv[i], "--battery") && i+1 < argc) battery = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-phy")) no_phy = 1;
        else if (!strcmp(argv[i], "--gt7p")) gt7p = 1;
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else die("未知参数: %s", argv[i]);
    }
    if (!strcmp(cmd, "keys")) return cmd_keys();
    if (!img) die("缺少 --img");
    if (!strcmp(cmd, "identify")) {
        if (!dtc) die("identify 需要 --dtc");
        cmd_identify(img, dtc, workdir);
        return 0;
    }
    if (!strcmp(cmd, "info")) { cmd_info(img, dtc, workdir); return 0; }
    if (!strcmp(cmd, "patch")) {
        if (!out || !dtc) die("patch 需要 --out --dtc");
        if (battery < 0 || battery > 6) die("--battery 取值 0/1/2/3/4/5/6");
        if (battery == 6 && !gt7p) die("--battery 6 (GT7P 解容) 需配合 --gt7p 使用");
        PatchCfg cfg; memset(&cfg, 0, sizeof(cfg));
        BattCfg bc; memset(&bc, 0, sizeof(bc));
        bc.mode = battery;
        if (hz) parse_hz_list(hz, &cfg);   /* --hz 可省略: 不超频机型仅电池/充电方案 (如一加11) */
        cfg.margin_low = mlow; cfg.margin_high = mhigh;
        cfg.modify_phy = !no_phy;
        cfg.gt7p = gt7p;
        if (wxh && strcmp(wxh, "auto")) {
            if (sscanf(wxh, "%ux%u", &cfg.wx, &cfg.wy) != 2) die("--wxh 格式: 宽x高 (如 1240x2772)");
            cfg.wxh_filter = 1;
        }
        snprintf(cfg.exclude, sizeof(cfg.exclude), "%s", exclude);
        snprintf(cfg.include, sizeof(cfg.include), "%s", include);
        parse_clock_override(cov, &cfg);
        return cmd_patch(img, out, dtc, workdir, &cfg, verbose, stock, &bc);
    }
    die("未知命令: %s", cmd);
    return 2;
}
