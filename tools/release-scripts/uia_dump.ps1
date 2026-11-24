# Lists the UI elements of every top-level window of PalworldModUploader.
param([int]$MaxDepth = 8)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$p = Get-Process PalworldModUploader -ErrorAction Stop | Select-Object -First 1
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
function Show-Node($el, $depth) {
    if ($depth -gt $MaxDepth) { return }
    $c = $el.Current
    $val = ""
    try {
        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) { $val = " value=[" + $vp.Current.Value + "]" }
    } catch {}
    $type = $c.ControlType.ProgrammaticName -replace "ControlType\.", ""
    Write-Output (("  " * $depth) + "$type name=[$($c.Name)] id=[$($c.AutomationId)] enabled=$($c.IsEnabled)$val")
    $child = $walker.GetFirstChild($el)
    $n = 0
    while ($child -and $n -lt 60) {
        Show-Node $child ($depth + 1)
        $child = $walker.GetNextSibling($child)
        $n++
    }
}
foreach ($w in $wins) { Show-Node $w 0 }
