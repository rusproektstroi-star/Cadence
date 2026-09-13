#!/bin/bash
# Тесты чистой логики devpanel (форматирование, парсинг конфига) — без systemctl/ss, поэтому
# работают и в Git Bash на Windows, и на Linux. Живое поведение (реальный старт/убийство
# процессов, порты) — не здесь, требует настоящей Linux-машины, см. tests/README.md.
#
# Запуск: bash tests/golden-image/devpanel_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVPANEL="$SCRIPT_DIR/../../golden-image/bin/devpanel"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  [+] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [-] $desc"
    echo "      ожидалось: $(printf '%q' "$expected")"
    echo "      получено:  $(printf '%q' "$actual")"
    FAIL=$((FAIL + 1))
  fi
}

echo "devpanel — pad() (ручной паддинг по символам, не по байтам printf %-Ns)"

# pad() — определена внутри devpanel как обычная bash-функция без побочных эффектов (нет
# systemctl/ss внутри неё самой) — извлекаем и подгружаем только её тело, не выполняя остальной
# скрипт (который иначе сразу упадёт без .devpanel/services.conf в текущем каталоге).
eval "$(sed -n '/^pad() {/,/^}/p' "$DEVPANEL")"

assert_eq "латиница паддится пробелами до нужной длины" \
  "ab$(printf '%*s' 3 '')" "$(pad "ab" 5)"

# ${#str} считает СИМВОЛЫ только при multibyte-aware сборке bash в UTF-8-локали (так на целевой
# Ubuntu — подтверждено вживую). Некоторые сборки bash (в частности MSYS2/Git for Windows) считают
# байты независимо от LC_CTYPE — это ограничение самой сборки bash, не то, что чинит pad(). На
# такой сборке тест ниже не даёт сигнала ни за, ни против — пропускаем явно, не отмечаем ложным
# провалом.
if [ "$(echo -n "Имя" | wc -m)" = "3" ]; then
  assert_eq "кириллица (Имя, 3 символа, 6 байт) паддится по СИМВОЛАМ, не по байтам" \
    "Имя$(printf '%*s' 13 '')" "$(pad "Имя" 16)"
else
  echo "  [~] кириллица (Имя, 3 символа) — ПРОПУЩЕНО: эта сборка bash считает \${#str} по байтам" \
       "независимо от локали (проверено: целевая Ubuntu считает верно, см. docs/GOLDEN_IMAGE.md)"
fi

assert_eq "строка длиннее width — не обрезается, не падает" \
  "abcdef" "$(pad "abcdef" 3)"

echo ""
echo "devpanel — load_config() (парсинг .devpanel/services.conf)"

TMP_PROJECT="$(mktemp -d)"
mkdir -p "$TMP_PROJECT/.devpanel"
cat > "$TMP_PROJECT/.devpanel/services.conf" <<'EOF'
# комментарий и пустая строка ниже должны игнорироваться

backend;8010;uvicorn app:main --port 8010;pip install -r requirements.txt;.venv
frontend;5501;python3 dev_server.py 5501;;
EOF

# load_config()/declare -a NAMES... — читаем их тем же приёмом: без запуска остального скрипта.
eval "$(sed -n '/^declare -a NAMES/p; /^load_config() {/,/^}/p' "$DEVPANEL")"
CONFIG="$TMP_PROJECT/.devpanel/services.conf"
load_config

assert_eq "два сервиса распознаны (комментарий/пустая строка пропущены)" "2" "${#NAMES[@]}"
assert_eq "первый сервис — backend" "backend" "${NAMES[0]}"
assert_eq "порт backend — 8010" "8010" "${PORTS[0]}"
assert_eq "второй сервис — frontend, порт 5501" "5501" "${PORTS[1]}"
assert_eq "у frontend нет бутстрапа/маркера (пустые поля конфига)" "" "${BOOTSTRAPS[1]}"

rm -rf "$TMP_PROJECT"

echo ""
echo "Итог: $PASS пройдено, $FAIL провалено"
[ "$FAIL" -eq 0 ]
