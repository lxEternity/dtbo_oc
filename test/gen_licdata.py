#!/usr/bin/env python3
"""生成 src/lic_data.h — XOR 混淆内嵌: HMAC密钥 / 群号 / 名单URL
真实密钥仅存在于本仓库源码与官方发布二进制中, 修改密钥会使所有已发授权失效."""
import os, secrets

XOR = secrets.token_bytes(16)
KEY = secrets.token_bytes(32)
GRP = "1124737265"
URL1 = "https://raw.githubusercontent.com/lxEternity/dtbo_oc/main/group/members.txt"
URL2 = "https://cdn.jsdelivr.net/gh/lxEternity/dtbo_oc@main/group/members.txt"

def enc(s: str) -> bytes:
    b = s.encode()
    return bytes(b[i] ^ XOR[i & 15] for i in range(len(b)))

def arr(name: str, data: bytes) -> str:
    return "static const unsigned char %s[%d] = {%s};" % (
        name, len(data), ",".join(str(x) for x in data))

hdr = """/* lic_data.h — 自动生成 (test/gen_licdata.py), 勿手改
 * XOR 混淆内嵌数据: strings 不可直接读出密钥/群号/名单URL
 * LIC_KEY: license HMAC-SHA256 密钥 (32B)
 * GRP:     授权QQ群号
 * URL1/2:  云端群成员名单拉取地址 (主: GitHub raw / 备: jsDelivr)
 */
#ifndef LIC_DATA_H
#define LIC_DATA_H
%s
%s
%s
%s
%s
#endif
""" % (arr("LIC_XOR", XOR), arr("LIC_KEY_C", KEY),
       arr("GRP_C", enc(GRP)), arr("URL1_C", enc(URL1)), arr("URL2_C", enc(URL2)))

with open(os.path.join(os.path.dirname(__file__), "..", "src", "lic_data.h"), "w") as f:
    f.write(hdr)
print("lic_data.h 已生成:", len(hdr), "bytes")
