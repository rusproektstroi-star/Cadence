<#
  Pester-тесты для vmfleet.ps1 — только "pure" класс: чистая логика (парсинг, форматирование,
  валидация схемы), без vmrun/VMware/реальных VM/сети. Не модифицируют и не dot-source'ят
  оригинальный скрипт целиком (тот требует mandatory -Command и хочет vmrun.exe физически на
  диске) — вместо этого функции извлекаются из его AST по имени и подгружаются изолированно.
  Живые/сетевые проверки — не здесь, см. tests/README.md.

  Запуск: pwsh -NoProfile -Command "Invoke-Pester -Path tests/vmfleet.Tests.ps1"
  Требует модуль Pester (в комплекте с Windows PowerShell/pwsh) и powershell-yaml
  (Install-Module powershell-yaml -Scope CurrentUser) для тестов инвентаря.
#>

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ScriptPath = Join-Path $RepoRoot "vmfleet.ps1"

function Get-FunctionSource {
    # Достаёт ИСХОДНЫЙ ТЕКСТ одного объявления "function Name { ... }" из файла по AST — сам
    # его не определяет (dot-source внутри этой функции остался бы в её локальной области
    # видимости и исчез бы после return). Вызывающий код дот-сорсит текст сам:
    #   . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "Foo")))
    # Так функция появляется в НУЖНОЙ (вызывающей) области видимости, не выполняя ничего из
    # остального файла (param-блок, проверка vmrun.exe, диспетчер switch внизу).
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $funcAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $funcAst) { throw "Функция '$Name' не найдена в $Path" }
    return $funcAst.Extent.Text
}

Describe "vmfleet.ps1 — синтаксис и согласованность команд" {

    It "парсится без синтаксических ошибок" {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count | Should Be 0
    }

    It "каждая команда из ValidateSet есть в диспетчере switch, и наоборот" {
        $raw = Get-Content $ScriptPath -Raw
        $validateSetMatch = [regex]::Match($raw, "ValidateSet\(([^)]+)\)")
        $validateSetMatch.Success | Should Be $true
        $validateSetCmds = [regex]::Matches($validateSetMatch.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object

        $switchBlock = [regex]::Match($raw, "(?s)switch \(\`$Command\) \{(.*?)\n\}")
        $switchBlock.Success | Should Be $true
        $switchCmds = [regex]::Matches($switchBlock.Groups[1].Value, "(?m)^\s*'([^']+)'\s*\{") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object

        Compare-Object $validateSetCmds $switchCmds | Should Be $null
    }
}

Describe "ConvertTo-MarkdownTable" {
    . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "ConvertTo-MarkdownTable")))

    It "пустой массив -> '(пусто)'" {
        ConvertTo-MarkdownTable -Objects @() | Should Be "(пусто)"
    }

    It "одна строка -> корректный markdown (заголовок, разделитель, строка данных)" {
        $obj = [PSCustomObject]@{ Id = "vm1"; Power = "on" }
        $result = ConvertTo-MarkdownTable -Objects @($obj)
        $lines = $result -split "`n"
        $lines[0] | Should Be "| Id | Power |"
        $lines[1] | Should Be "|---|---|"
        $lines[2] | Should Be "| vm1 | on |"
    }

    It "экранирует '|' внутри значения, чтобы не сломать таблицу" {
        $obj = [PSCustomObject]@{ Note = "a|b" }
        $result = ConvertTo-MarkdownTable -Objects @($obj)
        ($result -split "`n")[2] | Should Be "| a\|b |"
    }
}

Describe "Get-LocalRepoPath" {
    . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "Get-LocalRepoPath")))

    It "SSH-форма (git@github.com:org/Name.git) -> Documents\Name" {
        $r = Get-LocalRepoPath -RepoUrl "git@github.com:your-org/YourProject.git"
        (Split-Path $r -Leaf) | Should Be "YourProject"
    }

    It "HTTPS-форма (https://github.com/org/Name.git) -> Documents\Name" {
        $r = Get-LocalRepoPath -RepoUrl "https://github.com/your-org/YourProject.git"
        (Split-Path $r -Leaf) | Should Be "YourProject"
    }

    It "URL без .git на конце тоже работает" {
        $r = Get-LocalRepoPath -RepoUrl "https://github.com/your-org/YourProject"
        (Split-Path $r -Leaf) | Should Be "YourProject"
    }
}

