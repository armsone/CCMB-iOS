// CCMB "나의 AI 열정" — NAS 자체 소비 기록기.
//
// Mac 없이 NAS 앱(server-app.mjs)이 스스로 3분마다 기존 getUsage(true)(usage.py 수집기, 서비스별 180초 캐시·
// 중복 실행 방지 포함)를 한 번 불러, 서비스별 실제 수집 시각(fetched_at)이 새로 바뀐 값만으로 직전 값과의 차이(소비량)를
// 계산해 최근 40개만 남긴다. 새 인증·API·자격 증명은 만들지 않고, Node 표준 라이브러리만 쓴다.
//
// 저장 파일
// - 기준값(baseline) + 기록 원본: DATA_DIR/ccmb-nas-consumption-state-v1.json (0600, 비공개, 내보내지 않음)
// - 앱이 읽는 기록: /workspace/projects/CCMB-Usage/CCMB-nas-consumption-history-v1.json (0600)
//   예전 Mac relay 파일(CCMB-consumption-history-v1.json)과 이름이 달라 섞이지 않는다.
// 두 파일 모두 허용 목록의 숫자·시각·단위만 담는다(계정·경로·오류 문구·원본 응답 없음).
//
// 정직성 규칙
// - 첫 수집은 기준값만 잡고 소비를 만들지 않는다(가짜 40개를 미리 채우지 않는다).
// - 실패·stale·수집 시각이 그대로인 캐시·너무 오래된 값은 그 서비스만 건너뛴다(0으로 채우지 않는다).
// - 초기화(resets_at 변경·지남), 남은 값 증가(충전·초기화), 단위 전환, 15분 넘는 공백은 소비로 치지 않고
//   기준값만 다시 잡는다.
// - Codex는 주간 %(codex)와 크레딧(codexCredits)을 서로 다른 시리즈에 담고, codexUnit이 현재 단위를 알린다.
// - 일시적 실패는 기존 기록을 지우지 않는다. 형식이 다르거나 symlink·hardlink인 파일은 덮어쓰지 않는다.
import fs from 'node:fs';
import path from 'node:path';

const INTERVAL_SECONDS = 180;
// 3분 전환 전에 내보낸 기록(intervalSeconds 300)도 읽어 시각·값을 그대로 이어 받는다. 다음 내보내기부터 180으로 쓴다.
const LEGACY_INTERVAL_SECONDS = 300;
const INTERVAL_MS = INTERVAL_SECONDS * 1000;
// usage.py 서비스별 캐시(어댑터 CACHE_TTL 180초)가 확실히 지난 뒤에 부르도록 5초 늦춘다(같은 캐시를 두 번 읽지 않게).
const TICK_MARGIN_MS = 5_000;
const MIN_DELAY_MS = 30_000;
const MAX_SAMPLES = 40;
const SOURCE_MAX_AGE_MS = 10 * 60_000;
const MAX_GAP_MS = 15 * 60_000;
const RESET_TOLERANCE_SECONDS = 600;
const FUTURE_SLACK_MS = 60_000;
const LOCK_STALE_MS = 10 * 60_000;
const MAX_HISTORY_BYTES = 32_768;
const MAX_STATE_BYTES = 65_536;
const MAX_CREDITS = 1e12;

const HISTORY_DIR = '/workspace/projects/CCMB-Usage';
const HISTORY_NAME = 'CCMB-nas-consumption-history-v1.json';
const STATE_NAME = 'ccmb-nas-consumption-state-v1.json';
const LOCK_NAME = 'ccmb-nas-consumption-state-v1.lock';

const METRICS = ['codex', 'claude', 'claudeFable', 'gemini'];
const SERIES = ['codex', 'codexCredits', 'claude', 'claudeFable', 'gemini'];
const UNITS = ['percent', 'credits'];
const { O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW } = fs.constants;

class ForeignFileError extends Error {}

