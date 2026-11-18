# v0.3.11 E2：离线 WebView2 fixed 运行时 E2E（负向：缺失目录不回退 Evergreen）。
# 用法：powershell -File scripts/e2e_fixed_runtime.ps1
# 断言：
#   1) ZILT_WEBVIEW2_BROWSER_DIR 指向缺失目录 → 应用启动失败（非零退出）
#      且 zilt.log 含 WebView2RuntimeNotFound（loader 不回落 Evergreen——
#      findRuntimeWithOptions 的 fixed 分支直接报错）
#   2) 可选正向：ZILT_E2E_FIXED_RT 指向真实 fixed 运行时目录时，
#      以该目录跑冒烟（ZILT_SMOKE_EXIT=1）——需要手动准备 fixed 运行时。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0

# ---- 断言 1：缺失 fixed 目录 → 不回退、启动失败 ----
$env:ZILT_WEBVIEW2_BROWSER_DIR = 'C:\__zilt_e2e_missing_fixed_runtime__'
Remove-Item Env:\ZILT_SMOKE_EXIT -ErrorAction SilentlyContinue
$p = Start-Process -FilePath '.\zig-out\bin\zilt-app.exe' -PassThru -RedirectStandardOutput "$env:TEMP\zilt-e2e-out.txt" -RedirectStandardError "$env:TEMP\zilt-e2e-err.txt"
Start-Sleep -Seconds 6
$exited = $p.HasExited
if ($exited) { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue }
if (-not $exited) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Write-Output '[e2e-fixed] FAIL: app kept running (fallback to Evergreen happened?)'
    $fail = 1
}
# loader 失败以 error 返回（stderr 的 error trace 含 WebView2RuntimeNotFound）
$errOut = Get-Content "$env:TEMP\zilt-e2e-err.txt" -Raw -ErrorAction SilentlyContinue
if ($errOut -notmatch 'WebView2RuntimeNotFound') {
    Write-Output '[e2e-fixed] FAIL: stderr missing WebView2RuntimeNotFound'
    $fail = 1
}
if ($fail -eq 0) { Write-Output '[e2e-fixed] PASS: missing fixed dir -> no Evergreen fallback (startup failed as designed)' }

# ---- 断言 2（可选）：真实 fixed 运行时跑冒烟 ----
if ($env:ZILT_E2E_FIXED_RT) {
    Remove-Item Env:\ZILT_WEBVIEW2_BROWSER_DIR -ErrorAction SilentlyContinue
    $env:ZILT_WEBVIEW2_BROWSER_DIR = $env:ZILT_E2E_FIXED_RT
    $env:ZILT_SMOKE_TEST_MS = '60000'
    $env:ZILT_SMOKE_EXIT = '1'
    & .\zig-out\bin\zilt-app.exe
    if ($LASTEXITCODE -eq 0) { Write-Output '[e2e-fixed] PASS: real fixed runtime smoke exit 0' }
    else { Write-Output '[e2e-fixed] FAIL: real fixed runtime smoke exit non-zero'; $fail = 1 }
}
Remove-Item Env:\ZILT_WEBVIEW2_BROWSER_DIR -ErrorAction SilentlyContinue
exit $fail
