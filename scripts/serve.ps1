# 测试用静态文件服务器：scripts/serve.ps1 -Port 18765 -Root <目录>
# 供更新器 E2E 使用（HttpListener，仅绑定 127.0.0.1）
param(
    [int]$Port = 18765,
    [string]$Root = "dist/upd"
)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "serving $Root on http://127.0.0.1:$Port/"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $rel = $ctx.Request.Url.AbsolutePath.TrimStart('/')
        $path = Join-Path $Root $rel
        if (Test-Path $path -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = "application/octet-stream"
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            Write-Host "200 $rel ($($bytes.Length) bytes)"
        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.OutputStream.Close()
            Write-Host "404 $rel"
        }
    }
} finally {
    $listener.Stop()
}
