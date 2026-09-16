#requires -Version 7.0
<#
  vmfleet.ps1 — тонкая обёртка над vmrun для управления флотом VM с ИИ-агентами (Cadence).
  Никакой логики сверх управления парком: провижининг деталей проекта — через SSH отдельно.

  ПЕРЕД ПЕРВЫМ ЗАПУСКОМ — отредактировать блок "Конфиг" ниже под свой хост (SSH-пользователь
  гостевых машин, подсеть VMware, диск для .vmx). Скрипт нарочно не имеет значений по умолчанию,
  которые "просто заработают" на чужом хосте — заменить ИЛИ ЯВНО подтвердить каждое.
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('validate', 'up', 'down', 'status', 'health', 'ssh-config', 'hosts-file', 'activate', 'deactivate', 'snapshot', 'revert', 'clone', 'check-sync', 'dev-start', 'dev-stop', 'dev-status', 'dev-reap', 'dev-watchdog', 'install-dev-watchdog-task', 'shell-open', 'shell-close', 'agents-md-install', 'mount', 'unmount', 'mounts')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Id,

    [string]$Only,
    [string]$Group,
    [string]$Repo,
    [string]$SnapshotName,
    [string]$LocalPath,
    [switch]$Open,
    [string]$DeployKey,
    [string]$Token,
    [string]$LibraryRepo
)

$ErrorActionPreference = 'Stop'

# Вызывающий процесс (chcp 437 по умолчанию у cmd.exe/легаси-оболочек) иначе подменяет кириллицу
# в выводе на "?" — без этой строки статус реально показывает "?????????" вместо текста.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {
    # Бросает, если stdout перенаправлен и не является настоящей консолью — тогда нечего
    # переключать, не фатально.
}

# PowerShell 7 иначе вставляет ANSI-коды подсветки (Format-Table и т.п.) даже когда вывод
# перехватывается программой, а не терминалом — выглядит как мусорные "[32;1m" в тексте,
# ломает вид таблицы. PlainText — раз и навсегда для этого скрипта, не только для интерактива.
$PSStyle.OutputRendering = [System.Management.Automation.OutputRendering]::PlainText

# =============================================================================
# КОНФИГ — отредактировать под свой хост перед первым запуском
# =============================================================================
$Root = $PSScriptRoot                                       # где лежит этот скрипт — inventory.yaml/logs рядом с ним
$VmrunPath = "C:\Program Files\VMware\VMware Workstation\vmrun.exe"
$VmxRoot = "E:\Virtual Machines"                            # диск/папка, где живут .vmx гостей
$InventoryPath = Join-Path $Root "inventory.yaml"
$LogDir = Join-Path $Root "logs"
$MaxConcurrent = 8                                          # сколько машин можно поднять разом
$MinFreeMemMB = 1536                                         # порог свободной ОЗУ хоста при up

# SSH-пользователь и владельческий ключ ОДИНАКОВЫ на golden-образе и всех его клонах (образ несёт
# один и тот же аккаунт гостя). Заменить на реальные значения — обязательно, скрипт не работает
# с плейсхолдером ниже.
$SshUser = "changeme"
$SshOwnerKey = "$env:USERPROFILE\.ssh\id_ed25519_vmfleet"
if ($SshUser -eq 'changeme' -and $Command -notin @('validate')) {
    throw "vmfleet.ps1: `$SshUser всё ещё 'changeme' — отредактировать блок КОНФИГ вверху файла под свой хост (SSH-пользователь гостевых машин из golden-образа)."
}

# -i явно — по IP (не по алиасу из ~/.ssh/config) ключ не подхватывается сам; accept-new — для
# лабораторной сети без выхода наружу, разумный компромисс, чтобы новый клон не требовал ручного
# first-contact. Для сети с недоверенными участниками — сменить на более строгую политику.
$SshBaseOpts = @('-i', $SshOwnerKey, '-o', 'StrictHostKeyChecking=accept-new')

# Подсеть VMware этого хоста — смотреть в VMware Virtual Network Editor (Edit > Virtual Network
# Editor > выбранная сеть > Subnet), диапазон .10-.99 предполагается ВНЕ DHCP-пула этой сети.
$StaticIpBase = "192.168.100."
$StaticIpRangeStart = 10
$StaticIpRangeEnd = 99
$MaxActiveProjects = 2   # сколько проектов держать одновременно "активными" (браузер+dev-сервер)

# Монтирование рабочих каталогов гостей на буквы дисков хоста (SSHFS-Win). Буквы раздаются с конца
# алфавита: новые физические диски Windows нумерует от начала, так они не наступают на проекты.
$MountLetterPool = @('X', 'Y', 'Z', 'W', 'V', 'U')
# Оба компонента ставятся в РАЗНЫЕ Program Files: WinFsp — 32-битный инсталлятор, кладёт себя в
# "Program Files (x86)" и пишет ключ в WOW6432Node; SSHFS-Win — в обычный "Program Files".
# Проверено на реальной установке: одного жёстко заданного пути недостаточно.
$MountPrereqPaths = @{
    'WinFsp'    = @("$env:ProgramFiles\WinFsp", "${env:ProgramFiles(x86)}\WinFsp")
    'SSHFS-Win' = @("$env:ProgramFiles\SSHFS-Win", "${env:ProgramFiles(x86)}\SSHFS-Win")
}
$MountPrereqRegKeys = @{
    'WinFsp'    = @('HKLM:\SOFTWARE\WinFsp', 'HKLM:\SOFTWARE\WOW6432Node\WinFsp')
    'SSHFS-Win' = @('HKLM:\SOFTWARE\SSHFS-Win', 'HKLM:\SOFTWARE\WOW6432Node\SSHFS-Win')
}
$MountLabelRegRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'

if (-not (Test-Path $VmrunPath)) {
    throw "vmrun не найден по пути '$VmrunPath' — проверить установку VMware Workstation."
}
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

# ---------------------------------------------------------------------------
# Служебное
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    $logFile = Join-Path $LogDir "$(Get-Date -Format yyyy-MM-dd).log"
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

function Invoke-Vmrun {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Write-Log "vmrun $($Args -join ' ')"
    $output = & $VmrunPath @Args 2>&1
    $code = $LASTEXITCODE
    Write-Log "  exit=$code output=$($output -join ' | ')"
    # vmrun умеет вернуть 0 при фактической неудаче — код возврата не единственный сигнал,
    # вызывающий код проверяет результат отдельно.
    return @{ Code = $code; Output = $output }
}

function Get-Inventory {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        throw "Модуль powershell-yaml не установлен. Install-Module powershell-yaml -Scope CurrentUser"
    }
    Import-Module powershell-yaml -ErrorAction Stop
    if (-not (Test-Path $InventoryPath)) { throw "inventory.yaml не найден: $InventoryPath (см. inventory.yaml.example)" }
    return (Get-Content $InventoryPath -Raw | ConvertFrom-Yaml)
}

function Get-VmEntry {
    param($Inventory, [string]$VmId)
    $vm = $Inventory.vms | Where-Object { $_.id -eq $VmId }
    if (-not $vm) { throw "Машина '$VmId' не найдена в inventory.yaml" }
    return $vm
}

function Get-NextFreeStaticIp {
    $inv = Get-Inventory
    $used = @($inv.vms | ForEach-Object { $_.network.ip } | Where-Object { $_ })
    for ($i = $StaticIpRangeStart; $i -le $StaticIpRangeEnd; $i++) {
        $candidate = "$StaticIpBase$i"
        if ($candidate -notin $used) { return $candidate }
    }
    throw "Нет свободных статических адресов в диапазоне $StaticIpBase$StaticIpRangeStart-$StaticIpRangeEnd"
}

function Get-LocalRepoPath {
    param([string]$RepoUrl)
    # git@github.com:org/Name.git или https://github.com/org/Name.git -> "Name"
    $name = ($RepoUrl -split '[/:]')[-1] -replace '\.git$', ''
    return Join-Path "$env:USERPROFILE\Documents" $name
}

