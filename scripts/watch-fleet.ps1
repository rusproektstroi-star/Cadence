#requires -Version 7.0
<#
  watch-fleet.ps1 — наблюдатель со стороны хоста. Раз в 15 с отмечает по каждой включённой машине,
  отвечает ли она, и одновременно снимает состояние хоста: очередь к диску с виртуалками, загрузку
  процессора, свободную память.

  Смысл: когда гость встаёт, изнутри его уже не спросить — а эта запись останется. Вместе с
  ~/vitals.log на самом госте даёт две независимые картины одного момента.

  Запуск (в отдельном окне или свёрнутым):
      pwsh -NoProfile -File <репозиторий>\scripts\watch-fleet.ps1
  Остановка — Ctrl+C или закрыть окно. Лог: <репозиторий>\logs\watch-<дата>.log
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
    # Каталог .vmem.lck существует только пока у машины есть файл памяти. С
    # mainMem.useNamedFile = "FALSE" его нет вовсе, и прибор слепнет (нашли 2026-09-20: в логе
    # пошли сплошные "cpu=?"). Тот же PID в том же формате лежит в блокировке диска, поэтому
    # перебираем все каталоги *.lck, начиная с памяти.
    $lckDirs = @(Get-ChildItem -Path $dir -Filter "*.lck" -Directory -ErrorAction SilentlyContinue |
                 Sort-Object { if ($_.Name -like "*.vmem.lck") { 0 } else { 1 } })
    foreach ($lckDir in $lckDirs) {
        foreach ($lckFile in @(Get-ChildItem -Path $lckDir.FullName -Filter "*.lck" -File -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match((Get-Content $lckFile.FullName -Raw -ErrorAction SilentlyContinue), '(\d+)-\d+\(vmware-vmx\.exe\)')
            if ($m.Success) { return [int]$m.Groups[1].Value }
        }
    }
    return $null
}

$prev = @{}
$script:prevCpu = @{}
$script:prevIo = @{}
$script:prevPf = @{}
$script:prevStamp = $null
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
    # Помимо процессора снимаем ввод-вывод и ошибки страниц: если ОЗУ гостя подпёрта файлом .vmem
    # на медленном диске, остановка происходит в слое памяти гипервизора и внутри гостя невидима
    # (wa=0, D=0). Всплеск ошибок страниц у процесса виртуалки — единственный внешний след такого.
    # Делим прирост процессорного времени на ФАКТИЧЕСКИЙ интервал, а не на плановый: когда гость не
    # отвечает, проверка порта 22 висит на таймауте и виток растягивается до 20-25 с. Деление на
    # номинальные 15 с завышало проценты в полтора раза — на этих цифрах мы уже делали выводы.
    $sampleAt = Get-Date
    $elapsed = if ($script:prevStamp) { ($sampleAt - $script:prevStamp).TotalSeconds } else { $IntervalSec }
    if ($elapsed -le 0) { $elapsed = $IntervalSec }

    $vmxProcs = @{}
    $cim = @(Get-CimInstance Win32_Process -Filter "Name='vmware-vmx.exe'" -ErrorAction SilentlyContinue)
    foreach ($p in Get-Process vmware-vmx -ErrorAction SilentlyContinue) {
        $key = $p.Id
        $cpuNow = $p.TotalProcessorTime.TotalSeconds
        $c = $cim | Where-Object ProcessId -eq $key | Select-Object -First 1
        $ioNow = if ($c) { [int64]$c.ReadTransferCount + [int64]$c.WriteTransferCount } else { 0 }
        $pfNow = if ($c) { [int64]$c.PageFaults } else { 0 }

        $cpuD = $null; $ioD = $null; $pfD = $null
        if ($script:prevCpu.ContainsKey($key)) {
            $cpuD = [math]::Round(($cpuNow - $script:prevCpu[$key]) / $elapsed * 100, 1)
            $ioD  = [math]::Round((($ioNow - $script:prevIo[$key]) / $elapsed) / 1MB, 2)
            $pfD  = [math]::Round(($pfNow - $script:prevPf[$key]) / $elapsed)
        }
        $script:prevCpu[$key] = $cpuNow
        $script:prevIo[$key]  = $ioNow
        $script:prevPf[$key]  = $pfNow
        $vmxProcs[$key] = @{ Cpu = $cpuD; Mem = [math]::Round($p.WorkingSet64 / 1MB); Io = $ioD; Pf = $pfD }
    }
    $script:prevStamp = $sampleAt

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
            $v = $vmxProcs[[int]$vmxPid]
            $cpuTxt = "cpu={0}% ram={1}MB io={2}МБ/с pf={3}/с" -f $v.Cpu, $v.Mem, $v.Io, $v.Pf
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