const isFiniteNumber = (v) => typeof v === 'number' && Number.isFinite(v);
const isEpochMs = (v) => Number.isSafeInteger(v) && v > 1_000_000_000_000 && v < 4_200_000_000_000;
const isEpochSeconds = (v) => Number.isSafeInteger(v) && v > 1_000_000_000 && v < 4_200_000_000;
const round4 = (v) => Math.round(v * 10_000) / 10_000;
const sameKeys = (obj, keys) => obj && typeof obj === 'object' && !Array.isArray(obj)
  && Object.keys(obj).length === keys.length && keys.every((k) => Object.hasOwn(obj, k));

// ───────────── 수집 결과 읽기 (usage.py --json 의 services[] 중 필요한 숫자만) ─────────────

function freshService(services, name, now) {
  const svc = services.find((s) => s && typeof s === 'object' && s.service === name);
  if (!svc || svc.ok !== true || svc.stale !== false || svc.error != null) return null;
  if (!isEpochSeconds(svc.fetched_at)) return null;
  const sourceMs = svc.fetched_at * 1000;
  if (sourceMs > now + FUTURE_SLACK_MS || now - sourceMs > SOURCE_MAX_AGE_MS) return null;
  return { sourceAt: svc.fetched_at, items: Array.isArray(svc.items) ? svc.items.filter((i) => i && typeof i === 'object') : [] };
}

const validPercent = (v) => (isFiniteNumber(v) && v >= 0 && v <= 100 ? v : null);
const validResets = (v) => (isEpochSeconds(v) ? v : null);

function percentReading(svc, match) {
  if (!svc) return null;
  const item = svc.items.find(match);
  const value = validPercent(item?.remaining_percent);
  if (value === null) return null;
  return { unit: 'percent', value, resetsAt: validResets(item.resets_at), sourceAt: svc.sourceAt };
}

// Codex는 Mac 앱과 같은 기준: 주간 한도가 소진(또는 미보고)되고 크레딧 잔액이 양수일 때만 크레딧으로 잰다.
function codexReading(svc) {
  if (!svc) return null;
  const weekly = svc.items.find((i) => i.name === 'codex' && i.window === 'weekly');
  if (!weekly) return null;
  const percent = validPercent(weekly.remaining_percent);
  const credits = weekly.credits && typeof weekly.credits === 'object' ? weekly.credits : null;
  const balance = isFiniteNumber(credits?.balance) && credits.balance >= 0 && credits.balance < MAX_CREDITS ? credits.balance : null;
  if (credits?.unlimited !== true && balance !== null && balance > 0 && (percent === null || percent <= 0)) {
    return { unit: 'credits', value: balance, resetsAt: null, sourceAt: svc.sourceAt };
  }
  if (percent === null) return null;
  return { unit: 'percent', value: percent, resetsAt: validResets(weekly.resets_at), sourceAt: svc.sourceAt };
}

function readingsFrom(report, now) {
  const services = report.services;
  const codex = freshService(services, 'codex', now);
  const claude = freshService(services, 'claude', now);
  const gemini = freshService(services, 'gemini', now);
  return {
    codex: codexReading(codex),
    claude: percentReading(claude, (i) => i.name === '전체' && i.window === 'weekly'),
    claudeFable: percentReading(claude, (i) => typeof i.name === 'string' && i.name.toLowerCase() === 'fable' && i.window === 'weekly'),
    gemini: percentReading(gemini, (i) => typeof i.name === 'string' && i.name.startsWith('Gemini Models') && i.window === 'session'),
  };
}

// 직전 기준값 → 이번 값 사이의 소비량. 소비로 볼 수 없는 경우는 null(기준값만 다시 잡는다).
function consumption(prev, cur) {
  if (cur.unit !== prev.unit) return null;
  if ((cur.sourceAt - prev.sourceAt) * 1000 > MAX_GAP_MS) return null;
  if (cur.unit === 'percent') {
    // 아직 시작되지 않은 창(100%, 초기화 시각 없음)이 이번에 시작됐다면 100%에서 줄어든 만큼이 실제 소비다.
    if (prev.resetsAt === null && prev.value === 100 && cur.resetsAt !== null) return round4(100 - cur.value);
    if ((prev.resetsAt === null) !== (cur.resetsAt === null)) return null;
    if (prev.resetsAt !== null
      && (Math.abs(cur.resetsAt - prev.resetsAt) > RESET_TOLERANCE_SECONDS || cur.sourceAt >= prev.resetsAt)) return null;
  }
  const amount = round4(prev.value - cur.value);
  return amount >= 0 ? amount : null;
}

