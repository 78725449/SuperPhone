# 本地 GUI 视觉模型服务（GUI-Owl-1.5-4B via llama.cpp）
#
# 用途：给 AI 操作层提供【探索期的眼睛】—— 把截图变成"这一屏有什么、哪里能点"。
#       这是主干《设备操作Agent时序设计》§三 角色分层里「UI 视觉代理（演员）」的本地后端。
#       与云端方案的区别：全部内网、零外部依赖、零 token 成本。
#
# 背景与选型依据（见 AI操作层-真机实测台账-2026-09-18.md）：
#   - 设备端 vision.ocr 只能给"文字 + 坐标"，给不了"哪里能点"（可交互性判断）
#   - find_image（模板匹配）当前 y 准 x 偏，且需要预先有锚点图
#   - → 探索期需要一双"看得懂屏幕"的眼睛，这就是本服务
#
# 模型：mradermacher/GUI-Owl-1.5-4B-Instruct-GGUF
#   主模型    gui-owl-1.5-4b-instruct-q4_k_m.gguf        2381.6 MB
#   多模态    GUI-Owl-1.5-4B-Instruct.mmproj-Q8_0.gguf    432.9 MB（必须有，否则看不了图）
#   GUI-Owl-1.5 基于 Qwen3-VL，本机 llama.cpp（build 10502 / 2026-08-19）已确认支持
#   （llama.dll 与 mtmd.dll 中均有 qwen3vl 架构符号）
#
# 显存：Q4_K_M 2.6GB + mmproj 0.6GB + KV(8K) 约 3.7GB；2080Ti 11GB 上可与 ComfyUI 并存
#
# 注意：本文件必须保存为【带 UTF-8 BOM】，否则本机 PowerShell 5.1 会按 GBK 解析而致中文乱码

$ErrorActionPreference = 'Stop'

$LlamaDir = 'D:\llama.cpp'
$ModelDir = Join-Path $LlamaDir 'models\GUI-Owl-1.5-4B'
$Host_    = '127.0.0.1'
$Port     = 8092          # 不与其他端口冲突：8080 网关 / 18081 注册 / 18181 隧道 / 8081 embedding
$Ctx      = 8192          # 截图占 vision token 较多，8K 起步；显存够可调大

# 自动匹配模型文件：容忍大小写与命名差异（手工下载的文件名可能不同）。
# 主模型 = 目录里最大的、名字不含 mmproj 的 .gguf；多模态投影 = 名字含 mmproj 的 .gguf。
$ggufs  = @(Get-ChildItem $ModelDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue)
$Main   = ($ggufs | Where-Object { $_.Name -notmatch 'mmproj' } | Sort-Object Length -Descending |
           Select-Object -First 1).FullName
$Mmproj = ($ggufs | Where-Object { $_.Name -match 'mmproj' } |
           Select-Object -First 1).FullName

if (-not $Main -or -not $Mmproj) {
    Write-Host "X 模型文件不完整（目录 $ModelDir）"
    Write-Host '  需要两个文件：主模型 .gguf（约 2.4GB）+ 多模态投影 *mmproj*.gguf（约 0.4GB）'
    Get-ChildItem $ModelDir -File -ErrorAction SilentlyContinue | ForEach-Object { "    $($_.Name)" }
    exit 1
}

$log = Join-Path $ModelDir 'llama-server.log'
Write-Host "启动 GUI-Owl 视觉服务 -> http://${Host_}:${Port}"
Write-Host "  主模型 : $Main"
Write-Host "  多模态 : $Mmproj"
Write-Host "  上下文 : $Ctx   GPU 层 : 全部 (-ngl 99)"
Write-Host "  日志   : $log"
Write-Host ''

$llamaArgs = @(
    '-m', $Main,
    '--mmproj', $Mmproj,     # 关键：多模态投影，缺了它模型看不了图
    '-ngl', '99',            # 全部层放 GPU
    '-c', "$Ctx",
    '--host', $Host_,
    '--port', "$Port",
    '--jinja',               # 使用模型自带 chat template（Qwen3-VL 需要）
    '--no-webui'
)

Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$p = Start-Process -FilePath (Join-Path $LlamaDir 'llama-server.exe') `
    -ArgumentList $llamaArgs -WorkingDirectory $LlamaDir -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru

Write-Host "  PID = $($p.Id)"
Write-Host '  等待模型加载（首次加载 4B 模型约 10~40s）...'

for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 3
    try {
        $r = Invoke-RestMethod -Uri "http://${Host_}:${Port}/health" -TimeoutSec 5 -ErrorAction Stop
        if ($r.status -eq 'ok') {
            Write-Host "  +$($i*3)s  就绪 OK"
            Write-Host ''
            Write-Host '服务已就绪'
            Write-Host "  OpenAI 兼容端点: http://${Host_}:${Port}/v1/chat/completions"
            Write-Host '  用法：content 里放 [{"type":"text",...},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,..."}}]'
            exit 0
        }
    } catch {
        if ($i % 5 -eq 0) { Write-Host "  +$($i*3)s  仍在加载..." }
    }
}

Write-Host 'X 探测超时，日志尾部：'
Get-Content $log -Tail 25 | ForEach-Object { "    $_" }
exit 2
