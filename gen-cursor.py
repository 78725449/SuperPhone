# -*- coding: utf-8 -*-
# 生成苹果风格圆点光标（白填充+黑描边）的 X11 光标字符串
import math

size = 13  # 13x13: 白心直径9 + 1px 黑描边 + 透明外圈
c = (size - 1) / 2.0
mask = []
cur = []
for y in range(size):
    m = ''
    u = ''
    for x in range(size):
        d2 = (x - c) ** 2 + (y - c) ** 2
        if d2 <= 6.5 ** 2:      # mask: 半径 6.5 的圆
            m += 'x'
            if d2 <= 4.5 ** 2:  # 白填充: 半径 4.5
                u += ' '
            else:
                u += 'x'        # 黑描边
        else:
            m += ' '
            u += ' '
    mask.append(m)
    cur.append(u)

print('mask:')
for row in mask:
    print('    "{}"'.format(row))
print('cursor:')
for row in cur:
    print('    "{}"'.format(row))

# 自检：每行长度
assert all(len(r) == size for r in mask + cur), '行宽不一致'
# 自检：白区/黑区/透明区统计
white = sum(r.count(' ') for r in cur)
black = sum(r.count('x') for r in cur)
print('white={} black={}'.format(white, black))