// ───────────── 상태 검증 (기준값 + 기록 원본) ─────────────

function emptyState() {
  return { schemaVersion: 1, lastReadingAt: null, collectedAt: null, codexUnit: 'percent', baselines: {},
    series: Object.fromEntries(SERIES.map((k) => [k, []])) };
}

function validSeries(series, isTime) {
  if (!sameKeys(series, SERIES)) return false;
  return SERIES.every((key) => {
    const list = series[key];
    if (!Array.isArray(list) || list.length > MAX_SAMPLES) return false;
    let previous = -Infinity;
    return list.every((s) => {
      if (!sameKeys(s, ['at', 'amount']) || !isTime(s.at) || !isFiniteNumber(s.amount) || s.amount < 0) return false;
      const t = typeof s.at === 'string' ? Date.parse(s.at) : s.at;
      if (!(t > previous)) return false;
      previous = t;
      return true;
    });
  });
}

function validBaseline(b) {
  if (!sameKeys(b, ['unit', 'value', 'resetsAt', 'sourceAt']) || !UNITS.includes(b.unit)) return false;
  if (!isEpochSeconds(b.sourceAt) || (b.resetsAt !== null && !isEpochSeconds(b.resetsAt))) return false;
  return b.unit === 'percent' ? validPercent(b.value) !== null : isFiniteNumber(b.value) && b.value >= 0 && b.value < MAX_CREDITS;
}

function validState(state) {
  if (!sameKeys(state, ['schemaVersion', 'lastReadingAt', 'collectedAt', 'codexUnit', 'baselines', 'series'])) return false;
  if (state.schemaVersion !== 1 || !UNITS.includes(state.codexUnit)) return false;
  for (const key of ['lastReadingAt', 'collectedAt']) {
    if (state[key] !== null && !isEpochMs(state[key])) return false;
  }
  const baselines = state.baselines;
  if (!baselines || typeof baselines !== 'object' || Array.isArray(baselines)) return false;
  if (!Object.keys(baselines).every((k) => METRICS.includes(k) && validBaseline(baselines[k]))) return false;
  return validSeries(state.series, isEpochMs);
}

const isIsoTime = (v) => typeof v === 'string' && v.length <= 64 && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,3})?Z$/.test(v)
  && isEpochMs(Date.parse(v));

function validHistory(doc) {
  if (!sameKeys(doc, ['schemaVersion', 'source', 'intervalSeconds', 'slotCount', 'collectedAt', 'codexUnit', 'consumptionHistory'])) return false;
  return doc.schemaVersion === 1 && doc.source === 'nas'
    && (doc.intervalSeconds === INTERVAL_SECONDS || doc.intervalSeconds === LEGACY_INTERVAL_SECONDS)
    && doc.slotCount === MAX_SAMPLES && isIsoTime(doc.collectedAt) && UNITS.includes(doc.codexUnit)
    && validSeries(doc.consumptionHistory, isIsoTime);
}

function historyDocument(state) {
  const iso = (ms) => new Date(ms).toISOString();
  return {
    schemaVersion: 1,
    source: 'nas',
    intervalSeconds: INTERVAL_SECONDS,
    slotCount: MAX_SAMPLES,
    collectedAt: iso(state.collectedAt),
    codexUnit: state.codexUnit,
    consumptionHistory: Object.fromEntries(SERIES.map((k) => [k, state.series[k].map((s) => ({ at: iso(s.at), amount: s.amount }))])),
  };
}

// ───────────── 파일 (실제 경로 확인 · symlink/hardlink 거부 · 원자적 교체) ─────────────

