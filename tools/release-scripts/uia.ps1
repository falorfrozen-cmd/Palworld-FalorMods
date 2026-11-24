# Small UI Automation helper for PalworldModUploader.
#   uia.ps1 list                      -> every window: buttons, edits, texts, checkboxes (data grid rows skipped)
#   uia.ps1 invoke "<button text>" [window title part]
#   uia.ps1 set "<automation id>" "<value>" [window title part]
#   uia.ps1 select "<list item text>" [window title part]
#   uia.ps1 row "<directory id>"      -> select a data grid row by its first cell
#   uia.ps1 toggle "<checkbox text>" [window title part]
param([string]$Cmd = "list", [string]$A = "", [string]$B = "", [string]$C = "")
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$p = Get-Process PalworldModUploader -ErrorAction Stop | Select-Object -First 1
$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

function Get-Windows {
    $out = @()
    $top = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($w in $top) {
        $out += $w
        # modal dialogs owned by the main window show up as its children
        $kids = $w.FindAll([System.Windows.Automation.TreeScope]::Children,
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
        foreach ($k in $kids) { $out += $k }
    }
    return $out
}
function Get-Label($el) {
    $n = $el.Current.Name
    if ($n) { return $n }
    $t = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))
    if ($t) { return $t.Current.Name }
    return ""
}
function Walk($el, $depth, [ref]$acc) {
    if ($depth -gt 12) { return }
    $type = $el.Current.ControlType.ProgrammaticName -replace "ControlType\.", ""
    if ($type -eq "DataItem") { return }
    $acc.Value += ,@($el, $type, $depth)
    $child = $walker.GetFirstChild($el)
    $n = 0
    while ($child -and $n -lt 200) { Walk $child ($depth + 1) $acc; $child = $walker.GetNextSibling($child); $n++ }
}
function Pick-Window($part) {
    $ws = Get-Windows
    if ($part) { $ws = $ws | Where-Object { $_.Current.Name -like "*$part*" } }
    return $ws
}

if ($Cmd -eq "list") {
    foreach ($w in (Get-Windows)) {
        Write-Output ("=== WINDOW [" + $w.Current.Name + "]")
        $acc = @()
        Walk $w 0 ([ref]$acc)
        foreach ($e in $acc) {
            $el = $e[0]; $type = $e[1]
            if ($type -in @("Button", "Edit", "CheckBox", "ComboBox", "ListItem", "RadioButton", "Text", "TabItem")) {
                $val = ""
                try { $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); if ($vp) { $val = " value=[" + $vp.Current.Value + "]" } } catch {}
                $tog = ""
                try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern); if ($tp) { $tog = " toggle=" + $tp.Current.ToggleState } } catch {}
                $label = if ($type -eq "Text") { $el.Current.Name } else { Get-Label $el }
                Write-Output ("  $type [" + $label + "] id=[" + $el.Current.AutomationId + "] enabled=" + $el.Current.IsEnabled + $val + $tog)
            }
        }
    }
    exit 0
}

if ($Cmd -eq "row") {
    $w = (Get-Windows)[0]
    $items = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)))
    foreach ($it in $items) {
        $first = $walker.GetFirstChild($it)
        if ($first -and $first.Current.Name -eq $A) {
            try { ($it.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern)).ScrollIntoView() } catch {}
            ($it.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            Write-Output "selected row $A"; exit 0
        }
    }
    Write-Output "row $A not found"; exit 1
}

$wins = Pick-Window $(if ($Cmd -eq "set") { $C } else { $B })
foreach ($w in $wins) {
    $acc = @()
    Walk $w 0 ([ref]$acc)
    foreach ($e in $acc) {
        $el = $e[0]; $type = $e[1]
        if ($Cmd -eq "invoke" -and $type -eq "Button" -and (Get-Label $el) -eq $A) {
            ($el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
            Write-Output ("invoked [" + $A + "] in [" + $w.Current.Name + "]"); exit 0
        }
        if ($Cmd -eq "set" -and $el.Current.AutomationId -eq $A) {
            ($el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($B)
            Write-Output ("set [" + $A + "]"); exit 0
        }
        if ($Cmd -eq "select" -and $type -in @("ListItem", "RadioButton") -and (Get-Label $el) -eq $A) {
            ($el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            Write-Output ("selected [" + $A + "]"); exit 0
        }
        if ($Cmd -eq "toggle" -and $type -eq "CheckBox" -and (Get-Label $el) -eq $A) {
            ($el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
            Write-Output ("toggled [" + $A + "]"); exit 0
        }
    }
}
Write-Output "not found: $Cmd $A"
exit 1
