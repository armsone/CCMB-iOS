// CCMB 소비 기록기 1회 활성화용 사이드카 — 재시작 없이 "지금 떠 있는" server-app.mjs 옆에서 같은 기록기를 돌린다.
//
//   node /workspace/web-app/ccmb-usage-history-sidecar.mjs <server-app PID>
//
// - 기록 로직은 ccmb-usage-history.mjs의 startCcmbUsageHistory를 그대로 쓴다(복제하지 않음).
// - getUsage는 server-app.mjs와 같은 usage.py --json을 같은 결과 형태로 부른다. 서버 환경(/proc/<pid>/environ)은
//   읽지 않고 같은 계정인 사이드카 자신의 환경과 앱 폴더(cwd)로 실행한다(새 인증·자격 증명 없음).
// - 대상 PID가 끝나거나 다른 프로세스로 바뀌면(시작 시각 비교) 기록기를 멈추고 종료한다. 이후 재시작된 서버는
//   패치된 server-app.mjs가 기록기를 직접 띄운다.
// - 이미 패치된 코드로 뜬 서버(파일 수정 이후 시작)면 서버가 기록기를 갖고 있으므로 시작하지 않는다.
// - DATA_DIR의 pid 파일로 한 번에 하나만 돈다. 겹치더라도 기록기의 잠금·수집 시각 검사가 중복 기록을 막는다.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startCcmbUsageHistory } from './ccmb-usage-history.mjs';

const APP_ROOT = path.dirname(fileURLToPath(import.meta.url));
const SERVER_SCRIPT = path.join(APP_ROOT, 'server-app.mjs');
const USAGE_TOOL = path.join(APP_ROOT, 'usage.py');
const PID_NAME = 'ccmb-nas-consumption-sidecar.pid';
const WATCH_MS = 5_000;
const { O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW } = fs.constants;

const log = (m) => console.error(`${new Date().toISOString()} [ccmb-history-sidecar] ${m}`);
const fail = (m) => { log(`중단: ${m}`); process.exit(1); };

// /proc/<pid>/stat 22번째 값(부팅 후 시작 tick). PID가 재사용돼도 이 값은 달라진다.
function startTicks(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    return Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19]);
  } catch {
    return null;
  }
}

const isServer = (pid) => {
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0')[1] === SERVER_SCRIPT;
  } catch {
    return false;
  }
};

const serverPid = Number(process.argv[2]);
if (!Number.isSafeInteger(serverPid) || serverPid <= 1) fail('server-app PID가 필요합니다');
const serverTicks = startTicks(serverPid);
if (!serverTicks || !isServer(serverPid)) fail(`PID ${serverPid}는 ${path.basename(SERVER_SCRIPT)} 프로세스가 아닙니다`);
if (fs.statSync(`/proc/${serverPid}`).uid !== process.getuid()) fail('서버와 다른 계정입니다');

const btime = Number(/^btime (\d+)$/m.exec(fs.readFileSync('/proc/stat', 'utf8'))[1]);
const hz = Number(execFileSync('getconf', ['CLK_TCK'], { encoding: 'utf8' }));
if (!(btime > 0 && hz > 0)) fail('프로세스 시작 시각을 알 수 없습니다');
if ((btime + serverTicks / hz) * 1000 >= fs.statSync(SERVER_SCRIPT).mtimeMs) {
  fail('서버가 현재 server-app.mjs로 시작되어 기록기를 직접 실행합니다');
}

// 서버 환경은 읽지 않는다. 같은 계정의 자기 환경·홈과 server-app.mjs의 DATA_DIR 기본값, 앱 폴더를 쓴다.
const dataDir = path.resolve(process.env.DATA_DIR || path.join(os.homedir(), '.local/share/hanstree-workroom'));

// 한 번에 하나: pid 파일이 살아 있는 사이드카를 가리키면 시작하지 않는다.
const pidFile = path.join(dataDir, PID_NAME);
const myTicks = startTicks(process.pid);
const record = `${process.pid} ${myTicks} ${serverPid} ${serverTicks}\n`;
for (let attempt = 0; ; attempt++) {
  try {
    fs.writeFileSync(pidFile, record, { flag: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode: 0o600 });
    break;
  } catch (e) {
    if (e.code !== 'EEXIST' || attempt > 0) fail(`pid 파일을 만들 수 없습니다 (${e.code})`);
    const [pid, ticks] = fs.readFileSync(pidFile, 'utf8').trim().split(' ').map(Number);
    if (startTicks(pid) === ticks) fail(`이미 실행 중입니다 (PID ${pid})`);
    fs.unlinkSync(pidFile);
  }
}

// server-app.mjs getUsage()와 같은 usage.py 호출·결과 형태. 기록기가 수집 시각 + 185초마다 한 번만 부르므로
// 서버의 메모리 캐시는 필요 없다(usage.py 자체의 서비스별 180초 캐시는 서버와 공유된다).
function getUsage() {
  return new Promise((resolve) => {
    execFile('python3', [USAGE_TOOL, '--json'], { timeout: 65000, maxBuffer: 2 * 1024 * 1024, cwd: APP_ROOT }, (err, stdout) => {
      const fetchedAt = Date.now();
      let report;
      try { report = JSON.parse(stdout); } catch {}
      resolve(report && Array.isArray(report.services)
        ? { ok: !err && report.services.every((x) => x.ok), report, fetchedAt, error: err ? 'partial' : null, cached: false }
        : { ok: false, error: 'unavailable', fetchedAt, cached: false });
    });
  });
}

const history = startCcmbUsageHistory({ getUsage, dataDir, log });
log(`시작: server-app PID ${serverPid}`);

function exit(reason) {
  history.stop();
  try {
    if (fs.readFileSync(pidFile, 'utf8') === record) fs.unlinkSync(pidFile);
  } catch {}
  log(`종료: ${reason}`);
  process.exit(0);
}

// 이 타이머가 프로세스를 살려 둔다(기록기 타이머는 unref).
setInterval(() => {
  if (startTicks(serverPid) !== serverTicks || !isServer(serverPid)) exit(`server-app PID ${serverPid} 종료/변경`);
}, WATCH_MS);
process.on('SIGTERM', () => exit('SIGTERM'));
process.on('SIGINT', () => exit('SIGINT'));
