// usage-probe.mjs — строка состояния Claude Code для сессий НА ХОСТЕ: оркестратора и любых других.
//
// Тот же смысл, что у golden-image/bin/usage-probe на гостях, но под Windows: там bash и jq, здесь
// ни того, ни другого.
//
//     Opus 5 │ 5ч ████████░░ 81% │ 7д 30% │ контекст 43% сброс через 2ч05м
//     owner@example.com · my-org/my-project
//
// Claude Code запускает это сам и подаёт JSON сессии на stdin: при старте, при каждом ответе
// модели, после /compact и в момент, когда окно лимита достигает resets_at. Опрашивать не нужно.
//
// ПОЧЕМУ NODE, А НЕ POWERSHELL. Скрипт вызывается часто, Claude Code гасит частые вызовы окном в
// 300 мс и ОТМЕНЯЕТ незавершённый запуск при следующем событии — медленная строка просто не
// успевает дорисоваться. Замерено на живом хосте: вариант на PowerShell отрабатывал 772 мс, из них
// 406 мс уходило на один только старт pwsh. Node стартует в разы быстрее и разбирает JSON сам.
// Он же гарантированно есть везде, где стоит Claude Code: тот и сам ставится через npm.
//
// ПРО ~/.claude.json. Читать его целиком нельзя по двум причинам: он весит десятки килобайт, а
// главное — в нём лежат ключи, различающиеся только регистром (два написания одного пути проекта),
// и штатный разбор на них падает. Поэтому почта достаётся точечным выражением и кешируется:
// перечитываем, только если файл стал новее кеша, то есть после повторного входа.
//
// Чего во входном JSON может не быть, и это нормально: rate_limits приходят только подписчикам
// claude.ai Pro и Max и только после первого ответа модели; context_window пуст в начале сессии и
// сразу после /compact; workspace.repo отсутствует, если у каталога нет remote origin. Пустое поле
// показывается прочерком, а не нулём: ноль означал бы «расход нулевой», то есть противоположное
// незнанию.

import { readFileSync, writeFileSync, mkdirSync, statSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const raw = readFileSync(0, 'utf8');
if (!raw.trim()) process.exit(0);

let j;
try { j = JSON.parse(raw); } catch { process.exit(0); }

const stateDir = join(homedir(), '.claude', 'cadence');
try { mkdirSync(stateDir, { recursive: true }); } catch { }

const h5      = j.rate_limits?.five_hour?.used_percentage ?? null;
const h5reset = j.rate_limits?.five_hour?.resets_at ?? null;
const d7      = j.rate_limits?.seven_day?.used_percentage ?? null;
const ctx     = j.context_window?.used_percentage ?? null;
const model   = j.model?.display_name ?? '?';

const repo = j.workspace?.repo?.name
    ? [j.workspace.repo.owner, j.workspace.repo.name].filter(Boolean).join('/')
    : (j.workspace?.current_dir ?? '').split(/[\\/]/).filter(Boolean).pop() ?? '';

// Решает всегда САМЫЙ ПОЛНЫЙ из доступных счётчиков: упрёмся в тот, что ближе к потолку, а не в
// тот, который удобнее смотреть.
let worst = null, worstOf = '';
for (const [v, name] of [[h5, '5ч'], [d7, '7д'], [ctx, 'контекст']]) {
    if (v === null) continue;
    if (worst === null || v > worst) { worst = v; worstOf = name; }
}

// Состояние — по одному файлу на репозиторий: на хосте рядом работают несколько сессий в разных
// каталогах, и общий файл они затирали бы друг другу. Имя из репозитория, а не из session_id,
// чтобы файлы не плодились с каждой новой сессией.
const key = (repo || 'host').replace(/[^\w.-]/g, '_');
try {
    const tmp = join(stateDir, `usage-${key}.json.tmp`);
    writeFileSync(tmp, JSON.stringify({
        ts: Math.floor(Date.now() / 1000),
        worst, worst_of: worstOf,
        five_hour: h5, five_hour_resets_at: h5reset,
        seven_day: d7, context: ctx,
        model, repo,
        session_id: j.session_id ?? '',
        cost_usd: j.cost?.total_cost_usd ?? 0,
    }));
    renameSync(tmp, join(stateDir, `usage-${key}.json`));
} catch { }

// --- учётная запись, через кеш ---
let account = '';
try {
    const cfg = join(homedir(), '.claude.json');
    const cache = join(stateDir, 'account');
    let fresh = false;
    try { fresh = statSync(cache).mtimeMs > statSync(cfg).mtimeMs; } catch { }
    if (fresh) {
        account = readFileSync(cache, 'utf8').trim();
    } else {
        const m = readFileSync(cfg, 'utf8')
            .match(/"oauthAccount"\s*:\s*\{[^}]*"emailAddress"\s*:\s*"([^"]+)"/);
        if (m) { account = m[1]; writeFileSync(cache, account); }
    }
} catch { }

// --- вывод ---

const bar = p => p === null ? '··········'
    : '█'.repeat(Math.max(0, Math.min(10, Math.floor(p / 10)))).padEnd(10, '░');
const pct = p => p === null ? '--' : String(Math.round(p));

let until = '';
if (h5reset) {
    const left = h5reset - Math.floor(Date.now() / 1000);
    if (left > 0) {
        until = ` сброс через ${Math.floor(left / 3600)}ч${String(Math.floor((left % 3600) / 60)).padStart(2, '0')}м`;
    }
}

console.log(`${model} │ 5ч ${bar(h5)} ${pct(h5)}% │ 7д ${pct(d7)}% │ контекст ${pct(ctx)}%${until}`);

// Вторая строка приглушена: расход важнее, опознание нужно изредка. Собирается только из
// непустого — без входа и без репозитория она не превращается в частокол разделителей.
const second = [account, repo].filter(Boolean).join(' · ');
if (second) console.log(`\x1b[2m${second}\x1b[0m`);