function Get-NextFreeBrowserProfile {
    $inv = Get-Inventory
    $usedByFleet = @($inv.vms | ForEach-Object { $_.host.browser_profile } | Where-Object { $_ })
    $chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $usedByChrome = @()
    if (Test-Path $chromeUserData) {
        $usedByChrome = @(Get-ChildItem $chromeUserData -Directory -Filter "Profile *" | ForEach-Object { $_.Name })
    }
    for ($i = 1; $i -le 20; $i++) {
        $candidate = "Profile $i"
        if ($candidate -notin $usedByFleet -and $candidate -notin $usedByChrome) { return $candidate }
    }
    throw "Нет свободного номера профиля Chrome (проверено 1-20)"
}

function New-ProjectBrowserShortcut {
    param([string]$LocalRepoPath, [string]$ProfileDir)
    $chromePath = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $chromePath) { throw "chrome.exe не найден на хосте — ярлык не создан" }
    if (-not (Test-Path $LocalRepoPath)) {
        Write-Log "browser-shortcut: локальный клон '$LocalRepoPath' не найден — ярлык не создан, положить вручную после клонирования репозитория на хост"
        return
    }

    $shortcutPath = Join-Path $LocalRepoPath "open-in-browser.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $shortcut = $wsh.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $chromePath
    $shortcut.Arguments = "--profile-directory=`"$ProfileDir`""
    $shortcut.IconLocation = $chromePath
    $shortcut.Description = "Открыть Chrome в профиле $ProfileDir (вкладки/адреса — в самом профиле, не в ярлыке)"
    $shortcut.Save()
    Write-Log "browser-shortcut: создан $shortcutPath ($ProfileDir)"

    $gitignorePath = Join-Path $LocalRepoPath ".gitignore"
    $entry = "open-in-browser.lnk"
    $existing = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }
    if ($existing -notmatch [regex]::Escape($entry)) {
        Add-Content -Path $gitignorePath -Value $entry
        Write-Log "browser-shortcut: '$entry' добавлен в $gitignorePath"
    }
}

function Get-VmHostMemoryUsageMB {
    # Реальное потребление ОЗУ хоста работающей VM. Win32_Process.CommandLine для vmware-vmx.exe
    # пуст без прав администратора — вместо этого PID берём из lock-файла <uuid>.vmem.lck\*.lck
    # рядом с самим .vmx (VMware сам туда его пишет, формат: "uuid=... <PID>-<число>
    # (vmware-vmx.exe) ..."), это доступно без elevation.
    param([string]$VmxPath)
    $dir = Split-Path $VmxPath -Parent
    $lckDir = Get-ChildItem -Path $dir -Filter "*.vmem.lck" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lckDir) { return $null }
    $lckFile = Get-ChildItem -Path $lckDir.FullName -Filter "*.lck" -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lckFile) { return $null }
    $content = Get-Content $lckFile.FullName -Raw -ErrorAction SilentlyContinue
    $m = [regex]::Match($content, '(\d+)-\d+\(vmware-vmx\.exe\)')
    if (-not $m.Success) { return $null }
    $vmxPid = [int]$m.Groups[1].Value
    try {
        $ws = (Get-Process -Id $vmxPid -ErrorAction Stop).WorkingSet64
        return [int][math]::Round($ws / 1MB)
    } catch { return $null }
}

function ConvertTo-MarkdownTable {
    # Печатать сразу в markdown (|...|), а не в консольном ASCII-формате Format-Table — которое
    # чат-сессия, вызывающая этот скрипт, иначе может "улучшить" по-своему вместо показа сырого
    # вывода. Готовый markdown минимизирует повод что-то перестраивать.
    param([object[]]$Objects)
    if (-not $Objects -or $Objects.Count -eq 0) { return "(пусто)" }
    $headers = @($Objects[0].PSObject.Properties.Name)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("| " + ($headers -join " | ") + " |")
    $lines.Add("|" + (($headers | ForEach-Object { "---" }) -join "|") + "|")
    foreach ($o in $Objects) {
        $vals = $headers | ForEach-Object { ("$($o.$_)" -replace '\|', '\|') }
        $lines.Add("| " + ($vals -join " | ") + " |")
    }
    return ($lines -join "`n")
}

function Get-FreeHostMemMB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1KB)
}

# ---------------------------------------------------------------------------
# Монтирование — чистые помощники (без обращения к сети/реестру, покрыты тестами)
# ---------------------------------------------------------------------------
function Get-MountUncPath {
    # \\sshfs\user@host\workspace/project -> в UNC разделитель обратный слэш
    param([string]$User, [string]$HostName, [string]$RemotePath)
    $rel = ($RemotePath -replace '/', '\').Trim('\')
    return "\\sshfs\$User@$HostName\$rel"
}

function ConvertTo-MountPointKey {
    # UNC -> имя ключа MountPoints2: \\sshfs\u@h\p  =>  ##sshfs#u@h#p (подпись диска в проводнике)
    param([string]$UncPath)
    return ($UncPath -replace '^\\\\', '##') -replace '\\', '#'
}

function Test-MountEntry {
    # Возвращает список ошибок записи инвентаря (пустой список = запись корректна). Машины без
    # mount_letter пропускаются: монтирование необязательно, это не ошибка схемы.
    param($Vm, [string[]]$UsedLetters = @())
    $errors = @()
    $letter = $Vm.host.mount_letter
    if (-not $letter) { return $errors }

    if ($letter -notmatch '^[A-Za-z]$') {
        $errors += "$($Vm.id): mount_letter '$letter' — должна быть одна буква A-Z"
        return $errors
    }
    if ($UsedLetters -contains $letter.ToUpper()) {
        $errors += "$($Vm.id): буква $letter уже занята другой машиной парка"
    }
    if (-not $Vm.host.remote_path) {
        $errors += "$($Vm.id): mount_letter задан, но remote_path пуст — монтировать нечего"
    } elseif ($Vm.host.remote_path -match '^[A-Za-z]:|^[\\/]') {
        $errors += "$($Vm.id): remote_path '$($Vm.host.remote_path)' должен быть относительным (от `$HOME гостя)"
    }
    if (-not $Vm.host.mount_label) {
        $errors += "$($Vm.id): mount_label пуст — диск в проводнике будет не отличить от соседнего"
    }
    $inbox = $Vm.guest.inbox_dir
    if ($inbox) {
        if ($inbox -match '^[A-Za-z]:|^[\\/]' -or $inbox -match '\.\.') {
            $errors += "$($Vm.id): inbox_dir '$inbox' должен лежать внутри remote_path (относительный, без '..')"
        }
    }
    return $errors
}

function Get-MountPrereqMissing {
    # Имена отсутствующих предпосылок хоста. Пустой массив = всё на месте. Компонент считается
    # установленным, если найден ЛЮБОЙ из его каталогов-кандидатов или ключ реестра — разрядность
    # инсталлятора у WinFsp и SSHFS-Win разная, одного пути недостаточно.
    param([hashtable]$Paths = $MountPrereqPaths, [hashtable]$RegKeys = $MountPrereqRegKeys)
    $missing = @()
    foreach ($name in $Paths.Keys) {
        $found = @($Paths[$name]) | Where-Object { $_ -and (Test-Path $_) }
        if (-not $found -and $RegKeys -and $RegKeys.ContainsKey($name)) {
            $found = @($RegKeys[$name]) | Where-Object { $_ -and (Test-Path $_) }
        }
        if (-not $found) { $missing += $name }
    }
    return @($missing | Sort-Object)
}

function Get-MappedDriveLetters {
    # Буквы, уже занятые на хосте (любые — физические, сетевые, подставные).
    return @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name |
        Where-Object { $_ -match '^[A-Za-z]$' } | ForEach-Object { $_.ToUpper() })
}



