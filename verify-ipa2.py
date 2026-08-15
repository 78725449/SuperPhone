# -*- coding: utf-8 -*-
# 验证新 IPA：二进制 arm64+签名、index.vnc 手机端光标策略、服务端圆点数据
import zipfile, struct

TIP = r'C:\Users\Administrator\Documents\ChatGPT\New project\ipa-tmp\TrollVNC_0.0.1.tipa'

def check_macho(data, name):
    if len(data) < 4:
        return f'{name}: 文件过小'
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic not in (0xfeedface, 0xfeedfacf):
        return f'{name}: 非 Mach-O (magic=0x{magic:08x})!'
    is64 = magic == 0xfeedfacf
    cputype = struct.unpack_from('<I', data, 4)[0]
    ncmds = struct.unpack_from('<I', data, 16 if is64 else 12)[0]
    hdr_end = 32 if is64 else 28
    codesign = 0
    pos = hdr_end
    for _ in range(ncmds):
        if pos + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from('<II', data, pos)
        if cmd == 0x1d:
            codesign += 1
        pos += cmdsize
    arch = 'arm64' if cputype == 0x0100000c else f'cputype=0x{cputype:x}'
    return f'{name}: {arch} LC_CODE_SIGNATURE={codesign} {"SIGNED" if codesign else "未签名!"}'

with zipfile.ZipFile(TIP) as z:
    names = z.namelist()
    print('条目数:', len(names))

    for bn in [n for n in names if any(n.endswith(x) for x in ('/TrollVNC', '/trollvncserver', '/trollvncmanager'))]:
        print(check_macho(z.read(bn), bn))

    # index.vnc 手机端光标策略
    iv = z.read('Payload/TrollVNC.app/webclients/index.vnc').decode('utf-8', errors='replace')
    print('\nindex.vnc:')
    print('  含 isTouch 光标分支:', 'if (isTouch)' in iv and 'rfb.showDotCursor = false' in iv)
    print('  含 CURSOR_IDLE_MS 1500:', 'CURSOR_IDLE_MS = 1500' in iv)
    print('  含 cursorPoke 自动隐藏:', 'setTimeout(cursorHide, CURSOR_IDLE_MS)' in iv)
    print('  含 disconnect 清理:', "rfb.addEventListener('disconnect'" in iv)

    # caps.js Home
    cj = z.read('Payload/TrollVNC.app/webclients/caps.js').decode('utf-8', errors='replace')
    print('\ncaps.js 含 Home:', 'Home' in cj)

    # 服务端圆点：trollvncserver 二进制中查找 13 行圆点字符串（'xxxxxxxxxxxxx' 满行唯一标识）
    sv = z.read('Payload/TrollVNC.app/trollvncserver')
    marker = b'xxxxxxxxxxxxx'
    print('\ntrollvncserver 含 13 宽 mask 满行:', marker in sv)
    # 白心标记 'xx         xx'
    white = b'xx         xx'
    print('trollvncserver 含白心行:', white in sv)
