# -*- coding: utf-8 -*-
# 提取 index.vnc 内嵌 script 并做 node 语法检查
import re, subprocess, sys, tempfile, os

path = r'c:\Users\Administrator\Documents\ChatGPT\New project\TrollVNC\layout\usr\share\trollvnc\webclients\index.vnc'
html = open(path, encoding='utf-8').read()

scripts = re.findall(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>', html, re.S)
print('内联 script 数量:', len(scripts))

ok = True
for i, code in enumerate(scripts):
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
        f.write(code)
        tmp = f.name
    r = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
    os.unlink(tmp)
    if r.returncode != 0:
        ok = False
        print(f'=== script #{i} 语法错误 ===')
        print(r.stderr)
    else:
        print(f'script #{i}: 语法 OK ({len(code)} chars)')

sys.exit(0 if ok else 1)
