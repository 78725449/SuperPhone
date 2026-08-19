/*
 This file is part of SuperPhone
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "TRSelfSignedCert.h"

#import <ifaddrs.h>
#import <net/if.h>
#import <arpa/inet.h>

// Security 私有符号（与 ZTSelfSignedCertificate.m 一致，SecGenerateSelfSignedCertificate 为私有函数）
// extern "C" 保证 C 链接（.mm C++ 下默认名字修饰会导致链接找不到 _SecGenerateSelfSignedCertificate）
extern "C" {
extern SecCertificateRef SecGenerateSelfSignedCertificate(CFArrayRef subject, CFDictionaryRef __nullable parameters,
                                                          SecKeyRef publicKey, SecKeyRef privateKey);
extern const CFStringRef kSecOidCommonName;
extern const CFStringRef kSecCSRBasicContraintsPathLen;
extern const CFStringRef kSecCertificateKeyUsage;
extern const CFStringRef kSecCertificateExtensionsEncoded;
} // extern "C"

// keyUsage bit 定义（对齐 SecCertificatePriv.h / ZTSelfSignedCertificate.m）
enum {
    kTRKeyUsageDigitalSignature = 1 << 0,
    kTRKeyUsageKeyEncipherment = 1 << 2,
    kTRKeyUsageKeyCertSign = 1 << 5,
    kTRKeyUsageCRLSign = 1 << 6,
};

/** DER → PEM（64 字符折行，对齐 ZTSelfSignedCertificate.m 的 ZTPEMFromDER） */
static NSString *TRPEMFromDER(NSData *der, NSString *header, NSString *footer) {
    if (!der) return nil;
    NSString *b64 = [der base64EncodedStringWithOptions:0];
    NSMutableString *pem = [NSMutableString string];
    [pem appendFormat:@"-----BEGIN %@-----\n", header];
    const NSUInteger lineLen = 64;
    for (NSUInteger i = 0; i < b64.length; i += lineLen) {
        NSUInteger len = MIN(lineLen, b64.length - i);
        [pem appendFormat:@"%@\n", [b64 substringWithRange:NSMakeRange(i, len)]];
    }
    [pem appendFormat:@"-----END %@-----\n", footer];
    return pem;
}

/** 手工构造 EKU = { serverAuth, clientAuth } 的 DER（对齐 ZTSelfSignedCertificate.m 的 ZTExtendedKeyUsageDER） */
static NSData *TRExtendedKeyUsageDER(void) {
    // 30 14       SEQUENCE, length 0x14
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 01   (1.3.6.1.5.5.7.3.1 serverAuth)
    //    06 08    OBJECT IDENTIFIER, length 8
    //       2b 06 01 05 05 07 03 02   (1.3.6.1.5.5.7.3.2 clientAuth)
    static const uint8_t ekuBytes[] = {0x30, 0x14, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03,
                                       0x01, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02};
    return [NSData dataWithBytes:ekuBytes length:sizeof(ekuBytes)];
}

/** 手工构造 subjectAltName（2.5.29.17）扩展值的 DER：SEQUENCE of GeneralName
 *  条目：DNS:localhost + IP:各网卡 IPv4（借鉴网关 gen-cert.mjs 的 SAN 策略）
 *  @param ips 待加入的 IP 列表（IPv4）
 *  @return 扩展值 DER（不含 OID/头）；失败返回 nil
 */
static NSData *TRSubjectAltNameDER(NSArray<NSString *> *ips) {
    NSMutableData *body = [NSMutableData data];
    // dNSName [2] IMPLICIT IA5String：0x82 len ascii
    const char *dns = "localhost";
    uint8_t dnsHdr[] = {0x82, (uint8_t)strlen(dns)};
    [body appendBytes:dnsHdr length:2];
    [body appendBytes:dns length:strlen(dns)];
    // iPAddress [7] IMPLICIT OCTET STRING：0x87 0x04 <4 字节>
    for (NSString *ip in ips) {
        struct in_addr addr;
        if (inet_pton(AF_INET, ip.UTF8String, &addr) != 1) continue;
        uint8_t ipHdr[] = {0x87, 0x04};
        [body appendBytes:ipHdr length:2];
        [body appendBytes:&addr length:4];
    }
    if (body.length > 127) return nil; // 单字节长度上限（内网 IP 数量远达不到）
    // SEQUENCE 包装
    uint8_t seqHdr[] = {0x30, (uint8_t)body.length};
    NSMutableData *san = [NSMutableData data];
    [san appendBytes:seqHdr length:2];
    [san appendBytes:body.bytes length:body.length];
    return san;
}

NSArray<NSString *> *TRIPAddresses(void) {
    NSMutableArray *ips = [NSMutableArray arrayWithObject:@"127.0.0.1"];
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (struct ifaddrs *ifa = ifap; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if ((ifa->ifa_flags & IFF_LOOPBACK) || (ifa->ifa_flags & IFF_UP) == 0) continue;
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                NSString *s = [NSString stringWithUTF8String:buf];
                if (s && ![ips containsObject:s]) [ips addObject:s];
            }
        }
        freeifaddrs(ifap);
    }
    return ips;
}

