<#
.SYNOPSIS
    Dataverse Selective Component Downloader CLI Tool for Developers and AI Copilots.
.DESCRIPTION
    Dynamically isolates and fetches specific Dynamics 365 components into the local project workspace.
.PARAMETER ComponentType
    The Dataverse schema component code identifier (e.g., Form=60, View=64, Sitemap=62, WebResource=61).
.PARAMETER ComponentId
    The structural string GUID assigned to the specific targeted cloud asset.
.EXAMPLE
    .\Fetch-Component.ps1 -ComponentType 60 -ComponentId "4ba68e21-bc30-4e31-897b-99933ef788a1"
#>
param (
    [Parameter(Mandatory = $true, HelpMessage = "Enter Type Code (60=Form, 64=View, 62=Sitemap, 61=WebResource)")]
    [ValidateSet("60", "64", "62", "61", "29", "91")]
    [string]$ComponentType,

    [Parameter(Mandatory = $true, HelpMessage = "Enter the 364-bit unique string component GUID")]
    [ValidateScript({$_ -match "^\{?[a-fA-E0-9]{8}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{12}\}?$"})]
    [string]$ComponentId
)

$ErrorActionPreference = "Stop"

# Define static local execution context boundaries
$tempSolutionName = "CopilotFetchPatch_WorkspaceTemp"
$workspaceSrcDir  = Join-Path $PSScriptRoot "src"
$tempZipFile      = Join-Path $PSScriptRoot "$tempSolutionName.zip"
$tempInitFolder   = Join-Path $PSScriptRoot "_temp_init"

Write-Host "🤖 Starting Selective Downloader Tool..." -ForegroundColor Cyan

# Step 1: Pre-flight Verification Check
Write-Host "🔍 Verifying Power Platform CLI environment context..." -ForegroundColor Gray
$authStatus = pac auth list | Out-String
if ($authStatus -match "No auth profiles found") {
    Write-Error "❌ Active PAC authentication profile missing. Run 'pac auth create --url [YourEnvURL]' before continuing."
    exit 1
}

# Step 2: Clean up legacy local structural artifacts
if (Test-Path $tempZipFile) { Remove-Item $tempZipFile -Force }
if (Test-Path $tempInitFolder) { Remove-Item $tempInitFolder -Recurse -Force }

try {
    # Step 3: Server-side clean patch initialization
    Write-Host "🧹 Purging any conflicting temp solutions on the server..." -ForegroundColor Gray
    pac solution delete --name $tempSolutionName --error-on-not-found $false | Out-Null

    Write-Host "🛠️ Provisioning isolated temporary tracking environment container..." -ForegroundColor Gray
    pac solution init --publisher-name "CopilotCLI" --publisher-prefix "cp" --outputDirectory $tempInitFolder | Out-Null

    # Step 4: Inject Targeted Asset Row Link via PAC CLI
    Write-Host "📌 Requesting cloud mapping context layer linking (Type: $ComponentType, ID: $ComponentId)..." -ForegroundColor Yellow
    # Maps component row context directly inside target unmanaged solution
    pac solution add-solution-component `
        --solution-name $tempSolutionName `
        --component-id $ComponentId `
        --component-type $ComponentType | Out-Null

    # Step 5: Export Small Isolated Fragment
    Write-Host "📥 Compiling and downloading targeted manifest segment package..." -ForegroundColor Gray
    pac solution export --name $tempSolutionName --zipfile $tempZipFile --include customization --packagetype Unmanaged | Out-Null

    # Step 6: Unpack payload safely over current local source directory files
    Write-Host "📦 Extracting files into local workspace folder structure..." -ForegroundColor Cyan
    pac solution unpack --zipfile $tempZipFile --folder $workspaceSrcDir --packagetype Unmanaged | Out-Null

    Write-Host "✨ Core synchronization phase completed successfully." -ForegroundColor Green

} catch {
    Write-Host "❌ Fatal error experienced during background syncing operations: $_" -ForegroundColor Red
    exit 1
} finally {
    # Step 7: Absolute post-execution scratch cleaning phase 
    Write-Host "🧼 Running post-flight context cleaning routines..." -ForegroundColor Gray
    pac solution delete --name $tempSolutionName --error-on-not-found $false | Out-Null
    if (Test-Path $tempZipFile) { Remove-Item $tempZipFile -Force }
    if (Test-Path $tempInitFolder) { Remove-Item $tempInitFolder -Recurse -Force }
}

Write-Host "`n🚀 Success! Target component pulled directly into matching tracking path layout under /src/ folder." -ForegroundColor Green
