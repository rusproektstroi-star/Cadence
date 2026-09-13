# Добавить в конец ~/.bashrc на образе (после стандартного содержимого Ubuntu, после строки
# с добавлением ~/.npm-global/bin в PATH). Баннер со списком инструментов образа — только для
# обычного логин-шелла (не внутри tmux, чтобы не спамить в каждой панели agents.0/agents.1).
# Полный список — ~/docs/canon/installed-tools.md

if [ -z "${TMUX:-}" ]; then
  cat <<'BANNER'

Инструменты этого образа (полный список — ~/docs/canon/installed-tools.md):
  devpanel  — таблица dev-серверов проекта (запускать из корня репозитория)
  devctl    — автоматический dev-сервер (аренда/watchdog): status/hold/release
  mc        — файловый менеджер (Midnight Commander)
  gh        — GitHub CLI

BANNER
fi
