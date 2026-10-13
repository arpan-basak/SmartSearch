param(
    [Parameter(Mandatory = $true)]
    [string]$Apk,
    [double]$MaxMiB = 0,
    [switch]$RequireSingleAbi
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$file = Get-Item -LiteralPath $Apk
$archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
try {
    $abis = @($archive.Entries | ForEach-Object {
        if ($_.FullName -match '^lib/([^/]+)/') { $Matches[1] }
    } | Sort-Object -Unique)
    $size = $file.Length / 1MB
    Write-Output ('{0}: {1:N2} MiB; processors: {2}' -f $file.Name, $size, ($abis -join ', '))
    $archive.Entries | Sort-Object CompressedLength -Descending |
        Select-Object -First 12 @{n='Entry';e={$_.FullName}},
            @{n='APK MiB';e={[math]::Round($_.CompressedLength / 1MB, 2)}},
            @{n='Uncompressed MiB';e={[math]::Round($_.Length / 1MB, 2)}} |
        Format-Table -AutoSize | Out-Host
    if ($RequireSingleAbi -and $abis.Count -ne 1) {
        throw 'Expected exactly one processor architecture. Rebuild with --split-per-abi.'
    }
    if ($MaxMiB -gt 0 -and $size -gt $MaxMiB) {
        throw ('APK exceeds its {0:N2} MiB size budget. Inspect the largest entries before distributing.' -f $MaxMiB)
    }
} finally {
    $archive.Dispose()
}
