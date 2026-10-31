$ErrorActionPreference = 'Stop'
$seekRoot = Split-Path $PSScriptRoot -Parent
$seekCache = Join-Path $seekRoot 'artifacts/toolchain-downloads'
New-Item -ItemType Directory -Path $seekCache -Force | Out-Null
$seekDownloads = @(
    @{
        Name = 'OpenAppleMacrosServer-x86_64-1.4.1.tar.gz'
        Url = 'https://github.com/xtool-org/OpenAppleMacros/releases/download/v1.4.1/OpenAppleMacrosServer-x86_64.tar.gz'
        Hash = '2d80c922d0873dd8b0a85e19d10bd7f42a1aea3db3a85f7b6edf56fe9b687a21'
    },
    @{
        Name = 'toolset-x86_64-1.1.0.tar.gz'
        Url = 'https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.1.0/toolset-x86_64.tar.gz'
        Hash = 'a5166f2d56ac45707e5ef2f3c20a41a94af8ef0c0456354224dd08656e874188'
    }
)
foreach ($seekDownload in $seekDownloads) {
    $seekFile = Join-Path $seekCache $seekDownload.Name
    if (-not (Test-Path -LiteralPath $seekFile)) {
        & curl.exe --fail --location --retry 3 --connect-timeout 20 --speed-limit 1024 --speed-time 30 --continue-at - --output ($seekFile + '.download') $seekDownload.Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $($seekDownload.Name)" }
        Move-Item -LiteralPath ($seekFile + '.download') -Destination $seekFile
    }
    if ((Get-FileHash -LiteralPath $seekFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $seekDownload.Hash) {
        throw "Checksum mismatch: $seekFile"
    }
    Write-Output "Verified $($seekDownload.Name)"
}
