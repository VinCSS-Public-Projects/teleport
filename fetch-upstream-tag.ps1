#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Tag,

    [string]$UpstreamUrl = 'https://github.com/gravitational/teleport'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path '.git')) {
    throw "Not a git repository (run this from the repo root)."
}

if (git tag --list $Tag) {
    Write-Host "Tag '$Tag' already exists locally." -ForegroundColor Yellow
    exit 0
}

Write-Host "Fetching tag '$Tag' from $UpstreamUrl..." -ForegroundColor Cyan
git fetch $UpstreamUrl "refs/tags/${Tag}:refs/tags/${Tag}"

if ($LASTEXITCODE -ne 0) {
    throw "git fetch failed with exit code $LASTEXITCODE"
}

Write-Host "Tag '$Tag' fetched successfully." -ForegroundColor Green
git show $Tag --stat --no-patch
