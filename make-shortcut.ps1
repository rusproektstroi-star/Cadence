#requires -Version 7.0
<#
  make-shortcut.ps1 — кладёт на рабочий стол ярлык «Cadence», который открывает PowerShell 7
  в каталоге оркестратора, печатает статус парка и запускает агента. Один клик вместо
  "открыть терминал → перейти в каталог → посмотреть статус → запустить claude".

  Запуск:
    .\make-shortcut.ps1                                   # C:\vmfleet, ярлык на рабочем столе
    .\make-shortcut.ps1 -FleetRoot D:\vmfleet -NoStatus   # свой каталог, без вывода статуса
    .\make-shortcut.ps1 -Startup                          # ещё и в автозапуск при входе в Windows
#>

param(
    [string]$FleetRoot = 'C:\vmfleet',
    [string]$Name      = 'Cadence',
    [string]$Agent     = 'claude',   # команда запуска агента; '' — не запускать, только статус
    [switch]$NoStatus,               # не печатать статус парка при старте
    [switch]$Startup                 # положить копию в автозагрузку (запуск при входе в Windows)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FleetRoot)) {
    throw "Каталог оркестратора не найден: $FleetRoot — указать свой через -FleetRoot"
}

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) { throw "pwsh (PowerShell 7) не найден в PATH — ярлык не на что вешать" }

# Команда внутри ярлыка: перейти в каталог -> (статус) -> (агент). -NoExit, чтобы окно осталось
# живым после выхода из агента, а не закрылось вместе с ним.
$steps = @("Set-Location '$FleetRoot'")
if (-not $NoStatus) { $steps += ".\vmfleet.ps1 status" }
if ($Agent)         { $steps += $Agent }
$inner = $steps -join '; '

$shell = New-Object -ComObject WScript.Shell
$targets = @([Environment]::GetFolderPath('Desktop'))
if ($Startup) { $targets += [Environment]::GetFolderPath('Startup') }

foreach ($dir in $targets) {
    $lnkPath = Join-Path $dir "$Name.lnk"
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $pwshPath
    $lnk.Arguments        = "-NoExit -Command `"$inner`""
    $lnk.WorkingDirectory = $FleetRoot
    $lnk.IconLocation     = "$pwshPath,0"
    $lnk.Description      = "Cadence: статус парка ВМ и агент-оркестратор"
    $lnk.Save()
    Write-Host "Ярлык создан: $lnkPath" -ForegroundColor Green
}

Write-Host "Команда внутри ярлыка: pwsh -NoExit -Command `"$inner`""