# ---------------------------------------------------------------------------
# validate — схема инвентаря, уникальность id/hostname/config_dir, сходимость бюджета
# ---------------------------------------------------------------------------
function Invoke-Validate {
    $inv = Get-Inventory
    $errors = @()

    $ids = $inv.vms | ForEach-Object { $_.id }
    $dupIds = $ids | Group-Object | Where-Object Count -gt 1
    if ($dupIds) { $errors += "Дублирующиеся id: $($dupIds.Name -join ', ')" }

    $hostnames = $inv.vms | ForEach-Object { $_.hostname }
    $dupHost = $hostnames | Group-Object | Where-Object Count -gt 1
    if ($dupHost) { $errors += "Дублирующиеся hostname: $($dupHost.Name -join ', ')" }

    $configDirs = $inv.vms | ForEach-Object { $_.agents } | ForEach-Object { $_.config_dir }
    $dupCfg = $configDirs | Group-Object | Where-Object Count -gt 1
    if ($dupCfg) { $errors += "Дублирующиеся config_dir по парку: $($dupCfg.Name -join ', ')" }

    foreach ($vm in $inv.vms) {
        if (-not (Test-Path $vm.vmx)) { $errors += "$($vm.id): .vmx не найден по пути $($vm.vmx)" }
        if ($vm.vmx -notmatch [regex]::Escape("$VmxRoot\")) {
            $errors += "$($vm.id): .vmx вне $VmxRoot — нарушение соглашения о хранении (см. `$VmxRoot в конфиге)"
        }
    }

    $totalMem = ($inv.vms | Measure-Object -Property memsize -Sum).Sum
    Write-Log "Суммарный memsize по парку: $totalMem МБ (справочно, бюджет — по факту свободной ОЗУ при up)"

    # Монтирование: буквы уникальны по парку и не заняты на хосте чужим устройством,
    # remote_path относительный, inbox_dir внутри него.
    $seenLetters = @()
    foreach ($vm in $inv.vms) {
        $errors += Test-MountEntry -Vm $vm -UsedLetters $seenLetters
        $letter = $vm.host.mount_letter
        if ($letter -and $letter -match '^[A-Za-z]$') {
            $up = $letter.ToUpper()
            $seenLetters += $up
            $drive = Get-PSDrive -Name $up -PSProvider FileSystem -ErrorAction SilentlyContinue
            if ($drive) {
                $ours = Get-MountUncPath -User $SshUser -HostName $vm.hostname -RemotePath $vm.host.remote_path
                if ($drive.DisplayRoot -ne $ours) {
                    $errors += "$($vm.id): буква $up занята на хосте ($($drive.DisplayRoot ?? 'локальный диск')), а не нашим монтированием"
                }
            }
        }
    }

    if ($errors.Count -eq 0) {
        Write-Log "validate: OK, $($inv.vms.Count) машин(а) в инвентаре"
        return $true
    } else {
        $errors | ForEach-Object { Write-Log "validate: ОШИБКА — $_" }
        return $false
    }
}

# ---------------------------------------------------------------------------
# up / down — старт/стоп с ограничением MAX_CONCURRENT и замером свободной ОЗУ
# ---------------------------------------------------------------------------
function Wait-VmReady {
    param($Vmx, [int]$TimeoutSec = 120)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ip = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $res = Invoke-Vmrun getGuestIPAddress $Vmx -wait
        if ($res.Code -eq 0 -and $res.Output -match '\d+\.\d+\.\d+\.\d+') {
            $ip = ($res.Output -join ' ').Trim()
            break
        }
        Start-Sleep -Seconds 3
    }
    if (-not $ip) { return $null }

    # Готовность — не факт включения: SSH должен ответить
    $sshOk = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $test = Test-NetConnection -ComputerName $ip -Port 22 -WarningAction SilentlyContinue
        if ($test.TcpTestSucceeded) { $sshOk = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $sshOk) { return $null }
    return $ip
}

function Invoke-Up {
    param([string]$OnlyId, [string]$GroupName)
    $inv = Get-Inventory
    $targets = @($inv.vms)
    if ($OnlyId) { $targets = @($targets | Where-Object { $_.id -eq $OnlyId }) }
    if ($GroupName) { $targets = @($targets | Where-Object { $_.profile -eq $GroupName }) }
    if (-not $targets) { throw "Нет машин, подходящих под фильтр" }
    if ($targets.Count -gt $MaxConcurrent) {
        throw "Запрошено $($targets.Count) машин, MAX_CONCURRENT=$MaxConcurrent — отказ, не предупреждение"
    }

    foreach ($vm in $targets) {
        $free = Get-FreeHostMemMB
        if ($free -lt $MinFreeMemMB) {
            throw "Свободно $free МБ (< $MinFreeMemMB) — остановлен запуск перед '$($vm.id)'"
        }
        Write-Log "up: $($vm.id) — старт (свободно на хосте: $free МБ)"
        $r = Invoke-Vmrun start $vm.vmx nogui
        if ($r.Code -ne 0) { Write-Log "up: $($vm.id) — ОШИБКА старта: $($r.Output)"; continue }
        $ip = Wait-VmReady -Vmx $vm.vmx
        if (-not $ip) { Write-Log "up: $($vm.id) — не дождались готовности (IP/SSH)"; continue }
        Write-Log "up: $($vm.id) — готова, IP=$ip"
    }
}

