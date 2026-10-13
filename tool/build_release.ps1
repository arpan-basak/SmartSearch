param(
    [ValidateSet('android-arm64', 'android-arm', 'android-x64')]
    [string]$TargetPlatform = 'android-arm64'
)

# Small, release-only APK for one processor family. Keep matching symbols with
# the APK so Flutter crash stacks can still be symbolicated after distribution.
$ErrorActionPreference = 'Stop'
$abi = @{
    'android-arm64' = 'arm64-v8a'
    'android-arm' = 'armeabi-v7a'
    'android-x64' = 'x86_64'
}[$TargetPlatform]
$budget = @{'android-arm64' = 85; 'android-arm' = 70; 'android-x64' = 95}[$TargetPlatform]
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
    & flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Dependency restore failed.' }
    & flutter build apk --release --no-pub --split-per-abi `
        --target-platform $TargetPlatform --split-debug-info "build/symbols/$abi"
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
    & "$PSScriptRoot/measure_apk.ps1" `
        -Apk "build/app/outputs/flutter-apk/app-$abi-release.apk" `
        -MaxMiB $budget -RequireSingleAbi
} finally {
    Pop-Location
}
