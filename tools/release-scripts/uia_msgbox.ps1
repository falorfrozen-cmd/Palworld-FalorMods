# Presses a button of a standard message box owned by PalworldModUploader.
#   uia_msgbox.ps1 "<dialog title part>" <button id: 1 = OK, 2 = Cancel, 6 = Yes, 7 = No>
param([string]$Title, [int]$ButtonId)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
'@
$AE = [System.Windows.Automation.AutomationElement]
$p = Get-Process PalworldModUploader -ErrorAction Stop | Select-Object -First 1
$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
$wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.AndCondition($cond,
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))))
foreach ($w in $wins) {
    if ($w.Current.Name -like "*$Title*") {
        $h = [System.IntPtr]$w.Current.NativeWindowHandle
        if ($h -ne [System.IntPtr]::Zero) {
            # WM_COMMAND with the button id = what a click on that button sends
            [void][Native.Win]::PostMessage($h, 0x0111, [System.IntPtr]$ButtonId, [System.IntPtr]::Zero)
            Write-Output ("sent button $ButtonId to [" + $w.Current.Name + "]")
            exit 0
        }
    }
}
Write-Output "dialog not found"
exit 1