function Invoke-Down {
    param([string]$OnlyId)
    $inv = Get-Inventory
    $targets = @($inv.vms)
    if ($OnlyId) { $targets = @($targets | Where-Object { $_.id -eq $OnlyId }) }
    foreach ($vm in $targets) {
        # Размонтировать ДО выключения: выключение ВМ с живым монтированием оставляет зависший
        # дескриптор, который снимается только перезапуском проводника.
        if ($vm.host.mount_letter) { Invoke-Unmount -VmId $vm.id }
        Write-Log "down: $($vm.id) — soft stop"
        $r = Invoke-Vmrun stop $vm.vmx soft
        if ($r.Code -ne 0) {
            Write-Log "down: $($vm.id) — soft не сработал, hard stop"
            Invoke-Vmrun stop $vm.vmx hard | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# status / health
# ---------------------------------------------------------------------------
function Invoke-Status {
    $inv = Get-Inventory
    $running = (Invoke-Vmrun list).Output -join "`n"
    $free = Get-FreeHostMemMB
    $totalUsedByVms = 0
    $details = @()

    $rows = foreach ($vm in $inv.vms) {
        $isUp = $running -match [regex]::Escape($vm.vmx)
        $tmuxInfo = "-"
        if ($isUp -and -not $vm.network.ip) {
            $tmuxInfo = "нет IP в инвентаре (golden-шаблон?)"
        } elseif ($isUp) {
            try {
                $panes = ssh @SshBaseOpts -o ConnectTimeout=3 -o BatchMode=yes "$SshUser@$($vm.network.ip)" `
                    "tmux list-panes -t agents 2>/dev/null | wc -l" 2>$null
                $tmuxInfo = if ($panes) { "$panes панелей" } else { "нет сессии" }
            } catch { $tmuxInfo = "ssh недоступен" }
        }

        $ramMb = "-"
        if ($isUp) {
            $usage = Get-VmHostMemoryUsageMB -VmxPath $vm.vmx
            if ($null -ne $usage) { $ramMb = $usage; $totalUsedByVms += $usage }
        }

        [PSCustomObject]@{
            Id         = $vm.id
            Power      = if ($isUp) { "on" } else { "off" }
            "RAM (MB)" = $ramMb
            IP         = $vm.network.ip
            Tmux       = $tmuxInfo
        }

        # Отдельный блок ниже таблицы, не колонки — длинные ssh-команды в узком терминале
        # переносятся и визуально сливаются с соседней колонкой.
        $details += [PSCustomObject]@{
            Id       = $vm.id
            Power    = if ($isUp) { ".\vmfleet.ps1 down -Only $($vm.id)" } else { ".\vmfleet.ps1 up -Only $($vm.id)" }
            Machine  = "ssh $($vm.id)"
            Agents   = "ssh $($vm.id) -t 'tmux attach -t agents'"
            # Не форсировать команду через -t — обычный логин-шелл, инструмент запускается
            # руками (баннер при логине подсказывает список). Форсированный "-t 'cd ... &&
            # devpanel'" рвёт соединение сразу по выходу из devpanel и не даёт обычный шелл
            # для остального (mc, git) в той же вкладке.
            Devpanel = "ssh $($vm.id)  # затем: cd ~/workspace/project && devpanel"
        }
    }
    Write-Host (ConvertTo-MarkdownTable $rows)

    # Машины, реально включённые (по vmrun list), но отсутствующие в inventory.yaml — иначе
    # невидимы в status целиком, хотя занимают ОЗУ хоста и влияют на то, кого можно/нельзя гасить.
    $trackedVmx = @($inv.vms | ForEach-Object { $_.vmx })
    $runningVmxPaths = @(($running -split "`n") | Where-Object { $_ -match '\.vmx$' })
    $untracked = @($runningVmxPaths | Where-Object { $_ -notin $trackedVmx })
    $totalUntrackedRam = 0
    if ($untracked) {
        Write-Host "`nВключены, но НЕ в inventory.yaml (не под управлением vmfleet):"
        foreach ($vmxPath in $untracked) {
            $usage = Get-VmHostMemoryUsageMB -VmxPath $vmxPath
            $ramText = "? MB"
            if ($null -ne $usage) { $ramText = "$usage MB"; $totalUntrackedRam += $usage }
            Write-Host "  $vmxPath — $ramText"
        }
    }

    Write-Host "`n**Host RAM**: free $free MB | used by tracked VMs $totalUsedByVms MB | used by untracked VMs $totalUntrackedRam MB`n"
    Write-Host "**Connect:**`n"
    Write-Host (ConvertTo-MarkdownTable $details)
}

function Invoke-Health {
    param([string]$OnlyId)
    $inv = Get-Inventory
    $targets = @($inv.vms)
    if ($OnlyId) { $targets = @($targets | Where-Object { $_.id -eq $OnlyId }) }
    foreach ($vm in $targets) {
        if (-not $vm.network.ip) { Write-Host "$($vm.id): без статического IP — health пропущен (golden-шаблон?)"; continue }
        Write-Host "=== $($vm.id) ($($vm.network.ip)) ==="
        # Одна строка через ";", не here-string — файл может оказаться в CRLF после git
        # checkout/reset на Windows, тогда построчный \r ломает вывод на госте.
        $script = 'echo "node:  $(node -v 2>/dev/null || echo НЕТ)"; ' +
            'echo "claude: $($HOME/.npm-global/bin/claude --version 2>/dev/null || claude --version 2>/dev/null || echo НЕТ)"; ' +
            'echo "gh:    $(gh --version 2>/dev/null | head -1 || echo НЕТ)"; ' +
            'echo "git:   $(git --version 2>/dev/null || echo НЕТ)"; ' +
            'echo "panes: $(tmux list-panes -t agents 2>/dev/null | wc -l)"; ' +
            'echo "free:  $(free -m | awk ''/Mem:/ {print $3"/"$2" МБ"}'')"; ' +
            'echo "xorg:  $(pgrep Xorg >/dev/null && echo НАЙДЕН-ОШИБКА || echo отсутствует-ок)"'
        ssh @SshBaseOpts -o ConnectTimeout=5 "$SshUser@$($vm.network.ip)" $script
    }
}

# ---------------------------------------------------------------------------
# ssh-config — генерация %USERPROFILE%\.ssh\config из инвентаря
# ---------------------------------------------------------------------------
function Invoke-SshConfig {
    $inv = Get-Inventory
    $sshConfigPath = "$env:USERPROFILE\.ssh\config"
    $begin = "# BEGIN vmfleet"
    $end = "# END vmfleet"
    $block = New-Object System.Collections.Generic.List[string]
    $block.Add($begin)
    foreach ($vm in $inv.vms) {
        if (-not $vm.network.ip) { continue }
        $block.Add("Host $($vm.id)")
        $block.Add("    HostName $($vm.network.ip)")
        $block.Add("    User $SshUser")
        $block.Add("    IdentityFile $SshOwnerKey")
        # StrictHostKeyChecking accept-new — та же настройка, что уже стоит в $SshBaseOpts для
        # внутренних вызовов самого оркестратора. Без неё пользовательский ssh-config спотыкается
        # о смену host-ключа каждый раз, когда IP переиспользуется другой машиной (DHCP/повторный
        # clone) — оркестратор этой проблемы не имел, а сгенерированный для человека конфиг имел,
        # потому что настройка не была перенесена сюда.
        $block.Add("    StrictHostKeyChecking accept-new")
        $block.Add("")
    }
    $block.Add($end)

    $existing = if (Test-Path $sshConfigPath) { Get-Content $sshConfigPath -Raw } else { "" }
    Copy-Item $sshConfigPath "$sshConfigPath.bak" -ErrorAction SilentlyContinue
    $pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))"
    $newBlock = $block -join "`n"
    if ($existing -match $pattern) {
        $updated = $existing -replace $pattern, $newBlock
    } else {
        $updated = $existing.TrimEnd() + "`n`n" + $newBlock + "`n"
    }
    Set-Content -Path $sshConfigPath -Value $updated -NoNewline
    $withIp = @($inv.vms | Where-Object { $_.network.ip })
    Write-Log "ssh-config: обновлён $sshConfigPath ($($withIp.Count) записей)"
}

# ---------------------------------------------------------------------------
# hosts-file — генерация блока в системном hosts из инвентаря
# ---------------------------------------------------------------------------
function Invoke-HostsFile {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "hosts-file требует прав администратора — запустить pwsh 'Запуск от имени администратора'. Тихого пропуска нет."
    }

    $inv = Get-Inventory
    $begin = "# BEGIN vmfleet"
    $end = "# END vmfleet"
    $block = New-Object System.Collections.Generic.List[string]
    $block.Add($begin)
    foreach ($vm in $inv.vms) {
        if (-not $vm.network.ip -or -not $vm.network.hostname) { continue }
        $block.Add("$($vm.network.ip)`t$($vm.network.hostname)")
    }
    $block.Add($end)

    Copy-Item $hostsPath "$hostsPath.vmfleet-backup" -Force
    $existing = Get-Content $hostsPath -Raw
    $pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))"
    $newBlock = $block -join "`n"
    $updated = if ($existing -match $pattern) { $existing -replace $pattern, $newBlock }
               else { $existing.TrimEnd() + "`n`n" + $newBlock + "`n" }
    Set-Content -Path $hostsPath -Value $updated -NoNewline -Encoding ascii
    & ipconfig /flushdns | Out-Null
    Write-Log "hosts-file: обновлён $hostsPath, DNS-кэш сброшен"
}

# ---------------------------------------------------------------------------
# shell-open / shell-close — отдельное окно tmux (индекс 1, "shell") с чистым shell рядом с
# "agents", открывается/закрывается через сам оркестратор, а не ручным Ctrl+B c (не полагаемся
# на прокидку клавиш терминалом — на некоторых терминалах физическое нажатие не доходит).
# ---------------------------------------------------------------------------
function Invoke-ShellOpen {
    param([string]$VmId)
    $inv = Get-Inventory
    Get-VmEntry $inv $VmId | Out-Null   # бросит понятную ошибку, если id нет в инвентаре

    $existing = ssh @SshBaseOpts $VmId "tmux list-windows -t agents -F '#{window_index}' 2>/dev/null"
    if ($existing -contains "1") {
        Write-Host "shell-open: окно 'shell' (индекс 1) на '$VmId' уже открыто"
    } else {
        ssh @SshBaseOpts $VmId "tmux new-window -t agents:1 -n shell" | Out-Null
        Write-Log "shell-open: $VmId — окно 'shell' (индекс 1) создано"
    }
    ssh @SshBaseOpts $VmId "tmux select-window -t agents:1" | Out-Null
    Write-Host "Подключиться: ssh $VmId -t 'tmux attach -t agents'   # окно shell уже выбрано активным"
}

function Invoke-ShellClose {
    param([string]$VmId)
    $inv = Get-Inventory
    Get-VmEntry $inv $VmId | Out-Null
    ssh @SshBaseOpts $VmId "tmux select-window -t agents:0 2>/dev/null; tmux kill-window -t agents:1 2>/dev/null" | Out-Null
    Write-Log "shell-close: $VmId — окно 'shell' (индекс 1) закрыто (если было открыто), agents.0/agents.1 не затронуты"
}

# ---------------------------------------------------------------------------
# mount / unmount / mounts — монтирование рабочих каталогов гостей на буквы дисков хоста.
# Разбор решения — docs/decisions/mounts.md.
# ---------------------------------------------------------------------------
function Assert-MountPrereq {
    # Внятное сообщение вместо ошибки net use (внятно, а не ошибкой net use).
    $missing = Get-MountPrereqMissing
    if ($missing.Count -gt 0) {
        throw "Не установлено: $($missing -join ', '). SSHFS-монтирование без них не работает. " +
              "Поставить: WinFsp (github.com/winfsp/winfsp/releases), затем SSHFS-Win " +
              "(github.com/winfsp/sshfs-win/releases). Оба — инсталляторы с UAC, нужен человек."
    }
}

function Set-MountLabel {
    # Подпись сетевого диска в проводнике — только через реестр: label работает с томами.
    param([string]$UncPath, [string]$Label)
    $key = Join-Path $MountLabelRegRoot (ConvertTo-MountPointKey -UncPath $UncPath)
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name '_LabelFromReg' -Value $Label
}

function Remove-MountLabel {
    param([string]$UncPath)
    $key = Join-Path $MountLabelRegRoot (ConvertTo-MountPointKey -UncPath $UncPath)
    if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-RunningVmxList {
    # Один вызов vmrun на команду, а не по вызову на машину — иначе лог забивается повторами.
    $r = Invoke-Vmrun list
    return ($r.Output -join "`n")
}

function Test-VmPoweredOn {
    param($Vm, [string]$RunningList)
    if (-not $PSBoundParameters.ContainsKey('RunningList')) { $RunningList = Get-RunningVmxList }
    return ($RunningList -match [regex]::Escape($Vm.vmx))
}

function Set-GuestInbox {
    # Готовит каталог обмена на госте : сам каталог, правило игнорирования по
    # полю инвентаря (не угадывая), и блок про screenshots/ в CLAUDE.md проекта. Идемпотентно.
    param(
        [string]$IpOrHost,
        [string]$RemotePath = 'workspace/project',
        [string]$InboxDir = 'screenshots',
        [bool]$OwnRepo = $true
    )
    if (-not $InboxDir) { return }
    $proj = "`$HOME/$($RemotePath.Trim('/'))"
    $ignoreTarget = if ($OwnRepo) { "$proj/.gitignore" } else { "$proj/.git/info/exclude" }

    # mkdir + .gitkeep + строка игнорирования, если её там ещё нет.
    $script = @"
set -e
mkdir -p '$proj/$InboxDir'
touch '$proj/$InboxDir/.gitkeep'
if [ -d '$proj/.git' ]; then
  mkdir -p "`$(dirname '$ignoreTarget')"
  touch '$ignoreTarget'
  grep -qxF '$InboxDir/' '$ignoreTarget' || echo '$InboxDir/' >> '$ignoreTarget'
  echo "IGNORE=$ignoreTarget"
else
  echo "IGNORE=нет .git — правило не применялось"
fi
"@
    $res = ssh @SshBaseOpts "$SshUser@$IpOrHost" $script 2>&1
    Write-Log "inbox: $IpOrHost — каталог '$InboxDir' готов; $($res -join ' ')"

    # Блок в CLAUDE.md проекта — дописываем, если его там нет. Не коммитим: это чужой репозиторий,
    # коммит делает инженер проекта (docs/decisions/mounts.md).
    $blockPath = Join-Path $Root "canon\project-screenshots-block.md"
    if (Test-Path $blockPath) {
        $block = (Get-Content $blockPath -Raw) -replace "`r`n", "`n"
        $marker = '## Каталог screenshots/'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($block))
        $appendScript = @"
if [ -f '$proj/CLAUDE.md' ]; then
  if grep -qF '$marker' '$proj/CLAUDE.md'; then
    echo 'CLAUDE_MD=блок уже есть'
  else
    printf '\n' >> '$proj/CLAUDE.md'
    echo '$b64' | base64 -d >> '$proj/CLAUDE.md'
    echo 'CLAUDE_MD=блок дописан (НЕ закоммичен — коммит за инженером проекта)'
  fi
else
  echo 'CLAUDE_MD=нет CLAUDE.md в проекте — блок не дописан'
fi
"@
        $r2 = ssh @SshBaseOpts "$SshUser@$IpOrHost" $appendScript 2>&1
        Write-Log "inbox: $IpOrHost — $($r2 -join ' ')"
    }
}

function Invoke-Mount {
    param([string]$VmId)
    Assert-MountPrereq
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId

    $letter = $vm.host.mount_letter
    if (-not $letter) { throw "$VmId — mount_letter не задан в inventory.yaml, монтировать некуда" }
    $entryErrors = Test-MountEntry -Vm $vm
    if ($entryErrors.Count -gt 0) { throw ($entryErrors -join "; ") }

    # Монтируются только включённые машины : диск на выключенную ВМ подвешивает проводник,
    # и оператор решит, что сломался хост.
    if (-not (Test-VmPoweredOn -Vm $vm)) {
        throw "$VmId выключена — монтировать нельзя (диск на выключенную ВМ вешает проводник). Сначала: .\vmfleet.ps1 up -Only $VmId"
    }
    $target = if ($vm.network.hostname) { $vm.network.hostname } else { $vm.network.ip }
    if (-not $target) { throw "$VmId — ни hostname, ни ip в инвентаре, адрес монтирования не собрать" }

    # Каталог обмена готовится здесь же: машины, склонированные до этой фазы, иначе остались бы без
    # него, а отдельная команда ради одного mkdir — лишняя сущность. Идемпотентно.
    $ownRepo = if ($null -ne $vm.github.own_repo) { [bool]$vm.github.own_repo } else { $true }
    Set-GuestInbox -IpOrHost ($vm.network.ip ?? $target) -RemotePath $vm.host.remote_path `
                   -InboxDir $vm.guest.inbox_dir -OwnRepo $ownRepo

    $unc = Get-MountUncPath -User $SshUser -HostName $target -RemotePath $vm.host.remote_path
    $up = $letter.ToUpper()

    $existing = Get-PSDrive -Name $up -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($existing -and $existing.DisplayRoot -eq $unc) {
        Write-Log "mount: $VmId — ${up}: уже смонтирован на $unc, повторно не монтирую"
        return
    }
    if ($existing) { throw "Буква ${up}: занята ($($existing.DisplayRoot)) — освободить или сменить mount_letter в инвентаре" }

    # /persistent:no обязателен : восстановление при входе в Windows произойдёт раньше,
    # чем поднимется ВМ, и проводник повиснет.
    Write-Log "mount: $VmId — net use ${up}: $unc /persistent:no"
    $out = net use "${up}:" $unc /persistent:no 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Монтирование не удалось: $($out -join ' ')" }

    $label = if ($vm.host.mount_label) { $vm.host.mount_label } else { $vm.project }
    if ($label) { Set-MountLabel -UncPath $unc -Label $label }
    Write-Log "mount: $VmId — ${up}: подключён, подпись '$label'"
    Write-Host "${up}: -> $unc   (подпись в проводнике: $label)"
}

function Invoke-Unmount {
    param([string]$VmId)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    $letter = $vm.host.mount_letter
    if (-not $letter) { return }
    $up = $letter.ToUpper()

    $drive = Get-PSDrive -Name $up -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $drive) {
        Write-Log "unmount: $VmId — ${up}: не смонтирован, нечего снимать"
        return
    }
    $unc = $drive.DisplayRoot
    net use "${up}:" /delete /y 2>&1 | Out-Null
    if ($unc) { Remove-MountLabel -UncPath $unc }
    Write-Log "unmount: $VmId — ${up}: снят"
}

function Invoke-Mounts {
    $inv = Get-Inventory
    $missing = Get-MountPrereqMissing
    if ($missing.Count -gt 0) {
        Write-Host "**Предпосылки не установлены:** $($missing -join ', ') — монтирование недоступно, таблица только справочная."
        Write-Host ""
    }

    $rows = @()
    $knownUnc = @()
    $running = Get-RunningVmxList
    foreach ($vm in $inv.vms) {
        $letter = $vm.host.mount_letter
        if (-not $letter) { continue }
        $up = $letter.ToUpper()
        $target = if ($vm.network.hostname) { $vm.network.hostname } else { $vm.network.ip }
        $unc = if ($vm.host.remote_path -and $target) { Get-MountUncPath -User $SshUser -HostName $target -RemotePath $vm.host.remote_path } else { $null }
        if ($unc) { $knownUnc += $unc }

        $drive = Get-PSDrive -Name $up -PSProvider FileSystem -ErrorAction SilentlyContinue
        $powered = Test-VmPoweredOn -Vm $vm -RunningList $running
        $state =
            if (-not $drive)            { if ($powered) { "не смонтирован" } else { "машина выключена" } }
            elseif (-not $powered)      { "ОТВАЛИЛСЯ (машина выключена) — снять: .\vmfleet.ps1 unmount $($vm.id)" }
            elseif ($drive.DisplayRoot -ne $unc) { "чужое монтирование: $($drive.DisplayRoot)" }
            elseif (Test-Path "${up}:\") { "подключён" }
            else                        { "ОТВАЛИЛСЯ (диск не отвечает) — повторить: .\vmfleet.ps1 mount $($vm.id)" }

        $rows += [PSCustomObject]@{
            'Буква'     = "${up}:"
            'Проект'    = if ($vm.host.mount_label) { $vm.host.mount_label } elseif ($vm.project) { $vm.project } else { '-' }
            'Машина'    = $vm.id
            'Путь'      = if ($unc) { $unc } else { '-' }
            'Состояние' = $state
        }
    }

    if ($rows.Count -eq 0) {
        Write-Host "Ни у одной машины парка не задан host.mount_letter — монтировать нечего."
    } else {
        Write-Host (ConvertTo-MarkdownTable $rows)
    }

    # Осиротевшие: сетевой диск на \\sshfs\, которого нет в инвентаре — снимаем .
    foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ($d.DisplayRoot -like '\\sshfs\*' -and $knownUnc -notcontains $d.DisplayRoot) {
            Write-Log "mounts: осиротевшее монтирование $($d.Name): -> $($d.DisplayRoot) — снимаю (нет в инвентаре)"
            net use "$($d.Name):" /delete /y 2>&1 | Out-Null
            Remove-MountLabel -UncPath $d.DisplayRoot
        }
    }
}



# ---------------------------------------------------------------------------
# activate / deactivate — сетевая часть реализована; подъём dev-сервера/монтирование зависит
# от devctl на госте (см. docs/GOLDEN_IMAGE.md), пока минимальная заглушка.
# ---------------------------------------------------------------------------
function Invoke-Activate {
    param([string]$VmId)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    $activeCount = @($inv.vms | Where-Object { $_.host.active -eq $true }).Count
    if ($activeCount -ge $MaxActiveProjects -and -not $vm.host.active) {
        throw "Уже $activeCount активных проектов (лимит $MaxActiveProjects) — деактивировать один перед этим"
    }
    if (-not $vm.network.ip) { throw "$VmId без статического IP — сначала провижининг сети" }

    Write-Log "activate: $VmId — сетевая часть OK, dev-сервер — через devctl на госте"
    Write-Host "Открыть вручную: http://$($vm.network.hostname):3000 (после ssh $VmId 'devctl start')"

    # Монтирование — необязательное удобство: его отсутствие не должно валить activate целиком
    # (docs/decisions/mounts.md). Предпосылки проверяются мягко, с сообщением.
    if ($vm.host.mount_letter) {
        $missing = Get-MountPrereqMissing
        if ($missing.Count -gt 0) {
            Write-Host "Диск не смонтирован: не установлено $($missing -join ', ') — см. .\vmfleet.ps1 mounts"
        } else {
            Invoke-Mount -VmId $VmId
        }
    }
}

function Invoke-Deactivate {
    param([string]$VmId)
    Invoke-Unmount -VmId $VmId
    Write-Log "deactivate: $VmId — размонтирован; dev-сервер — через devctl на госте, не реализовано здесь"
}

# ---------------------------------------------------------------------------
# snapshot / revert
# ---------------------------------------------------------------------------
function Invoke-Snapshot {
    param([string]$VmId, [string]$Name)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    $r = Invoke-Vmrun snapshot $vm.vmx $Name
    if ($r.Code -ne 0) { throw "Снапшот не создан: $($r.Output)" }
    Write-Log "snapshot: $VmId -> '$Name' создан"
}

function Invoke-Revert {
    param([string]$VmId, [string]$Name)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    $r = Invoke-Vmrun revertToSnapshot $vm.vmx $Name
    if ($r.Code -ne 0) { throw "Откат не выполнен: $($r.Output)" }
    Write-Log "revert: $VmId -> '$Name' выполнен"
}

# ---------------------------------------------------------------------------
# clone — главная команда: golden-образ -> новая проектная машина, деобезличенная, с ролями и
# кодом проекта на месте.
# ---------------------------------------------------------------------------
function Invoke-Clone {
    param([string]$NewId, [string]$RepoUrl, [string]$DeployKeyPath)
    if (-not $RepoUrl) { throw "clone требует -Repo <url> — провижининг проекта делает оркестратор, не агент реактивно" }
    $inv = Get-Inventory
    $golden = Get-VmEntry $inv "cli-golden"
    $newVmxDir = Join-Path $VmxRoot $NewId
    $newVmx = Join-Path $newVmxDir "$NewId.vmx"

    Write-Log "clone: $NewId <- cli-golden, репозиторий $RepoUrl"
    $r = Invoke-Vmrun clone $golden.vmx $newVmx full "-cloneName=$NewId"
    if ($r.Code -ne 0) { throw "Клонирование не удалось: $($r.Output)" }

    Write-Log "clone: правка .vmx — обезличивание MAC"
    (Get-Content $newVmx) | Where-Object { $_ -notmatch 'ethernet0\.(generatedAddress|generatedAddressOffset)' } |
        Set-Content $newVmx

    Invoke-Vmrun start $newVmx nogui | Out-Null
    $ip = Wait-VmReady -Vmx $newVmx -TimeoutSec 180
    if (-not $ip) { throw "Клон не поднялся (IP/SSH) — вручную проверить $newVmx" }

    # IP мог раньше принадлежать другой машине (DHCP переиспользует адреса) — старая запись
    # known_hosts не совпадёт с ключом, унаследованным клоном от cli-golden. Убрать ДО первого
    # подключения, не после — иначе именно это первое подключение и упадёт.
    ssh-keygen -R $ip 2>$null | Out-Null

    Write-Log "clone: $NewId — переобезличивание SSH host-ключей (унаследованы от cli-golden побайтово, как MAC до правки .vmx)"
    ssh @SshBaseOpts "$SshUser@$ip" "sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart ssh" | Out-Null
    # Ключ гостя только что изменился — снова убрать запись (accept-new её примет заново на
    # следующем подключении, но явный сброс здесь надёжнее, чем полагаться на восстановление связи
    # после systemctl restart ssh в той же ssh-сессии).
    ssh-keygen -R $ip 2>$null | Out-Null
    Start-Sleep -Seconds 2

    # Клон иначе наследует hostname "cli-golden" буквально — start-agents.sh строит
    # CLAUDE_CONFIG_DIR из $(hostname), поэтому без переименования все клоны получали бы
    # ОДИНАКОВЫЕ имена конфиг-каталогов.
    Write-Log "clone: $NewId — переименование hostname (было унаследовано как cli-golden)"
    ssh @SshBaseOpts "$SshUser@$ip" "sudo hostnamectl set-hostname $NewId" | Out-Null

    # start-agents.sh уже отработал через systemd при самой первой загрузке — ДО этого переименования
    # (автостарт срабатывает на старте гостя, раньше, чем сюда доходит SSH-команда) — значит панели
    # уже создались со СТАРЫМ именем (claude-cli-golden-*) в CLAUDE_CONFIG_DIR. Переименовать
    # каталоги на новое имя и поднять панели заново, иначе агенты навсегда останутся привязаны к
    # чужому имени хоста.
    Write-Log "clone: $NewId — панели уже были подняты автостартом со старым именем, переношу конфиг-каталоги и поднимаю заново"
    $renameConfigDirs = "tmux kill-session -t agents 2>/dev/null; " +
        "mv ~/.config/claude-cli-golden-engineer ~/.config/claude-$NewId-engineer 2>/dev/null; " +
        "mv ~/.config/claude-cli-golden-bureau ~/.config/claude-$NewId-bureau 2>/dev/null; true"
    ssh @SshBaseOpts "$SshUser@$ip" $renameConfigDirs | Out-Null

    Write-Log "clone: $NewId готов на $ip — манифест ролей + клонирование проекта"
    # Не пайпить многострочную строку в ssh — PowerShell вставляет \r при передаче в stdin внешнего
    # процесса, ломает bash `source` на госте (`$'\r': command not found`). echo построчно — надёжно.
    ssh @SshBaseOpts "$SshUser@$ip" "echo PANE0_ROLE=engineer > ~/.vmfleet-roles.env; echo PANE1_ROLE=bureau >> ~/.vmfleet-roles.env"

    if ($DeployKeyPath) {
        if (-not (Test-Path $DeployKeyPath)) { throw "Deploy-ключ не найден: $DeployKeyPath" }
        Write-Log "clone: $NewId — установка deploy-ключа для приватного репозитория"
        scp @SshBaseOpts $DeployKeyPath "${SshUser}@${ip}:/tmp/deploy_key" | Out-Null
        # Не heredoc/here-string — файл vmfleet.ps1 на диске может оказаться в CRLF (git autocrlf
        # на Windows конвертирует при каждом checkout/reset, не только при явной правке), тогда
        # многострочный блок несёт \r построчно и ломает bash на госте ("$'\r': command not found",
        # "chmod: cannot access '...\r'"). Одна строка, `;` вместо переносов, без heredoc-
        # терминатора — нечему ломаться от EOL исходного файла.
        $deployKeySetup = 'mkdir -p ~/.ssh && chmod 700 ~/.ssh; ' +
            'mv /tmp/deploy_key ~/.ssh/project_deploy_key; chmod 600 ~/.ssh/project_deploy_key; ' +
            'ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null; ' +
            'grep -q "Host github.com" ~/.ssh/config 2>/dev/null || printf "%s\n" "Host github.com" "    IdentityFile ~/.ssh/project_deploy_key" "    IdentitiesOnly yes" >> ~/.ssh/config; ' +
            'chmod 600 ~/.ssh/config'
        ssh @SshBaseOpts "$SshUser@$ip" $deployKeySetup | Out-Null
    }

    $cloneResult = ssh @SshBaseOpts "$SshUser@$ip" "rm -rf ~/workspace/project && git clone '$RepoUrl' ~/workspace/project 2>&1; echo EXIT=`$?"
    if (($cloneResult -join "`n") -notmatch 'EXIT=0') {
        throw "git clone провалился на $NewId (${ip}): $($cloneResult -join ' | ')"
    }
    $remoteHead = (ssh @SshBaseOpts "$SshUser@$ip" "git -C ~/workspace/project rev-parse --short HEAD").Trim()

    # Каталог обмена с оператором — до первого запуска панелей, чтобы агент видел его сразу и читал
    # блок про screenshots/ из CLAUDE.md проекта.
    Set-GuestInbox -IpOrHost $ip

    ssh @SshBaseOpts "$SshUser@$ip" "~/start-agents.sh"
    Write-Log "clone: $NewId — панели агентов запущены поверх склонированного проекта"

    $suggestedStaticIp = Get-NextFreeStaticIp
    $panes = ssh @SshBaseOpts "$SshUser@$ip" "tmux list-panes -t agents 2>/dev/null | wc -l"

    $localRepoPath = Get-LocalRepoPath -RepoUrl $RepoUrl
    $browserProfile = Get-NextFreeBrowserProfile
    New-ProjectBrowserShortcut -LocalRepoPath $localRepoPath -ProfileDir $browserProfile

    Write-Host ""
    Write-Host "=== Отчёт о развёртывании: $NewId ===" -ForegroundColor Cyan
    Write-Host "Источник:         cli-golden, снапшот (см. docs/GOLDEN_IMAGE.md за актуальным именем)"
    Write-Host "MAC/hostname:     обезличены (было cli-golden -> $NewId)"
    Write-Host "SSH host-ключи:   перегенерированы"
    Write-Host "IP (DHCP):        $ip — статический не назначен"
    Write-Host "Роли:             agents.0=инженер, agents.1=бюро (~/.vmfleet-roles.env), панелей поднято: $panes"
    Write-Host "Репозиторий:      $RepoUrl -> ~/workspace/project, HEAD $remoteHead"
    Write-Host "Ярлык браузера:   $browserProfile -> $localRepoPath\open-in-browser.lnk $(if (-not (Test-Path $localRepoPath)) { '(НЕ создан — локального клона нет по этому пути)' })"
    Write-Host "Вход (интерактивно, не сделан оркестратором):"
    Write-Host "  - Claude Code на agents.0/agents.1 — 'claude' в панели, код входа вставить в браузере"
    Write-Host "  - gh auth login --web — если нужны issues/PR от имени агента (git push/pull уже работает через deploy-ключ)"
    Write-Host ""
    Write-Host "Дальше — статический IP (следующий свободный: $suggestedStaticIp, диапазон $StaticIpBase$StaticIpRangeStart-$StaticIpRangeEnd):"
    Write-Host "  ssh $NewId `"sed 's/__STATIC_IP__/$suggestedStaticIp/' ~/net-template/01-static.yaml.template | sudo tee /etc/netplan/01-static.yaml && sudo chmod 600 /etc/netplan/01-static.yaml && sudo netplan apply`""
    Write-Host "После — вписать network.ip/hostname И host.browser_profile=$browserProfile в inventory.yaml, выполнить 'vmfleet ssh-config'/'vmfleet hosts-file'."
}

function Invoke-CheckSync {
    param([string]$VmId, [string]$LocalRepoPath)
    if (-not $LocalRepoPath) { throw "check-sync требует -LocalPath <путь к локальному клону>" }
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    if (-not $vm.network.ip) { throw "$VmId без IP — check-sync невозможен" }

    $localHead = (git -C $LocalRepoPath rev-parse HEAD).Trim()
    $remoteHead = (ssh @SshBaseOpts "$SshUser@$($vm.network.ip)" "git -C ~/workspace/project rev-parse HEAD").Trim()

    if ($localHead -eq $remoteHead) {
        Write-Log "check-sync: $VmId — совпадает ($localHead)"
        Write-Host "OK: $localHead" -ForegroundColor Green
    } else {
        Write-Log "check-sync: $VmId — РАСХОЖДЕНИЕ локально=$localHead vm=$remoteHead"
        Write-Host "РАСХОЖДЕНИЕ: локально=$localHead, VM=$remoteHead" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# vmfleet dev-* — управление dev-сервером через devctl на госте (см. docs/GOLDEN_IMAGE.md).
# Названы через дефис (не подкоманда "dev start"), для единообразия с ssh-config/hosts-file.
# ---------------------------------------------------------------------------
$MaxDevServers = 2   # не более двух одновременно работающих dev-серверов по парку

function Get-DevStatus {
    param($Vm)
    if (-not $Vm.network.ip) { return $null }
    $json = ssh @SshBaseOpts -o ConnectTimeout=5 "$SshUser@$($Vm.network.ip)" "~/bin/devctl status" 2>$null
    if (-not $json) { return $null }
    try { return $json | ConvertFrom-Json } catch { return $null }
}

# Порты, которые devctl/проект обычно занимает сами по себе (не "чужие", не сигнал тревоги).
$KnownDevPorts = @(22, 3000, 8000)

function Get-PortDiscrepancy {
    # "Сервер запущен в обход devctl" — расхождение выводится как ошибка конфигурации оператору,
    # не автокилл и не диалог с агентом.
    param($Vm)
    if (-not $Vm.network.ip) { return @() }
    # Только 0.0.0.0/[::] (реально доступные с хоста) — loopback-only службы (например,
    # systemd-resolved на 127.0.0.53/54:53) не в счёт, они и так недоступны снаружи гостя.
    $raw = ssh @SshBaseOpts -o ConnectTimeout=5 "$SshUser@$($Vm.network.ip)" `
        "ss -Htln 2>/dev/null | awk '`$4 ~ /^(0\.0\.0\.0|\*|\[::\]):/ {print `$4}' | grep -oE ':[0-9]+`$' | tr -d ':' | sort -un" 2>$null
    if (-not $raw) { return @() }
    $listening = $raw -split "`n" | Where-Object { $_ -match '^\d+$' }
    $devctlPort = $null
    $s = Get-DevStatus -Vm $Vm
    if ($s) { $devctlPort = [string]$s.port }
    $known = @($KnownDevPorts) + @($devctlPort) | Where-Object { $_ }
    return @($listening | Where-Object { $_ -notin $known })
}

function Invoke-DevStart {
    param([string]$VmId, [switch]$OpenBrowser)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    if (-not $vm.network.ip) { throw "$VmId без статического IP — сначала провижининг сети" }

    $running = @($inv.vms | Where-Object { $_.network.ip } | ForEach-Object {
        $s = Get-DevStatus -Vm $_
        if ($s -and $s.running) { $_ }
    })
    $alreadyThis = $running | Where-Object { $_.id -eq $VmId }
    if (-not $alreadyThis -and $running.Count -ge $MaxDevServers) {
        $list = ($running | ForEach-Object {
            $s = Get-DevStatus -Vm $_
            "$($_.id) (idle $($s.idle_seconds)с)"
        }) -join ", "
        throw "Уже $($running.Count) dev-сервера работают: $list — погасите один, оркестратор не вытесняет чужой"
    }

    ssh @SshBaseOpts "$SshUser@$($vm.network.ip)" "~/bin/devctl start" | Write-Host
    Write-Log "dev-start: $VmId"
    if ($OpenBrowser -and $vm.network.hostname) {
        Start-Process "http://$($vm.network.hostname):3000"
    }
}

function Invoke-DevStop {
    param([string]$VmId)
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    if (-not $vm.network.ip) { throw "$VmId без статического IP" }
    ssh @SshBaseOpts "$SshUser@$($vm.network.ip)" "~/bin/devctl stop" | Out-Null
    Write-Log "dev-stop: $VmId"
}

function Invoke-AgentsMdInstall {
    param([string]$VmId, [string]$TokenPath, [string]$Repo)
    if ($VmId -eq "cli-golden") {
        throw "agents-md-install на cli-golden запрещён — токен/библиотека никогда не попадают в образ (docs/DECISIONS.md)"
    }
    if (-not $TokenPath) { throw "agents-md-install требует -Token <путь к файлу с fine-grained PAT>" }
    if (-not (Test-Path $TokenPath)) { throw "Файл токена не найден: $TokenPath" }
    if (-not $Repo) { throw "agents-md-install требует -LibraryRepo <owner/repo> — приватный репозиторий вашей библиотеки эталонных решений" }
    $inv = Get-Inventory
    $vm = Get-VmEntry $inv $VmId
    if (-not $vm.network.ip) { throw "$VmId без статического IP" }
    $ip = $vm.network.ip

    Write-Log "agents-md-install: $VmId — установка read-only доступа к библиотеке ($Repo) через gh"
    scp @SshBaseOpts $TokenPath "${SshUser}@${ip}:/tmp/agents_md_token" | Out-Null
    # Одна строка, не heredoc — тот же CRLF-риск из vmfleet.ps1 на диске, что и у deploy-ключа выше.
    $setup = 'mkdir -p ~/.config/agents-md && chmod 700 ~/.config/agents-md; ' +
        'mv /tmp/agents_md_token ~/.config/agents-md/token; chmod 600 ~/.config/agents-md/token; ' +
        'gh auth login --hostname github.com --with-token < ~/.config/agents-md/token'
    ssh @SshBaseOpts "$SshUser@$ip" $setup | Out-Null

    $check = ssh @SshBaseOpts "$SshUser@$ip" "gh auth status --hostname github.com 2>&1; echo ---; gh api repos/$Repo/contents/README.md --jq '.name' 2>&1"
    Write-Host ($check -join "`n")
    Write-Log "agents-md-install: $VmId — готово"
}

function Invoke-DevStatusAll {
    $inv = Get-Inventory
    $rows = foreach ($vm in @($inv.vms)) {
        if (-not $vm.network.ip) { continue }
        $s = Get-DevStatus -Vm $vm
        $extra = Get-PortDiscrepancy -Vm $vm
        [PSCustomObject]@{
            Id          = $vm.id
            Порт        = if ($s) { $s.port } else { "-" }
            Слушает     = if ($s) { $s.listening } else { "?" }
            Соединения  = if ($s) { $s.established } else { "?" }
            Держатели   = if ($s) { ($s.holders -join ",") } else { "?" }
            Простой_с   = if ($s) { $s.idle_seconds } else { "?" }
            "Вне devctl" = if ($extra) { "⚠ порт(ы) $($extra -join ',') — в обход devctl, проверить вручную" } else { "-" }
        }
    }
    if (-not $rows) { Write-Host "Нет машин со статическим IP для проверки dev-статуса."; return }
    $rows | Format-Table -AutoSize -Wrap
}

function Invoke-DevReap {
    $inv = Get-Inventory
    foreach ($vm in @($inv.vms)) {
        if (-not $vm.network.ip) { continue }
        $s = Get-DevStatus -Vm $vm
        if ($s -and $s.running) {
            Write-Log "dev-reap: принудительная остановка $($vm.id) (простой $($s.idle_seconds)с)"
            ssh @SshBaseOpts "$SshUser@$($vm.network.ip)" "~/bin/devctl stop" | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# dev-watchdog — страхующий контур ХОСТА: опрос раз в минуту (через задачу планировщика,
# install-dev-watchdog-task), гасит по ДВОЙНОМУ grace, если гостевой watchdog не отработал,
# и явно помечает машину как требующую внимания (лог + консоль).
# ---------------------------------------------------------------------------
$GraceSeconds = 600   # должно совпадать с DEVCTL_GRACE_SECONDS на госте

function Invoke-DevWatchdog {
    $inv = Get-Inventory
    $doubleGrace = $GraceSeconds * 2
    foreach ($vm in @($inv.vms)) {
        if (-not $vm.network.ip) { continue }
        $s = Get-DevStatus -Vm $vm
        if ($s -and $s.running -and $s.idle_seconds -gt $doubleGrace) {
            Write-Log "dev-watchdog: $($vm.id) — простой $($s.idle_seconds)с > двойной grace $doubleGrace с. Гостевой watchdog не отработал — гашу с хоста, машина ТРЕБУЕТ ВНИМАНИЯ."
            ssh @SshBaseOpts "$SshUser@$($vm.network.ip)" "~/bin/devctl stop" | Out-Null
        }
    }
}

function Invoke-InstallDevWatchdogTask {
    $taskName = "vmfleet-dev-watchdog"
    $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-NoProfile -File `"$Root\vmfleet.ps1`" dev-watchdog" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "vmfleet: страхующий контур dev-сервера, опрос раз в минуту" -Force | Out-Null
    Write-Log "install-dev-watchdog-task: задача планировщика '$taskName' зарегистрирована (раз в минуту)"
}

# ---------------------------------------------------------------------------
# Диспетчер
# ---------------------------------------------------------------------------
switch ($Command) {
    'validate'   { Invoke-Validate | Out-Null }
    'up'         { Invoke-Up -OnlyId $Only -GroupName $Group }
    'down'       { Invoke-Down -OnlyId $Only }
    'status'     { Invoke-Status }
    'health'     { Invoke-Health -OnlyId $Only }
    'ssh-config' { Invoke-SshConfig }
    'hosts-file' { Invoke-HostsFile }
    'activate'   { Invoke-Activate -VmId $Id }
    'deactivate' { Invoke-Deactivate -VmId $Id }
    'snapshot'   { Invoke-Snapshot -VmId $Id -Name $SnapshotName }
    'revert'     { Invoke-Revert -VmId $Id -Name $SnapshotName }
    'clone'      { Invoke-Clone -NewId $Id -RepoUrl $Repo -DeployKeyPath $DeployKey }
    'check-sync' { Invoke-CheckSync -VmId $Id -LocalRepoPath $LocalPath }
    'dev-start'  { Invoke-DevStart -VmId $Id -OpenBrowser:$Open }
    'dev-stop'   { Invoke-DevStop -VmId $Id }
    'dev-status' { Invoke-DevStatusAll }
    'dev-reap'   { Invoke-DevReap }
    'dev-watchdog' { Invoke-DevWatchdog }
    'install-dev-watchdog-task' { Invoke-InstallDevWatchdogTask }
    'shell-open'   { Invoke-ShellOpen -VmId $Id }
    'shell-close'  { Invoke-ShellClose -VmId $Id }
    'agents-md-install' { Invoke-AgentsMdInstall -VmId $Id -TokenPath $Token -Repo $LibraryRepo }
    'mount'      { Invoke-Mount -VmId $Id }
    'unmount'    { Invoke-Unmount -VmId $Id }
    'mounts'     { Invoke-Mounts }
}
