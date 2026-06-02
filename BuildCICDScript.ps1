# =================================================================================
# DYNAMICS 365 AUTOMATED SEGMENTED SOLUTION BUILDER (LOCAL & CI/CD PIPELINE)
# =================================================================================
param (
    [string]$TargetBranch = "origin/main"
)

$sourceDir   = Join-Path $PSScriptRoot "src"
$otherDir    = Join-Path $PSScriptRoot "Other"
$buildDir    = Join-Path $PSScriptRoot "_segmented_build"
$outputZip   = Join-Path $PSScriptRoot "SegmentedSolutionFix.zip"

# Clean up any previous segmented build folders
if (Test-Path $buildDir) { Remove-Item -Path $buildDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $buildDir "src") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $buildDir "Other") | Out-Null

Write-Host "🔍 Step 1: Identifying modified files..." -ForegroundColor Cyan

$changedFiles = @()

# Detect if running in a CI/CD Pipeline (Azure Pipelines or GitHub Actions)
if ($env:TF_BUILD -eq "True" -or $env:GITHUB_ACTIONS -eq "true") {
    Write-Host "-> Pipeline detected. Running Git Diff against branch: $TargetBranch" -ForegroundColor Yellow
    # Fetch paths of files that differ between the current branch and the target branch
    $changedFiles = git diff --name-only $TargetBranch | ForEach-Object {
        $path = $_.Trim()
        if ($path.StartsWith("src/") -or $path.StartsWith("Other/")) { $path }
    }
} else {
    Write-Host "-> Local environment detected. Running Git Status for uncommitted changes..." -ForegroundColor Yellow
    # Fetch paths of files that are locally modified, staged, or untracked
    $changedFiles = git status --porcelain | ForEach-Object {
        $path = $_.Substring(3).Trim()
        if ($path.StartsWith("src/") -or $path.StartsWith("Other/")) { $path }
    }
}

if ($null -eq $changedFiles -or $changedFiles.Count -eq 0) {
    Write-Host "⚠️ No changed files detected in 'src/' or 'Other/'. Nothing to build." -ForegroundColor Yellow
    exit 0
}

# Mapping table to match folder patterns to Dataverse Solution Component Type IDs
$componentMappings = @(
    @{ Pattern = "Entities\\.*?\\FormXml\\.*?\\.*\.xml$"; Type = "60" },      # System Form
    @{ Pattern = "Entities\\.*?\\SavedQueries\\.*?\.xml$"; Type = "64" },     # Saved Query (View)
    @{ Pattern = "Entities\\.*?\\RibbonDiff\\.xml$"; Type = "29" },           # Ribbon Customization
    @{ Pattern = "SiteMaps\\.*?\.xml$"; Type = "62" },                        # Site Map
    @{ Pattern = "WebResources\\.*?\.xml$"; Type = "61" },                    # Web Resource
    @{ Pattern = "PluginAssemblies\\.*?\.xml$"; Type = "91" },                # Plugin Assembly
    @{ Pattern = "Workflows\\.*?\.xml$"; Type = "29" }                        # Workflow / Cloud Flow
)

$detectedComponents = @()

Write-Host "📂 Step 2: Isolating changed files and staging folder structure..." -ForegroundColor Cyan
foreach ($relPath in $changedFiles) {
    # Skip Solution.xml itself as we reconstruct it dynamically
    if ($relPath -like "*Solution.xml") { continue }

    $srcFileFull = Join-Path $PSScriptRoot $relPath
    $destFileFull = Join-Path $buildDir $relPath
    $destFolder = Split-Path $destFileFull

    # Ensure targeted subfolder structure exists inside the staging directory
    if (!(Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
    
    if (Test-Path $srcFileFull) {
        Copy-Item -Path $srcFileFull -Destination $destFileFull -Force
        Write-Host " -> Staged: $relPath" -ForegroundColor Gray
    } else {
        Write-Host " -> Skipped (File deleted or missing): $relPath" -ForegroundColor DarkYellow
        continue
    }

    # CRITICAL: If the file belongs to an Entity, we must provision an empty parent Entity.xml shell
    if ($relPath -match "src/Entities/(?[^/]+)/") {
        $entityName = $Matches['entityName']
        $entityXmlSrc = Join-Path $sourceDir "Entities\$entityName\Entity.xml"
        $entityXmlDest = Join-Path $buildDir "src\Entities\$entityName\Entity.xml"

        if ((Test-Path $entityXmlSrc) -and !(Test-Path $entityXmlDest)) {
            # Copy and wipe attributes/relationships nodes so fields are completely untouched
            $entityXml = [xml](Get-Content $entityXmlSrc)
            if ($entityXml.Entity.attributes) { $entityXml.Entity.attributes.RemoveAll() }
            if ($entityXml.Entity.Relationships) { $entityXml.Entity.Relationships.RemoveAll() }
            $entityXml.Save($entityXmlDest)
        }
    }

    # Match the file path to extract its Dynamics 365 Component Type and Unique GUID 
    foreach ($mapping in $componentMappings) {
        if ($relPath -match $mapping.Pattern) {
            $fileName = Split-Path $relPath -Leaf
            if ($fileName -match "(?<guid>\{?[a-fA-E0-9]{8}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{12}\}?)") {
                $guid = $Matches['guid']
                # Collect item if it's not a duplicate record entry
                if (!($detectedComponents | Where-Object { $_.Id -eq $guid })) {
                    $detectedComponents += New-Object PSObject -Property @{ Type = $mapping.Type; Id = $guid }
                }
            }
        }
    }
}

Write-Host "✍️ Step 3: Automatically rewriting Solution.xml with matched components..." -ForegroundColor Cyan
$origSolutionXmlPath = Join-Path $otherDir "Solution.xml"
$newSolutionXmlPath  = Join-Path $buildDir "Other\Solution.xml"

if (!(Test-Path $origSolutionXmlPath)) {
    Write-Error "❌ Base Solution.xml profile not found at: $origSolutionXmlPath"
    exit 1
}

# Load schema structure of original XML manifest file
$solXml = [xml](Get-Content $origSolutionXmlPath)
$rootComponentsNode = $solXml.ImportExportXml.SolutionManifest.RootComponents
$rootComponentsNode.RemoveAll() # Purge old static references of all 500+ items

# Inject only the explicitly modified files tracked in Step 2
foreach ($comp in $detectedComponents) {
    $newNode = $solXml.CreateElement("RootComponent")
    $newNode.SetAttribute("type", $comp.Type)
    $newNode.SetAttribute("id", $comp.Id)
    $newNode.SetAttribute("behavior", "0")
    $rootComponentsNode.AppendChild($newNode) | Out-Null
    Write-Host " -> Injected XML RootComponent: Type $($comp.Type), ID $($comp.Id)" -ForegroundColor DarkGreen
}

# Save new Solution.xml manifest out into the custom build tree
$solXml.Save($newSolutionXmlPath)

Write-Host "📦 Step 4: Compiling segmented zip file using PAC CLI..." -ForegroundColor Cyan
if (Test-Path $outputZip) { Remove-Item $outputZip -Force }

# Invoke Power Platform CLI tool to package the isolated staging tree
pac solution pack --zipfile $outputZip --folder (Join-Path $buildDir "src") --packagetype Both

if ($LASTEXITCODE -ne 0) {
    Write-Error "❌ PAC CLI compilation failed."
    exit 1
}

Write-Host "`n🚀 Success! Your targeted segmented package is built at:" -ForegroundColor Green
Write-Host $outputZip -ForegroundColor Yellow
Write-Host "This contains ONLY your changed components and matches your main unique solution container name." -ForegroundColor Green
