<#
.SYNOPSIS
    Gzip-compresses and base64-encodes a file, and prints both the "files:"
    and "templates:" entries ready to paste into synthetic-data.yml.

.PARAMETER Path
    Local file to encode.

.PARAMETER VirtualPath
    Virtual path to project inside the honeypot (e.g. "Documents/logo.png").
    Defaults to just the file name (placed at the virtual root).

.PARAMETER Timestamp
    Unix timestamp for the files: entry. Defaults to the file's last-write
    time.

.PARAMETER NoGzip
    Skip gzip compression - produces "type: base64" instead of
    "type: base64gzip". Fine for small files.

.EXAMPLE
    .\Encode-SyntheticFile.ps1 -Path C:\Temp\honeybadger.png -VirtualPath "Documents/honeybadger.png"

.EXAMPLE
    .\Encode-SyntheticFile.ps1 -Path C:\Temp\logo.png -NoGzip
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [string]$VirtualPath,

    [long]$Timestamp,

    [switch]$NoGzip
)

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$fileInfo = Get-Item $Path
$rawBytes = [System.IO.File]::ReadAllBytes($Path)

if (-not $VirtualPath) {
    $VirtualPath = $fileInfo.Name
}
$VirtualPath = $VirtualPath -replace '\\', '/'
$templateName = Split-Path $VirtualPath -Leaf

if (-not $Timestamp) {
    $Timestamp = [long]([DateTimeOffset]$fileInfo.LastWriteTimeUtc).ToUnixTimeSeconds()
}

if ($NoGzip) {
    $outputBytes = $rawBytes
    $templateType = "base64"
} else {
    $memoryStream = New-Object System.IO.MemoryStream
    $gzipStream = New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode]::Compress)
    $gzipStream.Write($rawBytes, 0, $rawBytes.Length)
    $gzipStream.Close()
    $outputBytes = $memoryStream.ToArray()
    $templateType = "base64gzip"
}

$base64 = [System.Convert]::ToBase64String($outputBytes)

# Wrap to 76 chars per line, indented 6 spaces to sit under "content: |"
$wrapped = ($base64 -split '(?<=\G.{76})' | ForEach-Object { "      $_" }) -join "`n"

Write-Host ""
Write-Host "File           : $Path"
Write-Host "Virtual path   : $VirtualPath"
Write-Host "Original size  : $($rawBytes.Length) bytes"
if (-not $NoGzip) {
    Write-Host "Gzip size      : $($outputBytes.Length) bytes"
}
Write-Host "Template type  : $templateType"
Write-Host ""
Write-Host "Paste into synthetic-data.yml:"
Write-Host "---------------------------------------------------"
Write-Host "  - path: $VirtualPath"
Write-Host "    directory: false"
Write-Host "    size: $($rawBytes.Length)"
Write-Host "    timestamp: $Timestamp"
Write-Host ""
Write-Host "templates:"
Write-Host "  # -- $templateName --"
Write-Host "  - name: $templateName"
Write-Host "    type: $templateType"
Write-Host "    content: |"
Write-Host $wrapped
Write-Host "---------------------------------------------------"
