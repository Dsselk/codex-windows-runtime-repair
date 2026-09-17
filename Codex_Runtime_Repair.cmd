@echo off
setlocal
title Codex Runtime Repair
set "SELF=%~f0"

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
  exit /b
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$lines = Get-Content -LiteralPath $env:SELF -Encoding UTF8; $marker = [Array]::IndexOf($lines, '#__POWERSHELL__'); if ($marker -lt 0) { throw 'PowerShell payload marker not found.' }; $code = $lines[($marker + 1)..($lines.Count - 1)] -join [Environment]::NewLine; & ([ScriptBlock]::Create($code))"
set "RC=%errorlevel%"

echo.
echo ------------------------------------------------------------
echo Script finished. Press any key to close this window.
pause >nul
exit /b %RC%

#__POWERSHELL__
$ErrorActionPreference = "Stop"

$pkg = Get-AppxPackage OpenAI.Codex | Select-Object -First 1
if (-not $pkg) {
    throw "未找到 OpenAI.Codex 安装包。"
}

$src = Join-Path $pkg.InstallLocation "app\resources\cua_node"
$rt  = "$env:LOCALAPPDATA\OpenAI\Codex\runtimes\cua_node"

# 优先从最新 staging 获取 hash；没有 staging 就从最新 manual 获取
$stage = Get-ChildItem $rt -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object Name -Like ".staging-*" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($stage -and $stage.Name -match '^\.staging-([0-9a-fA-F]+)-') {
    $hash = $Matches[1]
}
else {
    $manualFound = Get-ChildItem $rt -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object Name -Like ".manual-*" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($manualFound -and $manualFound.Name -match '^\.manual-([0-9a-fA-F]+)$') {
        $hash = $Matches[1]
    }
    else {
        throw "找不到 staging/manual，先停止，不修改任何东西。"
    }
}

# 已确认存在 staging/manual 后才关闭 Codex，避免无故中断正常运行中的应用
Get-Process ChatGPT,Codex -ErrorAction SilentlyContinue | Stop-Process -Force

$manual = Join-Path $rt ".manual-$hash"
$final  = Join-Path $rt $hash

Write-Host "Version:" $pkg.Version
Write-Host "Hash:" $hash

# 找两个空闲盘符
$used = @(Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name)

$free = @(
    "ZYXWVUTSRQPONMLKJIHGFED".ToCharArray() |
    ForEach-Object { [string]$_ } |
    Where-Object { $used -notcontains $_ }
)

if ($free.Count -lt 2) {
    throw "没有两个可用的临时盘符。"
}

$S = $free[0]
$T = $free[1]

function Remove-Maps {
    # 仅用于异常路径兜底；同时吞掉已解除映射时 subst 的无效参数提示
    & subst "$S`:" /D 2>$null | Out-Null
    & subst "$T`:" /D 2>$null | Out-Null
}

function Get-Map($root) {
    $m = @{}
    $prefix = $root.TrimEnd('\') + '\'

    Get-ChildItem $root -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($prefix.Length)
        $m[$rel] = [Int64]$_.Length
    }

    return $m
}

try {
    # 源目录映射成短路径
    & subst "$S`:" "$src"

    $srcMap = Get-Map "$S`:\"

    # ---------- 先验证现有正式 runtime ----------
    if (Test-Path $final) {
        & subst "$T`:" "$final"

        $finalMap = Get-Map "$T`:\"

        $bad = @()

        foreach ($rel in $srcMap.Keys) {
            if (-not $finalMap.ContainsKey($rel)) {
                $bad += "MISSING: $rel"
            }
            elseif ($finalMap[$rel] -ne $srcMap[$rel]) {
                $bad += "SIZE: $rel"
            }
        }

        foreach ($rel in $finalMap.Keys) {
            if (-not $srcMap.ContainsKey($rel)) {
                $bad += "EXTRA: $rel"
            }
        }

        & subst "$T`:" /D 2>$null

        if ($bad.Count -eq 0) {
            Write-Host ""
            Write-Host "正式 runtime 已完整，不覆盖。" -ForegroundColor Green

            # 只清同 hash 的失败临时目录
            Get-ChildItem $rt -Directory -Force |
                Where-Object {
                    $_.Name -like ".staging-$hash-*"
                } |
                Remove-Item -Recurse -Force

            # manual 若存在，也只有在正式 runtime 已验证完整时才删
            if (Test-Path $manual) {
                Remove-Item $manual -Recurse -Force
            }

            & subst "$S`:" /D 2>$null | Out-Null

            Write-Host "RUNTIME_OK" -ForegroundColor Green
            return
        }

        Write-Host "现有正式 runtime 不完整，发现 $($bad.Count) 个差异。" -ForegroundColor Yellow
        $bad | Select-Object -First 10

        # 不直接删，改名留备份
        $backupName = "$hash.bad-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Rename-Item -LiteralPath $final -NewName $backupName -ErrorAction Stop
    }

    # ---------- 重建 manual ----------
    if (Test-Path $manual) {
        Remove-Item $manual -Recurse -Force
    }

    New-Item -ItemType Directory -Path $manual -Force | Out-Null

    & subst "$T`:" "$manual"

    Write-Host ""
    Write-Host "Copying..."

    & xcopy.exe "$S`:\*" "$T`:\" /E /H /I /Y /G /Q

    Write-Host "Verifying..."

    $dstMap = Get-Map "$T`:\"

    $bad = @()

    foreach ($rel in $srcMap.Keys) {
        if (-not $dstMap.ContainsKey($rel)) {
            $bad += "MISSING: $rel"
        }
        elseif ($dstMap[$rel] -ne $srcMap[$rel]) {
            $bad += "SIZE: $rel"
        }
    }

    foreach ($rel in $dstMap.Keys) {
        if (-not $srcMap.ContainsKey($rel)) {
            $bad += "EXTRA: $rel"
        }
    }

    Write-Host "Source files:" $srcMap.Count
    Write-Host "Target files:" $dstMap.Count

    if ($bad.Count -ne 0) {
        $bad | Select-Object -First 20
        throw "复制后校验失败，共 $($bad.Count) 个差异。"
    }

    # 必须先解除目标映射，才能重命名目录
    & subst "$T`:" /D 2>$null

    # 这里如果失败，会直接停止，绝不会再打印成功
    Rename-Item -LiteralPath $manual -NewName $hash -ErrorAction Stop

    # 最终关键文件再检查
    if (-not (Test-Path (Join-Path $final "bin\node.exe"))) {
        throw "最终 node.exe 不存在。"
    }

    if (-not (Test-Path (Join-Path $final "bin\node_repl.exe"))) {
        throw "最终 node_repl.exe 不存在。"
    }

    # 成功后才清当前 hash 的 staging
    Get-ChildItem $rt -Directory -Force |
        Where-Object {
            $_.Name -like ".staging-$hash-*"
        } |
        Remove-Item -Recurse -Force

    & subst "$S`:" /D 2>$null | Out-Null

    Write-Host ""
    Write-Host "成功" -ForegroundColor Green
}
catch {
    Remove-Maps

    Write-Host ""
    Write-Host "FAILED" -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}