function checkRealDirectory(dir) {
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || fs.realpathSync(dir) !== dir) throw new ForeignFileError('directory is not a real directory');
}

function readOwnFile(file, maxBytes) {
  let fd;
  try {
    fd = fs.openSync(file, O_RDONLY | O_NOFOLLOW);
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    if (e.code === 'ELOOP') throw new ForeignFileError('refusing symlinked file');
    throw e;
  }
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.nlink !== 1) throw new ForeignFileError('not a plain, unlinked file');
    if (st.size > maxBytes) throw new ForeignFileError('file too large');
    const buffer = Buffer.alloc(st.size);
    let offset = 0;
    while (offset < st.size) {
      const read = fs.readSync(fd, buffer, offset, st.size - offset, offset);
      if (read === 0) break;
      offset += read;
    }
    return buffer.subarray(0, offset).toString('utf8');
  } finally {
    fs.closeSync(fd);
  }
}

function writeOwnFile(dir, name, text) {
  const target = path.join(dir, name);
  const st = fs.lstatSync(target, { throwIfNoEntry: false });
  if (st && (!st.isFile() || st.nlink !== 1)) throw new ForeignFileError('refusing to replace a non-plain file');
  const tmp = path.join(dir, `.${name}.tmp-${process.pid}-${Date.now()}`);
  const fd = fs.openSync(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600);
  try {
    try {
      fs.writeSync(fd, text);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, target);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    throw e;
  }
}

function acquireLock(dir) {
  const lock = path.join(dir, LOCK_NAME);
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.closeSync(fs.openSync(lock, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600));
      return lock;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const st = fs.lstatSync(lock, { throwIfNoEntry: false });
      if (st && st.isFile() && st.nlink === 1 && Date.now() - st.mtimeMs > LOCK_STALE_MS) {
        try { fs.unlinkSync(lock); } catch {}
        continue;
      }
      return null;
    }
  }
  return null;
}

// ───────────── 기록기 ─────────────

