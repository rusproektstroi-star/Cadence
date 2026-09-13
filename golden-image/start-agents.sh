#!/bin/bash
set -euo pipefail

SESSION="agents"
ID="$(hostname)"
PROJECT_DIR="$HOME/workspace/project"
mkdir -p "$PROJECT_DIR"

# Манифест ролей — кладёт оркестратор при разворачивании (vmfleet clone), не выбор скрипта. На
# голом эталоне (нет манифеста) — константа по умолчанию, роли те же самые. Манифест касается
# ТОЛЬКО ролей, не проекта (проект приходит отдельно, через git clone до первого запуска панелей).
ROLES_FILE="$HOME/.vmfleet-roles.env"
if [ -f "$ROLES_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ROLES_FILE"
else
  PANE0_ROLE="engineer"
  PANE1_ROLE="bureau"
fi

CONFIG_DIR_ENGINEER="$HOME/.config/claude-${ID}-engineer"
CONFIG_DIR_BUREAU="$HOME/.config/claude-${ID}-bureau"

# Полный путь к claude, не голое имя команды — панель tmux, поднятая неинтерактивным скриптом
# (systemd-юнит при старте гостя), не обязательно получает PATH из ~/.bashrc (там ранний
# "case $- in ... *) return;;" до строки с npm-global, если шелл не помечен интерактивным). Не
# полагаемся на PATH здесь вообще, вместо починки самого механизма PATH.
CLAUDE_BIN="$HOME/.npm-global/bin/claude"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Сессия $SESSION уже существует"
else
  # agents.0 — ВСЕГДА первой, физически левая панель по порядку создания (позиционная гарантия,
  # не зависит от значения PANE0_ROLE — роль здесь всегда "engineer" по канону, переменные
  # PANE0_ROLE/PANE1_ROLE фиксируют это для текста самопредставления, не переставляют панели местами).
  tmux new-session -d -s "$SESSION" -n agents -c "$PROJECT_DIR"
  tmux send-keys -t "$SESSION:agents.0" \
    "CLAUDE_CONFIG_DIR=\"$CONFIG_DIR_ENGINEER\" \"$CLAUDE_BIN\"" C-m

  # agents.1 — ВСЕГДА второй, физически правая панель (split-window -h кладёт новую панель справа).
  tmux split-window -h -t "$SESSION:agents" -c "$PROJECT_DIR"
  tmux send-keys -t "$SESSION:agents.1" \
    "CLAUDE_CONFIG_DIR=\"$CONFIG_DIR_BUREAU\" \"$CLAUDE_BIN\"" C-m
  tmux select-layout -t "$SESSION:agents" even-horizontal
fi

# Подключаться только при наличии терминала — иначе запуск с хоста по SSH зависнет.
if [ -t 0 ]; then
  tmux attach-session -t "$SESSION"
else
  echo "Сессия $SESSION запущена в фоне"
fi
