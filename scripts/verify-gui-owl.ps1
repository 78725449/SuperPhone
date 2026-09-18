# GUI-Owl 本地视觉服务：一键验证
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File D:\编程项目\SuperPhone\scripts\verify-gui-owl.ps1
#
# 做三件事：
#   1. 确认模型文件齐备（只查存在与大小级别，不做整文件读取——主模型 2.4GB 超过
#      .NET Framework 的 ReadAllBytes 2GB 上限，曾经在这里踩过坑）
#   2. 起 llama-server（含 --mmproj 多模态投影）并等健康检查就绪
#   3. 拿一张真机截图喂给它，验证它【真的看得懂屏幕】—— 这是本轮最关键的验证
#
# 注意：本文件必须保存为【带 UTF-8 BOM】，否则本机 PowerShell 5.1 会按 GBK 解析而致中文乱码

$ErrorActionPreference = 'Stop'
$LlamaDir = 'D:\llama.cpp'
$ModelDir = Join-Path $LlamaDir 'models\GUI-Owl-1.5-4B'
$Port     = 8092
$Dev      = '553A6EA8-29F1-43DB-94B4-D4E01D4204DC'
$Gateway  = 'http://127.0.0.1:8080'

# 自动匹配模型文件：容忍大小写与命名差异（手工下载的文件名可能不同）
$ggufs  = @(Get-ChildItem $ModelDir -Filter '*.gguf' -File -ErrorAction SilentlyContinue)
$Main   = ($ggufs | Where-Object { $_.Name -notmatch 'mmproj' } | Sort-Object Length -Descending |
           Select-Object -First 1)
$Mmproj = ($ggufs | Where-Object { $_.Name -match 'mmproj' } | Select-Object -First 1)

Write-Host '=== 1. 模型文件 ===' -ForegroundColor Cyan
if (-not $Main -or -not $Mmproj) {
    Write-Host "  X 文件不齐（目录 $ModelDir）"
    $ggufs | ForEach-Object { "    $($_.Name)" }
    exit 1
}
Write-Host ("  OK 主模型: {0}  {1:N1} MB" -f $Main.Name, ($Main.Length / 1MB)) -ForegroundColor Green
Write-Host ("  OK 多模态: {0}  {1:N1} MB" -f $Mmproj.Name, ($Mmproj.Length / 1MB)) -ForegroundColor Green

Write-Host "`n=== 2. 启动 llama-server（端口 $Port）===" -ForegroundColor Cyan
$log = Join-Path $ModelDir 'llama-server.log'
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$p = Start-Process -FilePath (Join-Path $LlamaDir 'llama-server.exe') -ArgumentList @(
    '-m', $Main.FullName, '--mmproj', $Mmproj.FullName, '-ngl', '99', '-c', '8192',
    '--host', '127.0.0.1', '--port', "$Port", '--jinja', '--no-webui'
) -WorkingDirectory $LlamaDir -WindowStyle Hidden `
  -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru
Write-Host "  PID = $($p.Id)   日志 = $log"

$ready = $false
for ($i = 1; $i -le 40; $i++) {
    Start-Sleep -Seconds 3
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5 -ErrorAction Stop
        if ($r.status -eq 'ok') { Write-Host "  +$($i*3)s  就绪 OK" -ForegroundColor Green; $ready = $true; break }
    } catch {
        if ($i % 5 -eq 0) { Write-Host "  +$($i*3)s  加载中..." }
    }
}
if (-not $ready) {
    Write-Host '  X 未就绪，日志尾部：' -ForegroundColor Red
    Get-Content $log -Tail 30 | ForEach-Object { "    $_" }
    exit 2
}

Write-Host "`n=== 3. 真机截图 -> 喂给模型，验证它看得懂屏幕 ===" -ForegroundColor Cyan
Write-Host '  取原尺寸截图...'
$shot = Invoke-RestMethod -Uri "$Gateway/api/devices/$Dev/invoke" -Method Post `
    -Body (@{cap = 'screenshot'; params = @{}} | ConvertTo-Json -Depth 4) `
    -ContentType 'application/json' -TimeoutSec 60
$b64 = $shot.ack.image
if (-not $b64) {
    Write-Host "  X 截图失败: $($shot | ConvertTo-Json -Compress)" -ForegroundColor Red
    exit 3
}
Write-Host "  截图 $($shot.ack.width)x$($shot.ack.height)，base64 $($b64.Length) 字符"

$prompt = '你是手机屏幕分析助手。看这张截图，只输出一个 JSON（不要解释、不要 markdown 代码块）：' +
    '{"page":"页面名称","elements":[{"label":"元素上可见的文字，或对图标的简短中文描述","kind":"clickable","cx":0.5,"cy":0.3}]}' +
    '要求：' +
    '- cx/cy 是【归一化 0 到 1】，左上角为原点，取该元素的【中心】' +
    '- 只列【可以点击或输入】的元素，按从上到下排序，最多 20 个' +
    '- label 优先用截图里真实出现的文字；纯图标用一句中文说明它是什么'

$body = @{
    model       = 'gui-owl'
    messages    = @(@{
            role    = 'user'
            content = @(
                @{ type = 'text'; text = $prompt },
                @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } }
            )
        })
    max_tokens  = 1024
    temperature = 0.1
    stream      = $false
} | ConvertTo-Json -Depth 10 -Compress

Write-Host '  请求模型（首次推理含 vision 编码，可能 10~90s）...'
$t0 = Get-Date
try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
        -Body $body -ContentType 'application/json' -TimeoutSec 300
} catch {
    Write-Host "  X 请求失败: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  日志尾部：'; Get-Content $log -Tail 20 | ForEach-Object { "    $_" }
    exit 4
}
$el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$content = $resp.choices[0].message.content
Write-Host "  模型耗时 ${el}s，输出 $($content.Length) 字符" -ForegroundColor Green
Write-Host ''
Write-Host '  ── 模型原始输出 ──' -ForegroundColor Yellow
Write-Host $content
Write-Host '  ── 完 ──' -ForegroundColor Yellow

$m = [regex]::Match($content, '\{[\s\S]*\}')
if ($m.Success) {
    try {
        $o = $m.Value | ConvertFrom-Json
        Write-Host ''
        Write-Host "  解析成功：页面『$($o.page)』，元素 $($o.elements.Count) 个" -ForegroundColor Green
        $i = 0
        foreach ($e in $o.elements) {
            $i++
            Write-Host ("    {0,2}. {1,-24} {2}  tap({3:N3}, {4:N3})" -f $i, $e.label, $e.kind, $e.cx, $e.cy)
        }
        Write-Host ''
        Write-Host '  这些坐标可直接喂给 superphone_tap' -ForegroundColor Green
    } catch {
        Write-Host "  输出不是合法 JSON（$($_.Exception.Message)）—— 模型能力或 prompt 需调整" -ForegroundColor Yellow
    }
} else {
    Write-Host '  输出里没有 JSON —— 模型能力或 prompt 需调整' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "服务已在 http://127.0.0.1:$Port 运行（OpenAI 兼容 /v1/chat/completions）" -ForegroundColor Cyan
