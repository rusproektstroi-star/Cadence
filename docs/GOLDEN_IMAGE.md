# Сборка golden-образа (`cli-golden`)

Пошаговый рецепт: как собрать эталонную VM, с которой `vmfleet.ps1 clone` будет штамповать
проектные машины. Готовые файлы — в `golden-image/` в корне репозитория, здесь — куда их класть
и в каком порядке.

## Точка старта

Свежая установка **Ubuntu Server LTS** (24.04+) в VMware Workstation — минимальная, без GUI, без
предустановленных пакетов сверх стандартного набора установщика. Ничего специфичного не
наследуется ниоткуда — это чистый лист, не клон существующей рабочей машины.

Один пользователь (в этом документе — `<VM_USER>`, тот же аккаунт, что потом укажете в блоке
«КОНФИГ» `vmfleet.ps1` как `$SshUser`), с SSH-доступом по ключу.

## 1. Базовые пакеты

```bash
sudo apt-get update
sudo apt-get install -y git tmux jq curl wget micro unzip ca-certificates gpg mc
sudo systemctl set-default multi-user.target   # без графики — она и не нужна
```

## 2. Node.js + Claude Code + GitHub CLI

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

# npm-global префикс — чтобы `npm install -g` не требовал sudo
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.npm-global/bin:$PATH"

npm install -g @anthropic-ai/claude-code

# GitHub CLI — по официальной инструкции cli.github.com для Ubuntu (apt-репозиторий, не snap)
```

**Известная ловушка — автообновление Claude Code может сломать свою же установку под кастомным
префиксом.** `postinstall`-скрипт пакета иногда пропускается `npm` из соображений безопасности
при переустановке — бинарник/симлинк не пересобирается, процесс продолжает работать в памяти со
старой версии до перезапуска панели, а `npm ls -g` показывает пустой список. Отключить
автообновление для каждой роли (после того как заведены `CLAUDE_CONFIG_DIR`, шаг 4):

```bash
echo '{"theme": "dark", "env": {"DISABLE_AUTOUPDATER": "1"}}' > ~/.config/claude-<host>-engineer/settings.json
echo '{"theme": "dark", "env": {"DISABLE_AUTOUPDATER": "1"}}' > ~/.config/claude-<host>-bureau/settings.json
```
Проверить: `claude doctor` должен показать `Auto-updates: disabled`.

## 3. tmux

```bash
cp golden-image/tmux.conf ~/.tmux.conf
```

## 4. Роли и автостарт панелей

```bash
cp golden-image/start-agents.sh ~/start-agents.sh
chmod +x ~/start-agents.sh
mkdir -p ~/workspace/project ~/.config/systemd/user
cp golden-image/systemd/claude-agents.service ~/.config/systemd/user/claude-agents.service
systemctl --user enable --now claude-agents.service
loginctl enable-linger "$USER"   # чтобы юнит поднимался при старте гостя без ручного входа
```

Ролевой канон — `canon/agent-roles/ENGINEER.CLAUDE.md` и `BUREAU.CLAUDE.md` кладутся как
`CLAUDE.md` внутрь `~/.config/claude-<hostname>-engineer/` и `~/.config/claude-<hostname>-bureau/`
соответственно (создать эти каталоги, если их ещё нет). `canon/TABS_AND_ROLES.md` — как
`~/docs/canon/TABS_AND_ROLES.md` (см. §7 ниже — гость не имеет доступа к репозиторию оркестратора,
только к тому, что явно скопировано на образ).

**Проверить, что подняты обе панели:**
```bash
tmux list-panes -t agents -F '#{pane_index} #{pane_current_command}'
```
Ожидается две строки, обе `claude`.

## 5. Жизненный цикл dev-сервера (`devctl`)

```bash
sudo mkdir -p /usr/local/bin
sudo cp golden-image/bin/devctl golden-image/bin/devctl-watchdog /usr/local/bin/
sudo chmod +x /usr/local/bin/devctl /usr/local/bin/devctl-watchdog

mkdir -p ~/.config/systemd/user
cp golden-image/systemd/devctl-watchdog.timer golden-image/systemd/devctl-watchdog.service ~/.config/systemd/user/
systemctl --user enable --now devctl-watchdog.timer
```

**Не устанавливать `~/.devctl.conf` на золотом образе** — `PROJECT_START_CMD`/`PORT` специфичны
для конкретного проекта, задаются при провижининге, не зашиваются в образ.

## 6. `devpanel` + `mc`

```bash
sudo cp golden-image/bin/devpanel /usr/local/bin/devpanel
sudo chmod +x /usr/local/bin/devpanel
```
`mc` уже установлен на шаге 1. Оба доступны голым именем из любого контекста входа (симлинки/
бинарники прямо в `/usr/local/bin/`, не через `~/bin`+`PATH` — см. «Известные ловушки PATH» ниже).

## 7. Обнаруживаемость инструментов — библиотека канона + баннер при логине

```bash
mkdir -p ~/docs/canon
cp golden-image/installed-tools.md.template ~/docs/canon/installed-tools.md   # заполнить версии
cp canon/TABS_AND_ROLES.md ~/docs/canon/TABS_AND_ROLES.md
# при желании — свой dev-lifecycle-tz.md/headless-profile-decision.md рядом, если ведёте такие доки

