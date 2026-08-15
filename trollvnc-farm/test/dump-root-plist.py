# 解析 Root.plist 输出分组结构（临时诊断脚本）
import plistlib

p = plistlib.load(open(r'TrollVNC\prefs\TrollVNCPrefs\Resources\Root.plist', 'rb'))
for item in p['items']:
    c = item.get('cell', '')
    if c == 'PSGroupCell':
        print('== [%s] footer=%s' % (item.get('label', ''), item.get('footerText', '')))
    else:
        print('   %-26s key=%-24s label=%s default=%s action=%s' % (
            c, item.get('key', '-'), item.get('label', ''),
            item.get('default', ''), item.get('action', '')))
