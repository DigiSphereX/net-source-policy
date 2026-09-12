# NetSource Policy - build script
# Converts the source image (build\NetSourcePolicy-preview.png) into a multi-size
# application icon and compiles the zero-console launcher EXE with that icon.

param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$buildDir = Join-Path $Root 'build'
$srcImage = Join-Path $buildDir 'NetSourcePolicy-preview.png'
$iconOut  = Join-Path $buildDir 'NetSourcePolicy.ico'
$exeOut   = Join-Path $Root 'NetSourcePolicy.exe'
$csSource = Join-Path $buildDir 'NetSourcePolicy.cs'

if (-not (Test-Path $srcImage)) { throw "Source image not found: $srcImage" }

function New-ScaledBitmap {
    param($Bitmap, [int]$Size)
    $b = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = 'HighQuality'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
    $g.DrawImage($Bitmap, $rect)
    $g.Dispose()
    return $b
}

function Export-Icon {
    param($Bitmap, [string]$OutPath, [int[]]$Sizes = @(16, 32, 48, 64, 128, 256))
    $pngs = @()
    foreach ($s in $Sizes) {
        $b = New-ScaledBitmap -Bitmap $Bitmap -Size $s
        $ms = New-Object System.IO.MemoryStream
        $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b.Dispose()
        $pngs += , @($s, $ms.ToArray())
        $ms.Dispose()
    }
    $header = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($header)
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$pngs.Count)
    $offset = 6 + 16 * $pngs.Count
    foreach ($p in $pngs) {
        $w.Write([Byte]([int]$p[0] -band 0xFF)); $w.Write([Byte]0)
        $w.Write([Byte]0); $w.Write([Byte]0)
        $w.Write([UInt16]1); $w.Write([UInt16]32)
        $w.Write([UInt32]$p[1].Length); $w.Write([UInt32]$offset)
        $offset += $p[1].Length
    }
    foreach ($p in $pngs) { $w.Write($p[1]) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($OutPath, $header.ToArray())
    $w.Dispose(); $header.Dispose()
}

Write-Host "Source image: $srcImage"
$src = [System.Drawing.Image]::FromFile($srcImage)
Export-Icon -Bitmap $src -OutPath $iconOut
$src.Dispose()
Write-Host "Icon: $iconOut"

$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'C# compiler not found' }

Write-Host 'Compiling launcher...'
& $csc /nologo /target:winexe "/win32icon:$iconOut" "/out:$exeOut" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll "$csSource" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }

Write-Host "EXE: $exeOut"
Write-Host 'Done.'