Describe "inventory.yaml.example — схема" {
    $yamlAvailable = [bool](Get-Module -ListAvailable powershell-yaml)

    It "модуль powershell-yaml доступен (иначе остальные тесты этого блока пропущены)" -Skip:(-not $yamlAvailable) {
        $yamlAvailable | Should Be $true
    }

    if ($yamlAvailable) {
        Import-Module powershell-yaml -ErrorAction Stop
        $examplePath = Join-Path $RepoRoot "inventory.yaml.example"
        $inv = ConvertFrom-Yaml (Get-Content $examplePath -Raw)

        It "содержит хотя бы одну запись 'vms'" {
            $inv.vms.Count | Should BeGreaterThan 0
        }

        It "первая запись — golden-шаблон (role: golden-template, network.ip: null)" {
            $golden = $inv.vms | Where-Object { $_.id -eq "cli-golden" }
            $golden | Should Not Be $null
            $golden.role | Should Be "golden-template"
            $golden.network.ip | Should Be $null
        }

        It "каждая запись несёт обе роли агентов (engineer, bureau)" {
            foreach ($vm in $inv.vms) {
                $roles = $vm.agents | ForEach-Object { $_.role } | Sort-Object
                $roles | Should Be @("bureau", "engineer")
            }
        }

        It "id/hostname/config_dir уникальны по всему примеру" {
            $ids = $inv.vms | ForEach-Object { $_.id }
            ($ids | Group-Object | Where-Object Count -gt 1) | Should Be $null
        }
    }
}

Describe "Invoke-Validate — обнаружение ошибок схемы" {
    $yamlAvailable = [bool](Get-Module -ListAvailable powershell-yaml)

    if ($yamlAvailable) {
        Import-Module powershell-yaml -ErrorAction Stop
        . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "Write-Log")))
        . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "Get-Inventory")))
        . ([scriptblock]::Create((Get-FunctionSource -Path $ScriptPath -Name "Invoke-Validate")))

        $TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmfleet-tests-$([guid]::NewGuid())"
        $VmxRoot = Join-Path $TestRoot "vms"
        New-Item -ItemType Directory -Path $VmxRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $VmxRoot "vm1") -Force | Out-Null
        Set-Content -Path (Join-Path $VmxRoot "vm1\vm1.vmx") -Value "config.version = 8"
        $global:LogDir = $TestRoot

        function New-TestInventory {
            param([string]$Yaml)
            $path = Join-Path $TestRoot "inventory.yaml"
            Set-Content -Path $path -Value $Yaml
            return $path
        }

        It "валидный инвентарь (один вход, .vmx внутри VmxRoot) -> без ошибок" {
            $global:InventoryPath = New-TestInventory -Yaml @"
vms:
  - id: vm1
    hostname: vm1
    vmx: $VmxRoot\vm1\vm1.vmx
    memsize: 2048
    agents:
      - {name: engineer, config_dir: /cfg/e1}
      - {name: bureau, config_dir: /cfg/b1}
"@
            $global:VmxRoot = $VmxRoot
            (Invoke-Validate) | Should Be $true
        }

        It "дублирующиеся id -> ошибка (validate возвращает false)" {
            $global:InventoryPath = New-TestInventory -Yaml @"
vms:
  - id: vm1
    hostname: vm1
    vmx: $VmxRoot\vm1\vm1.vmx
    memsize: 2048
    agents:
      - {name: engineer, config_dir: /cfg/e1}
      - {name: bureau, config_dir: /cfg/b1}
  - id: vm1
    hostname: vm2
    vmx: $VmxRoot\vm1\vm1.vmx
    memsize: 2048
    agents:
      - {name: engineer, config_dir: /cfg/e2}
      - {name: bureau, config_dir: /cfg/b2}
"@
            $global:VmxRoot = $VmxRoot
            (Invoke-Validate) | Should Be $false
        }

        It ".vmx вне VmxRoot -> ошибка" {
            $outsidePath = Join-Path $TestRoot "outside.vmx"
            Set-Content -Path $outsidePath -Value "config.version = 8"
            $global:InventoryPath = New-TestInventory -Yaml @"
vms:
  - id: vm1
    hostname: vm1
    vmx: $outsidePath
    memsize: 2048
    agents:
      - {name: engineer, config_dir: /cfg/e1}
      - {name: bureau, config_dir: /cfg/b1}
"@
            $global:VmxRoot = $VmxRoot
            (Invoke-Validate) | Should Be $false
        }

        Remove-Item -Recurse -Force $TestRoot -ErrorAction SilentlyContinue
    }
}
