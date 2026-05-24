<#
.SYNOPSIS
  同步 Windows 客户端代码到 proxy 仓库并在 proxy 触发 GitHub Actions 打包。

.DESCRIPTION
  proxy (abxian/proxy) 只作为打包镜像，不在上面开发。
  本脚本把当前分支推到 proxy/main，然后在 proxy 仓库触发构建：
    - 默认       : dev.yml 构建 Windows x64，产物在 Actions Artifacts。
    - -Arm64     : 同时构建 Windows ARM64。
    - -Release   : 按 package.json 版本打 tag 推到 proxy 并触发 release.yml 正式发布。
    - -NoBuild   : 只同步代码，不触发构建。
    - -Force     : proxy/main 与本地分叉时强制推送（proxy 是镜像，可安全覆盖）。

.EXAMPLE
  ./package-proxy.ps1                # 同步并出 Windows x64 测试包
  ./package-proxy.ps1 -Arm64         # 额外出 ARM64
  ./package-proxy.ps1 -Release       # 正式发布（需先 bump package.json 版本）
  ./package-proxy.ps1 -NoBuild       # 只同步代码
#>
param(
  [switch]$Release,
  [switch]$Arm64,
  [switch]$Force,
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Require-Command($Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "缺少命令: $Name（请先安装并加入 PATH）"
  }
}
Require-Command git
Require-Command gh

$ProxyRepo   = "abxian/proxy"
$ProxyRemote = "proxy"

# 确保 proxy 远程存在
if ((git remote) -notcontains $ProxyRemote) {
  Write-Host "添加 proxy 远程 -> https://github.com/$ProxyRepo.git"
  git remote add $ProxyRemote "https://github.com/$ProxyRepo.git"
}

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
Write-Host "当前分支: $branch  ->  $ProxyRemote/main"

# 1. 同步代码到 proxy/main
Write-Host "==> 同步代码到 $ProxyRemote/main ..."
$pushArgs = @($ProxyRemote, "HEAD:main")
if ($Force) { $pushArgs += "--force" }
git push @pushArgs
if ($LASTEXITCODE -ne 0) {
  throw "推送到 proxy 失败。若因历史分叉（proxy 是纯镜像可覆盖），用 -Force 重试。"
}

if ($NoBuild) {
  Write-Host "已同步代码，按 -NoBuild 未触发构建。"
  return
}

# 2. 触发构建
if ($Release) {
  $version = (Get-Content package.json -Raw | ConvertFrom-Json).version
  $tag = "v$version"
  Write-Host "==> 正式发布: tag=$tag (来自 package.json)"
  if (-not (git tag --list $tag)) { git tag $tag }
  git push $ProxyRemote $tag --force
  gh workflow run release.yml --repo $ProxyRepo --ref $tag
  Write-Host "已触发 release.yml @ $tag"
}
else {
  $winArm = if ($Arm64) { "true" } else { "false" }
  Write-Host "==> dev.yml 构建 Windows (x64$(if ($Arm64) { ' + arm64' }))"
  gh workflow run dev.yml --repo $ProxyRepo --ref main `
    -f run_windows=true `
    -f run_windows_arm64=$winArm `
    -f run_macos_aarch64=false `
    -f run_linux_amd64=false
  Write-Host "已触发 dev.yml (run_windows=true, arm64=$winArm)"
}

$actionsUrl = "https://github.com/$ProxyRepo/actions"
Write-Host ""
Write-Host "查看构建进度: $actionsUrl"
try { Start-Process $actionsUrl } catch {}
