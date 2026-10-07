$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$workflowPath = Join-Path $PSScriptRoot '..\.github\workflows\publish-app-release.yml'
$workflow = [IO.File]::ReadAllText((Resolve-Path $workflowPath), [Text.Encoding]::UTF8)
$match = [regex]::Match($workflow, '(?ms)^        run: \|\r?\n(?<script>.*?)(?=^      - name:|\z)')
if (-not $match.Success) { throw 'Could not locate inline workflow script.' }
$scriptLines = $match.Groups['script'].Value -split "`r?`n"
$scriptLines = @($scriptLines | ForEach-Object { if ($_.StartsWith('          ')) { $_.Substring(10) } else { $_ } })
$scriptText = $scriptLines -join "`n"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "Workflow PowerShell parse failed: $($parseErrors[0].Message)" }
$names = @('Assert-ReleaseNotes', 'Write-ReleaseNotesFile', 'Test-PublicTrackedPath')
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $names }, $true))
if ($definitions.Count -ne 3) { throw 'Could not extract the release notes and public path validation functions.' }
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

$notesAssignment = @($ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
    $node.Left.VariablePath.UserPath -ceq 'notesByVersion'
}, $true) | Select-Object -First 1)
if ($notesAssignment.Count -ne 1) { throw 'Could not locate the release notes version map.' }
$notesMapScript = $notesAssignment[0].Extent.Text + "`n" +
  '@($notesByVersion[''1.0.59''], $notesByVersion[''1.0.60''], $notesByVersion[''1.0.61''], $notesByVersion[''1.0.62''], $notesByVersion[''1.0.63''], $notesByVersion[''1.0.64''])'
$selectedNotes = @(& ([scriptblock]::Create($notesMapScript)))
if ($selectedNotes.Count -ne 6) { throw 'Could not extract the selected release notes through 1.0.64.' }
foreach ($notes in $selectedNotes) { Assert-ReleaseNotes $notes }

function Assert-RejectedNotes {
  param([string]$Text, [string]$Label)
  $rejected = $false
  try { Assert-ReleaseNotes $Text } catch { $rejected = $true }
  if (-not $rejected) { throw "Expected rejection: $Label" }
}

Assert-ReleaseNotes (([regex]::Unescape('- \u0412\u0438\u043f\u0440\u0430\u0432\u043b\u0435\u043d\u043e \u0437\u0431\u0435\u0440\u0435\u0436\u0435\u043d\u043d\u044f \u043d\u0430\u043b\u0430\u0448\u0442\u0443\u0432\u0430\u043d\u044c.')) + "`n- Fixed settings persistence.")
Assert-ReleaseNotes '- Fixed settings persistence.'
Assert-RejectedNotes '- ????? Broken encoding.' 'question mark run'
Assert-RejectedNotes "- Invalid $([char]0xFFFD) text." 'replacement character'
Assert-RejectedNotes ([regex]::Unescape('- \u0420\u045f\u0421\u0402\u0420\u0451\u0420\u0406\u0421\u2013\u0421\u201a')) 'UTF-8 mojibake'
Assert-RejectedNotes '- [Download](https://example.test/app.exe)' 'Markdown link'
Assert-RejectedNotes '- Download https://example.test/app.exe' 'bare URL'

if (-not (Test-PublicTrackedPath 'tool/test_release_notes.ps1')) { throw 'Regression test path must be allowed as a tracked non-shipping file.' }
if (Test-PublicTrackedPath 'tool/unapproved.ps1') { throw 'Unapproved tool files must remain outside the public file allowlist.' }
if (-not (Test-PublicTrackedPath 'release-assets/v1.0.59/SHA256SUMS.txt')) { throw 'Approved release asset path was rejected.' }
if (Test-PublicTrackedPath 'release-assets/v1.0.59/private.txt') { throw 'Unapproved release asset path was accepted.' }

$tempFile = Join-Path ([IO.Path]::GetTempPath()) ("release-notes-test-{0}.md" -f [guid]::NewGuid())
try {
  $expected = [regex]::Unescape('- \u0423\u043a\u0440\u0430\u0457\u043d\u0441\u044c\u043a\u0456 \u043d\u043e\u0442\u0430\u0442\u043a\u0438 \u0437 \u0430\u043f\u043e\u0441\u0442\u0440\u043e\u0444\u043e\u043c: \u043e\u0431\u2019\u0454\u043a\u0442.')
  Write-ReleaseNotesFile $tempFile $expected
  $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
  if ([IO.File]::ReadAllText($tempFile, $strictUtf8) -cne $expected) { throw 'UTF-8 test round-trip mismatch.' }
} finally {
  Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

'Release notes regression checks passed.'
