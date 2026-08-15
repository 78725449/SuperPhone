# -*- coding: utf-8 -*-
# 验证 .tipa 结构：zip 条目、Info.plist、3 个 Mach-O 二进制（arm64 + 签名）、webclients 新版内容
import zipfile, plistlib, struct, sys, io

TIP = r'C:\Users\Administrator\Documents\ChatGPT\New project\ipa-tmp\TrollVNC_0.0.1.tipa'

def check_macho(data, name):
    """按偏移解析 Mach-O：magic、cputype、LC_CODE_SIGNATURE"""
    if len(data) < 4:
        return f'{name}: 文件过小'
    magic = struct.unpack_from('<I', data, 0)[0]
    ok_magic = magic in (0xfeedface, 0xfeedfacf)
    if not ok_magic:
        return f'{name}: magic=0x{magic:08x} 非 Mach-O!'
    is64 = magic == 0xfeedfacf
    off = 4
    cputype = struct.unpack_from('<I', data, off)[0]; off += 4
    cpusub = struct.unpack_from('<I', data, off)[0]; off += 4
    if is64:
        off += 4  # filetype 前的 4 字节跳过 (filetype+flags 各 4，ncmds 在 +8)
    filetype = struct.unpack_from('<I', data, off - 4)[0]
    ncmds_off = off if is64 else 12  # 32 位 ncmds 在偏移 16，64 位在 20
    if is64:
        ncmds = struct.unpack_from('<I', data, 16)[0]
        hdr_end = 32
    else:
        ncmds = struct.unpack_from('<I', data, 12)[0]
        hdr_end = 28
    codesign = 0
    pos = hdr_end
    for _ in range(ncmds):
        if pos + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from('<II', data, pos)
        if cmd == 0x1d:  # LC_CODE_SIGNATURE
            codesign += 1
        pos += cmdsize
    arch = 'arm64' if cputype == 0x0100000c else (f'x86_64' if cputype == 0x01000007 else f'cputype=0x{cputype:x}')
    return f'{name}: magic=0x{magic:08x} {arch} ncmds={ncmds} LC_CODE_SIGNATURE={codesign} {"SIGNED" if codesign else "未签名!"}'

with zipfile.ZipFile(TIP) as z:
    names = z.namelist()
    print(f'=== 条目数: {len(names)} ===')
    for n in names:
        info = z.getinfo(n)
        print(f'  {info.file_size:>10}  {n}')

    # Info.plist 解析
    plist_name = next((n for n in names if n.endswith('Info.plist')), None)
    if plist_name:
        plist = plistlib.loads(z.read(plist_name))
        for k in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleExecutable', 'MinimumOSVersion'):
            print(f'Info.plist {k} = {plist.get(k)}')
    print()

    # 验证核心二进制
    bin_names = [n for n in names if any(n.endswith(x) for x in ('/TrollVNC', '/trollvncserver', '/trollvncmanager'))]
    for bn in bin_names:
        print(check_macho(z.read(bn), bn))
    print()

    # webclients 新版内容抽查
    for probe in ('index.vnc', 'caps.js'):
        matches = [n for n in names if n.endswith('/webclients/' + probe)]
        for m in matches:
            content = z.read(m).decode('utf-8', errors='replace')
            flags = []
            if 'Home' in content: flags.append('Home')
            if 'setupRfbServerSideCursor' not in content: pass
            if probe == 'index.vnc':
                flags.append('白色面板' if '#f5f6f8' in content or '#fff' in content else '非白面板?')
                flags.append('kbdHidden' if 'kbdHidden' in content else '无kbdHidden')
            print(f'webclients/{probe}: {len(content)}B 含: {" ".join(flags)}')

    # 检查 webclients 是否为旧版特征（panel-close）
    for n in names:
        if n.endswith('/webclients/index.vnc'):
            c = z.read(n).decode('utf-8', errors='replace')
            print(f'index.vnc 旧版特征(panel-close): {c.count("panel-close")} 处 | Home+Power截屏旧文案: {"Home+Power截屏" in c} | 新版截屏文案: {"截屏" in c}')
            print(f'  包含 computePanelPos 水平展开: {"computePanelPos" in c} | attachKeyPress 无自动收起: {"scheduleClose" in c}')