export function startCcmbUsageHistory({ getUsage, dataDir, log = (m) => console.error(`[ccmb-history] ${m}`) }) {
  let lastLogged = null;
  const note = (message) => {
    if (message === lastLogged) return;
    lastLogged = message;
    log(message);
  };
  const stateDir = path.resolve(dataDir);
  let timer = null;
  let stopped = false;
  let running = false;

  function loadState() {
    const raw = readOwnFile(path.join(stateDir, STATE_NAME), MAX_STATE_BYTES);
    if (raw !== null) {
      let state;
      try { state = JSON.parse(raw); } catch { throw new ForeignFileError('state is not JSON'); }
      if (!validState(state)) throw new ForeignFileError('state is not the expected shape');
      return state;
    }
    // 기준값 파일이 없으면 이미 내보낸 기록만 이어 받는다(기준값은 다음 수집에서 새로 잡는다).
    const state = emptyState();
    const history = loadHistory();
    if (history) {
      const { doc } = history;
      state.codexUnit = doc.codexUnit;
      state.collectedAt = Date.parse(doc.collectedAt);
      state.lastReadingAt = state.collectedAt;
      for (const key of SERIES) {
        state.series[key] = doc.consumptionHistory[key].map((s) => ({ at: Date.parse(s.at), amount: s.amount }));
      }
    }
    return state;
  }

  function loadHistory() {
    const raw = readOwnFile(path.join(HISTORY_DIR, HISTORY_NAME), MAX_HISTORY_BYTES);
    if (raw === null) return null;
    let doc;
    try { doc = JSON.parse(raw); } catch { throw new ForeignFileError('history is not JSON'); }
    if (!validHistory(doc)) throw new ForeignFileError('history is not the expected shape');
    return { raw, doc };
  }

  function exportHistory(state) {
    if (state.collectedAt === null) return;
    const text = JSON.stringify(historyDocument(state));
    if (Buffer.byteLength(text) > MAX_HISTORY_BYTES) throw new ForeignFileError('history would exceed size limit');
    const existing = loadHistory();
    if (existing?.raw === text) return;
    writeOwnFile(HISTORY_DIR, HISTORY_NAME, text);
  }

  function apply(usage) {
    checkRealDirectory(stateDir);
    checkRealDirectory(HISTORY_DIR);
    const lock = acquireLock(stateDir);
    if (!lock) return 'locked';
    try {
      const state = loadState();
      const now = Date.now();
      const readingAt = usage?.fetchedAt;
      const report = usage?.report;
      if (!isEpochMs(readingAt) || readingAt > now + FUTURE_SLACK_MS || !report || !Array.isArray(report.services)) {
        exportHistory(state);
        return 'no-report';
      }
      if (state.lastReadingAt !== null && readingAt <= state.lastReadingAt) {
        exportHistory(state);
        return 'no-new-collection';
      }

      const readings = readingsFrom(report, now);
      let accepted = 0;
      for (const metric of METRICS) {
        const cur = readings[metric];
        if (!cur) continue;
        const prev = state.baselines[metric];
        if (prev && cur.sourceAt <= prev.sourceAt) continue;
        accepted++;
        const amount = prev ? consumption(prev, cur) : null;
        state.baselines[metric] = cur;
        if (metric === 'codex') state.codexUnit = cur.unit;
        if (amount === null) continue;
        const key = metric === 'codex' && cur.unit === 'credits' ? 'codexCredits' : metric;
        const last = state.series[key].at(-1);
        if (last && last.at >= readingAt) continue;
        state.series[key] = [...state.series[key], { at: readingAt, amount }].slice(-MAX_SAMPLES);
      }
      if (!accepted) {
        exportHistory(state);
        return 'no-fresh-service';
      }
      state.lastReadingAt = readingAt;
      state.collectedAt = readingAt;
      const text = JSON.stringify(state);
      if (Buffer.byteLength(text) > MAX_STATE_BYTES) throw new ForeignFileError('state would exceed size limit');
      // 기준값을 먼저 저장한다. 내보내기 전에 멈춰도 다음 실행이 같은 구간을 두 번 세지 않는다.
      writeOwnFile(stateDir, STATE_NAME, text);
      exportHistory(state);
      return 'recorded';
    } finally {
      try { fs.unlinkSync(lock); } catch {}
    }
  }

  function schedule(delay) {
    if (stopped) return;
    timer = setTimeout(tick, Math.min(Math.max(delay, MIN_DELAY_MS), INTERVAL_MS + TICK_MARGIN_MS));
    timer.unref();
  }

  async function tick() {
    if (running || stopped) return;
    running = true;
    let nextDelay = INTERVAL_MS + TICK_MARGIN_MS;
    try {
      let usage = null;
      try {
        // force: 서버의 5분 메모리 캐시 대신 30초 경로를 쓴다(진행 중 호출은 그대로 합쳐진다).
        usage = await getUsage(true);
      } catch {
        usage = null;
      }
      if (isEpochMs(usage?.fetchedAt)) nextDelay = usage.fetchedAt + INTERVAL_MS + TICK_MARGIN_MS - Date.now();
      const outcome = apply(usage);
      note(outcome === 'recorded' ? 'recorded' : `skipped (${outcome})`);
    } catch (e) {
      note(e instanceof ForeignFileError ? `refused: ${e.message}` : `failed (${e.code || e.name})`);
    } finally {
      running = false;
      schedule(nextDelay);
    }
  }

  // 재시작 직후 몰아서 수집하지 않도록, 마지막 수집 시각 기준 3분 뒤(최소 30초)에 첫 수집을 한다.
  let firstDelay = MIN_DELAY_MS;
  try {
    const raw = readOwnFile(path.join(stateDir, STATE_NAME), MAX_STATE_BYTES);
    const last = raw === null ? null : JSON.parse(raw)?.lastReadingAt;
    if (isEpochMs(last)) firstDelay = last + INTERVAL_MS + TICK_MARGIN_MS - Date.now();
  } catch {}
  schedule(firstDelay);

  return {
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
    },
  };
}