cat golden-image/bashrc-snippet.sh >> ~/.bashrc
```

Смысл: агент внутри VM не имеет доступа к репозиторию оркестратора на хосте — только к тому, что
явно скопировано на образ. Без этого шага ролевой канон ссылается на файлы, которых на диске нет.

## 8. Сетевой шаблон (не применяется на золотом образе)

```bash
mkdir -p ~/net-template
cp golden-image/net-template/01-static.yaml.template ~/net-template/
```
Плейсхолдеры `__INTERFACE__`/`__STATIC_IP__`/`__GATEWAY__` подставляются оркестратором (или вручную,
см. `docs/OPERATIONS.md` §3) при разводке под конкретный проект — не на golden-образе: адрес
гостя известен только после клонирования.

**Известная ловушка — устаревший конфиг установщика конфликтует с новым статическим.** Ubuntu
Server (subiquity-инсталлятор) сам создаёт `/etc/netplan/00-installer-config.yaml` с DHCP и
`match: macaddress: <MAC на момент установки>`. Этот файл клонируется байт-в-байт на каждый клон
golden-образа, но настоящий MAC у клона уже другой (обезличен оркестратором) — `netplan apply`
падает с `Cannot find unique matching interface for <iface>`, потому что не может сопоставить
старый MAC ни одному реальному интерфейсу. Отключить один раз **на самом golden-образе**, чтобы
не чинить это на каждом клоне заново:

```bash
sudo mv /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.disabled
```

## 9. Обезличивание перед снапшотом

```bash
sudo hostnamectl set-hostname cli-golden
sudo rm -f /etc/ssh/ssh_host_* && sudo ssh-keygen -A && sudo systemctl restart ssh
sudo cat /etc/machine-id   # проверить, не переопределять вручную без причины
```
MAC-адрес обезличивается позже, на стороне оркестратора при каждом клоне (`vmfleet.ps1` правит
`.vmx` файл) — на самом госте делать нечего.

## 10. Чек-лист перед снапшотом — обязательно, особенно если образ может попасть в публичный репозиторий

**Это самый важный шаг документа.** Живые учётные данные внутри снапшота реплицируются на КАЖДЫЙ
клон — включая чужие сессии Claude Code/GitHub, если снапшот случайно сделан после того, как кто-то
тестировал вход прямо на golden-образе.

```bash
# Claude Code — обе роли
rm -rf ~/.config/claude-cli-golden-{engineer,bureau}/{.credentials.json,.claude.json,sessions,cache,backups,telemetry}

# GitHub CLI
gh auth status   # должно быть "not logged in"; если нет — gh auth logout

# SSH — на golden-образе НЕ должно быть deploy-ключей конкретных проектов
ls ~/.ssh/                    # только то, что реально нужно на golden-уровне
cat ~/.ssh/config 2>/dev/null # не должно ссылаться на несуществующие пока repo-ключи

# git identity — не привязывать к личному email на уровне образа
git config --global --list

# История команд — не секрет, но и не для публичного образа
history -c && rm -f ~/.bash_history

# devctl — не должно быть тестовых событий/конфига конкретного проекта
rm -rf ~/.local/state/devctl/* ~/.devctl.conf ~/workspace/project/.dev-events.log

# Рабочий каталог проекта — пустой, не тестовый git-чекаут
rm -rf ~/workspace/project/* ~/workspace/project/.[!.]*  2>/dev/null || true
```

Только после этого:
```bash
vmrun stop <путь-к-vmx> soft
vmrun snapshot <путь-к-vmx> "cli-golden-<дата>"
```

**Если снапшот уже был сделан с живыми данными** — не патчить старый снапшот, удалять и переснимать
заново (снапшоты VMware не редактируются задним числом). Держать один актуальный снапшот, не
накапливать историю «на всякий случай» — устаревшие с чужими данными удалить полностью, не
оставлять «для истории».

## Монтирование рабочего каталога на хост — со стороны образа готовить нечего

SSHFS ходит по обычному SSH: на госте нужна только подсистема `sftp` в `sshd`, а она включена в
Ubuntu из коробки (`Subsystem sftp /usr/lib/openssh/sftp-server` в `/etc/ssh/sshd_config`). Никаких
пакетов, служб и настроек на образ не добавляется — всё нужное стоит на **хосте** (WinFsp +
SSHFS-Win, см. `docs/OPERATIONS.md` §5a).

Каталог обмена (`screenshots/`), правило игнорирования и блок про него в `CLAUDE.md` проекта
создаёт оркестратор — при `clone` и при каждом `mount`, уже на проектной машине. На шаблоне их нет
и быть не должно: на нём нет проекта.

## Что сознательно НЕ ставится на golden-образ

- Статический IP/netplan — адрес известен только при разводке под конкретный проект.
- `~/.devctl.conf` — команда запуска специфична для проекта.
- Deploy-ключи, `gh auth`, любые GitHub-токены (включая доступ к приватным библиотекам решений,
  см. `docs/OPERATIONS.md` §6 — эта команда прямо запрещена на `cli-golden`).
- Сам проектный код — репозиторий клонируется оркестратором в `~/workspace/project` уже на
  проектной машине, не на шаблоне.
