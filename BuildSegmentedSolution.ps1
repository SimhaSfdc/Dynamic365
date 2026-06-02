# =================================================================================
# DYNAMICS 365 AUTOMATED SEGMENTED SOLUTION BUILDER (GIT BASED)
# =================================================================================
$sourceDir   = Join-Path $PSScriptRoot "src"
$otherDir    = Join-Path $PSScriptRoot "Other"
$buildDir    = Join-Path $PSScriptRoot "_segmented_build"
$outputZip   = Join-Path $PSScriptRoot "SegmentedSolutionFix.zip"

# Clean up any previous segmented build folders
if (Test-Path $buildDir) { Remove-Item -Path $buildDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $buildDir "src") | Out-Null
New-Item -ItemType Directory -Path (Join-Path $buildDir "Other") | Out-Null

Write-Host "🔍 Step 1: Identifying modified files using Git..." -ForegroundColor Cyan
# Gets relative paths of both modified and untracked files in the 'src' or 'Other' folders
$changedFiles = git status --porcelain | ForEach-Object {
    $path = $_.Substring(3).Trim()
    if ($path.StartsWith("src/") -or $path.StartsWith("Other/")) { $path }
}

if ($null -eq $changedFiles -or $changedFiles.Count -eq 0) {
    Write-Error "❌ No changed or untracked files detected in Git. Commit changes or modify files before running."
    exit
}

# Mapping table to match file structures/extensions to Dataverse Solution Component Type IDs
$componentMappings = @(
    @{ Pattern = "Entities\\.*?\\FormXml\\.*?\\.*\.xml$"; Type = "60" },      # System Form
    @{ Pattern = "Entities\\.*?\\SavedQueries\\.*?\.xml$"; Type = "64" },     # Saved Query (View)
    @{ Pattern = "Entities\\.*?\\RibbonDiff\\.xml$"; Type = "29" },           # Ribbon Customization
    @{ Pattern = "SiteMaps\\.*?\.xml$"; Type = "62" },                        # Site Map
    @{ Pattern = "WebResources\\.*?\.xml$"; Type = "61" },                    # Web Resource
    @{ Pattern = "PluginAssemblies\\.*?\.xml$"; Type = "91" },                # Plugin Assembly
    @{ Pattern = "Workflows\\.*?\.xml$"; Type = "29" }                        # Workflow/Flow
)

$detectedComponents = @()

Write-Host "📂 Step 2: Isolating changed files and staging folder structure..." -ForegroundColor Cyan
foreach ($relPath in $changedFiles) {
    # Skip Solution.xml itself, we will handle that separately
    if ($relPath -like "*Solution.xml") { continue }

    $srcFileFull = Join-Path $PSScriptRoot $relPath
    $destFileFull = Join-Path $buildDir $relPath
    $destFolder = Split-Path $destFileFull

    # Ensure targeted subfolder exists inside the segmented directory
    if (!(Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
    Copy-Item -Path $srcFileFull -Destination $destFileFull -Force
    Write-Host " -> Staged: $relPath" -ForegroundColor Gray

    # If the file belongs to an Entity sub-component, we MUST copy its parent Entity.xml shell
    if ($relPath -match "src/Entities/(?[^/]+)/") {
        $entityName = $Matches['entityName']
        $entityXmlSrc = Join-Path $sourceDir "Entities\$entityName\Entity.xml"
        $entityXmlDest = Join-Path $buildDir "src\Entities\$entityName\Entity.xml"

        if ((Test-Path $entityXmlSrc) -and !(Test-Path $entityXmlDest)) {
            # Copy and clean the Entity.xml to an empty shell to avoid importing unintended fields
            $entityXml = [xml](Get-Content $entityXmlSrc)
            if ($entityXml.Entity.attributes) { $entityXml.Entity.attributes.RemoveAll() }
            if ($entityXml.Entity.Relationships) { $entityXml.Entity.Relationships.RemoveAll() }
            $entityXml.Save($entityXmlDest)
        }
    }

    # Match the file path to extract its Solution Component Type and GUID 
    foreach ($mapping in $componentMappings) {
        if ($relPath -match $mapping.Pattern) {
            # Extract GUID from the filename (e.g. {guid}.xml or filename.xml)
            $fileName = Split-Path $relPath -Leaf
            if ($fileName -match "(?<guid>\{?[a-fA-E0-9]{8}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{4}-[a-fA-E0-9]{12}\}?)") {
                $guid = $Matches['guid']
                # Store detected components cleanly avoiding duplicate lines
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
    Write-Error "❌ Original Solution.xml not found at $origSolutionXmlPath"
    exit
}

# Load structural details of original XML file
$solXml = [xml](Get-Content $origSolutionXmlPath)
$rootComponentsNode = $solXml.ImportExportXml.SolutionManifest.RootComponents
$rootComponentsNode.RemoveAll() # Wipe old lists of 500+ items

# Inject only the explicitly modified files discovered in Step 2
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

# Call Power Platform PAC CLI tool directly targeting the segmented workspace
pac solution pack --zipfile $outputZip --folder (Join-Path $buildDir "src") --packagetype Both

Write-Host "`n🚀 Success! Your targeted segmented package is built at:" -ForegroundColor Green
Write-Host $outputZip -ForegroundColor Yellow
Write-Host "This contains ONLY your changed components and is completely safe to import." -ForegroundColor Green
