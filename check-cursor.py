# -*- coding: utf-8 -*-
# 验证 trollvncserver.mm 中 setupXCursor 的 13x13 字符串数据
import re

src = open(r'c:\Users\Administrator\Documents\ChatGPT\New project\TrollVNC\src\trollvncserver.mm', encoding='utf-8').read()
m = re.search(r'NS_INLINE void setupXCursor.*?rfbMakeXCursor\(width, height', src, re.S)
block = m.group(0)
rows = re.findall(r'"([ x]*)"', block)
print('总行数:', len(rows))
print('行宽集合:', sorted(set(len(r) for r in rows)))
mask = rows[:13]
cur = rows[13:26]
print('mask 行宽全部 13:', all(len(r) == 13 for r in mask))
print('cursor 行宽全部 13:', all(len(r) == 13 for r in cur))
print('黑像素(cursor x):', sum(r.count('x') for r in cur))
print('白像素(cursor 空格):', sum(r.count(' ') for r in cur))
print('mask 不透明像素:', sum(r.count('x') for r in mask))
# 语义自检: mask 之外 cursor 必须为空格(透明)
ok = True
for my, cy in zip(mask, cur):
    for a, b in zip(my, cy):
        if a == ' ' and b == 'x':
            ok = False
            print('ERROR: mask 透明处 cursor 有 x')
print('透明一致性:', ok)
# 视觉预览
for my, cy in zip(mask, cur):
    print(''.join('#' if a == 'x' and b == 'x' else ('o' if a == 'x' else '.') for a, b in zip(my, cy)))