BOOL TRGenerateSelfSignedCert(NSString *commonName, NSString **certPEM, NSString **keyPEM) {
    OSStatus status = errSecSuccess;
    SecKeyRef publicKey = NULL;
    SecKeyRef privateKey = NULL;
    SecCertificateRef cert = NULL;
    CFMutableDictionaryRef certParams = NULL;
    CFMutableDictionaryRef encodedExts = NULL;
    CFArrayRef subject = NULL;
    CFArrayRef cnPair = NULL;
    CFArrayRef cnRDN = NULL;
    CFStringRef cfCommonName = (__bridge CFStringRef)commonName;
    BOOL ok = NO;

    // 1. 生成 RSA key pair (2048 bit)
    {
        CFMutableDictionaryRef keyParams =
            CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                      &kCFTypeDictionaryValueCallBacks);
        if (!keyParams) goto cleanup;
        CFDictionaryAddValue(keyParams, kSecAttrKeyType, kSecAttrKeyTypeRSA);
        int keySize = 2048;
        CFNumberRef keySizeNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keySize);
        CFDictionaryAddValue(keyParams, kSecAttrKeySizeInBits, keySizeNum);
        CFRelease(keySizeNum);
        CFDictionaryAddValue(keyParams, kSecAttrLabel, cfCommonName);
        status = SecKeyGeneratePair(keyParams, &publicKey, &privateKey);
        CFRelease(keyParams);
        if (status != errSecSuccess || !publicKey || !privateKey) goto cleanup;
    }

    // 2. 构造 certParams：CA:TRUE pathLen=0 + keyUsage + EKU(serverAuth+clientAuth) + SAN(IP+localhost)
    certParams = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    if (!certParams) goto cleanup;
    {
        CFIndex pathLenValue = 0;
        CFNumberRef pathLen = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &pathLenValue);
        CFDictionarySetValue(certParams, kSecCSRBasicContraintsPathLen, pathLen);
        CFRelease(pathLen);
    }
    {
        int keyUsageValue = kTRKeyUsageDigitalSignature | kTRKeyUsageKeyEncipherment |
                            kTRKeyUsageKeyCertSign | kTRKeyUsageCRLSign;
        CFNumberRef keyUsageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &keyUsageValue);
        CFDictionarySetValue(certParams, kSecCertificateKeyUsage, keyUsageNum);
        CFRelease(keyUsageNum);
    }
    {
        encodedExts = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
        if (!encodedExts) goto cleanup;
        NSData *ekuDER = TRExtendedKeyUsageDER();
        // bytes 为 const void*，CFDataCreate 需 const UInt8*（.mm C++ 下需显式转换）
        CFDataRef ekuData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)ekuDER.bytes, (CFIndex)ekuDER.length);
        if (!ekuData) goto cleanup;
        CFDictionarySetValue(encodedExts, CFSTR("2.5.29.37"), ekuData); // id-ce-extKeyUsage
        CFRelease(ekuData);
        // subjectAltName：DNS:localhost + IP:各网卡（2026-08-19，借鉴网关 gen-cert.mjs）
        NSData *sanDER = TRSubjectAltNameDER(TRIPAddresses());
        if (sanDER) {
            CFDataRef sanData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)sanDER.bytes, (CFIndex)sanDER.length);
            if (sanData) {
                CFDictionarySetValue(encodedExts, CFSTR("2.5.29.17"), sanData); // id-ce-subjectAltName
                CFRelease(sanData);
            }
        }
        CFDictionarySetValue(certParams, kSecCertificateExtensionsEncoded, encodedExts);
    }

    // 3. 构造 subject（三层数组结构，仅一个 CN）
    {
        const void *cnFields[2] = {kSecOidCommonName, cfCommonName};
        cnPair = CFArrayCreate(kCFAllocatorDefault, cnFields, 2, &kCFTypeArrayCallBacks);
        if (!cnPair) goto cleanup;
        const void *cnRDNFields[1] = {cnPair};
        cnRDN = CFArrayCreate(kCFAllocatorDefault, cnRDNFields, 1, &kCFTypeArrayCallBacks);
        if (!cnRDN) goto cleanup;
        const void *rdnList[1] = {cnRDN};
        subject = CFArrayCreate(kCFAllocatorDefault, rdnList, 1, &kCFTypeArrayCallBacks);
        if (!subject) goto cleanup;
    }

    // 4. 生成自签 CA 证书
    cert = SecGenerateSelfSignedCertificate(subject, certParams, publicKey, privateKey);
    if (!cert) goto cleanup;

    // 5. 导出证书（DER → PEM）
    {
        CFDataRef certData = SecCertificateCopyData(cert);
        if (!certData) goto cleanup;
        NSData *derCert = (__bridge_transfer NSData *)certData;
        NSString *pem = TRPEMFromDER(derCert, @"CERTIFICATE", @"CERTIFICATE");
        if (!pem) goto cleanup;
        if (certPEM) *certPEM = pem;
    }

    // 6. 导出私钥（DER → PEM，PKCS#1 RSA PRIVATE KEY）
    {
        CFErrorRef error = NULL;
        CFDataRef keyData = SecKeyCopyExternalRepresentation(privateKey, &error);
        if (!keyData) {
            if (error) CFRelease(error);
            goto cleanup;
        }
        NSData *derKey = (__bridge_transfer NSData *)keyData;
        NSString *pem = TRPEMFromDER(derKey, @"RSA PRIVATE KEY", @"RSA PRIVATE KEY");
        if (!pem) goto cleanup;
        if (keyPEM) *keyPEM = pem;
    }

    ok = (*certPEM != nil && *keyPEM != nil);

cleanup:
    if (cert) CFRelease(cert);
    if (publicKey) CFRelease(publicKey);
    if (privateKey) CFRelease(privateKey);
    if (certParams) CFRelease(certParams);
    if (encodedExts) CFRelease(encodedExts);
    if (subject) CFRelease(subject);
    if (cnPair) CFRelease(cnPair);
    if (cnRDN) CFRelease(cnRDN);
    return ok;
}
