//
//  TRSelfSignedCert.h
//  自签证书生成（trollvncserver / trollvncmanager 共享）
//
//  说明：从 TRCapabilityRegistry.mm 抽出（原 TRGenerateSelfSignedCert 仅编译进
//  trollvncmanager），供两个二进制复用，避免重复实现。等价对齐 app 侧
//  ZTSelfSignedCertificate.m（Security 私有函数路径），并补 IP SAN——
//  借鉴网关 gen-cert.mjs 的 collectIPv4 + subjectAltName 思路，
//  消除浏览器"证书与域名不匹配"警告（仅剩自签 CA 信任提示）。
//

#import <Foundation/Foundation.h>

/** 生成 RSA2048 自签证书（CA:TRUE pathLen=0 + keyUsage + EKU + IP SAN）
 *  @param commonName 证书 CN 字符串
 *  @param certPEM    输出：证书 PEM（-----BEGIN CERTIFICATE-----）
 *  @param keyPEM     输出：私钥 PEM（-----BEGIN RSA PRIVATE KEY-----，PKCS#1）
 *  @return BOOL 生成成功
 */
BOOL TRGenerateSelfSignedCert(NSString *commonName, NSString **certPEM, NSString **keyPEM);

/** 收集本机全部非内部 IPv4（用于证书 SAN，保证任意内网 IP 访问不报域名不匹配）
 *  @return IPv4 字符串数组（含 127.0.0.1）
 */
NSArray<NSString *> *TRIPAddresses(void);
