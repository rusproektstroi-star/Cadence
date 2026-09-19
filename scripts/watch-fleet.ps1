#requires -Version 7.0
<#
  watch-fleet.ps1 — наблюдатель со стороны хоста. Раз в 15 с отмечает по каждой включённой машине,
  отвечает ли она, и одновременно снимает состояние хоста: очередь к диску с виртуалками, загрузку
  процессора, свободную память.

  Смысл: когда гость встаёт, изнутри его уже не спросить — а эта запись останется. Вместе с
  ~/vitals.log на самом госте даёт две независимые картины одного момента.

  Запуск (в отдельном окне или свёрнутым):
      pwsh -NoProfile -File <репозиторий>\scripts\watch-fleet.ps1
  Остановка — Ctrl+C или закрыть окно. Лог: C:\vmfleet\logs\watch-<дата>.log
#>

param(
    [int]$IntervalSec = 15,
    [string]$VmxDrive = 'E:'
)

$ErrorActionPreference = 'Continue'
$LogDir = Join-Path (Split-Path $PSScriptRoot -Parent) "logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$VmrunPath = "C:\Program Files\VMware\VMware Workstation\vmrun.exe"

# Счётчики диска в русской локали называются иначе, поэтому берём по индексам, а не по именам.
$diskCounter = "\PhysicalDisk(*)\Avg. Disk Queue Length"
try { Get-Counter -Counter $diskCounter -MaxSamples 1 -ErrorAction Stop | Out-Null }
catch { $diskCounter = $null }

Write-Host "Наблюдатель запущен, интервал $IntervalSec с. Лог: $LogDir\watch-<дата>.log"
Write-Host "Останов — Ctrl+C.`n"


function Get-VmxPid {
    # Win32_Process.CommandLine у vmware-vmx.exe пуст без прав администратора — PID берём из
    # lock-файла <uuid>.vmem.lck\*.lck рядом с .vmx, тот же приём, что в vmfleet.ps1.
    param([string]$VmxPath)
    $dir = Split-Path $VmxPath -Parent
    $lckDir = Get-ChildItem -Path $dir -Filter "*.vmem.lck" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lckDir) { return $null }
    $lckFile = Get-ChildItem -Path $lckDir.FullName -Filter "*.lck" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lckFile) { return $null }
    $m = [regex]::Match((Get-Content $lckFile.FullName -Raw -ErrorAction SilentlyContinue), '(\d+)-\d+\(vmware-vmx\.exe\)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

$prev = @{}
$script:prevCpu = @{}
while ($true) {
    $now = Get-Date
    $log = Join-Path $LogDir "watch-$($now.ToString('yyyy-MM-dd')).log"

    $running = @(& $VmrunPath list 2>$null | Where-Object { $_ -match '\.vmx$' })
    $os = Get-CimInstance Win32_OperatingSystem
    $freeMb = [math]::Round($os.FreePhysicalMemory / 1KB)
    $cpu = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average)

    $diskQ = '?'
    if ($diskCounter) {
        try {
            $s = (Get-Counter -Counter $diskCounter -MaxSamples 1 -ErrorAction Stop).CounterSamples |
                 Where-Object { $_.InstanceName -notmatch '_total' } | Sort-Object CookedValue -Descending | Select-Object -First 1
            $diskQ = '{0:N2}' -f $s.CookedValue
        } catch { }
    }

    # Процесс самой виртуалки: крутит ли он процессор в момент обрыва. Если vmware-vmx ест CPU —
    # гость сам себя загоняет; если простаивает — он чего-то ждёт снаружи. Это разные диагнозы.
    $vmxProcs = @{}
    foreach ($p in Get-Process vmware-vmx -ErrorAction SilentlyContinue) {
        $cpuNow = $p.TotalProcessorTime.TotalSeconds
        $key = $p.Id
        $delta = if ($script:prevCpu.ContainsKey($key)) { [math]::Round(($cpuNow - $script:prevCpu[$key]) / $IntervalSec * 100, 1) } else { $null }
        $script:prevCpu[$key] = $cpuNow
        $vmxProcs[$key] = @{ Cpu = $delta; Mem = [math]::Round($p.WorkingSet64 / 1MB) }
    }

    $states = foreach ($vmx in $running) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($vmx)
        $ip = (& $VmrunPath getGuestIPAddress $vmx 2>$null | Select-Object -First 1)
        $alive = $false
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
            $t = Test-NetConnection -ComputerName $ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
            $alive = [bool]$t
        }
        # отмечаем момент смены состояния — именно он интересен в разборе
        $vmxPid = Get-VmxPid -VmxPath $vmx
        $cpuTxt = "cpu=?"
        if ($vmxPid -and $vmxProcs.ContainsKey([int]$vmxPid) -and $null -ne $vmxProcs[[int]$vmxPid].Cpu) {
            $cpuTxt = "cpu={0}% ram={1}MB" -f $vmxProcs[[int]$vmxPid].Cpu, $vmxProcs[[int]$vmxPid].Mem
        }

        $mark = ''
        if ($prev.ContainsKey($id) -and $prev[$id] -ne $alive) { $mark = if ($alive) { '  <<< ОЖИЛА' } else { '  <<< ПЕРЕСТАЛА ОТВЕЧАТЬ' } }
        $prev[$id] = $alive
        "{0}={1}({2}){3}" -f $id, $(if ($alive) { 'ok' } else { 'НЕТ' }), $cpuTxt, $mark
    }

    $line = "{0} cpu={1}% freeRAM={2}MB diskQ({3})={4} | {5}" -f `
        $now.ToString('yyyy-MM-ddTHH:mm:ss'), $cpu, $freeMb, $VmxDrive, $diskQ, ($states -join ' ')
    Add-Content -Path $log -Value $line
    if ($line -match '<<<') { Write-Host $line -ForegroundColor Yellow }

    Start-Sleep -Seconds $IntervalSec
}
