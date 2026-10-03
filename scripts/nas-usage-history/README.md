# NAS 소비 기록기 (나의 AI 열정)

Mac 없이 NAS 앱이 스스로 3분마다 소비 기록을 남깁니다. iPhone은 이 파일을 읽기만 합니다.

- `ccmb-usage-history.mjs` — NAS `/workspace/web-app/`에 두는 모듈(Node 표준 라이브러리만 사용).
- `server-app.patch` — `server-app.mjs` `startServer()` 안에 4줄을 더하는 최소 패치. 모듈을
  동적 `import()`로 불러, 모듈이 없거나 실패해도 서버는 그대로 뜹니다.
- `ccmb-usage-history-sidecar.mjs` — 재시작 없이 지금 서버 옆에서 같은 기록기를 돌리는 1회 활성화용 런처.
- `deploy.sh` — 점검(기본) / `--apply` / `--sidecar` / `--status`. `--apply`는 작업실 어댑터 `usage.py`에
  `_base.CACHE_TTL = 180` 한 줄도 넣습니다(공유 원본 `/workspace/tools/ai_usage.py`는 그대로).

## 동작

- 수집: 기존 `getUsage(true)`를 그대로 부릅니다. 서버의 5분 메모리 캐시 대신 기존 새로고침 경로(30초)를
  쓰고, 진행 중인 호출은 그대로 합쳐집니다(`usageInflight`). usage.py의 서비스별 캐시는 작업실 어댑터에서
  180초로 줄였습니다(공유 원본은 300초 그대로). 새 인증·API·자격 증명·CLI 변경은 없습니다. 다음 실행은
  이전 수집 시각 + 185초(180초 캐시 + 5초 여유, 최소 30초)로 잡아 같은 캐시를 두 번 읽지 않고, 한 번에
  하나만 돕니다. 재시작 뒤에도 마지막 수집 시각을 이어서 씁니다.
- 대상: Codex 주간 %(또는 주간 소진 + 크레딧 잔액 > 0일 때 크레딧), Claude 전체 주간, Claude Fable 주간,
  Gemini Models 세션.
- 새 값 판정: 서비스가 `ok: true`, `stale: false`이고 서비스별 `fetched_at`이 직전 기준값보다 새롭고 10분
  이내일 때만. 실패·stale·같은 캐시·누락은 그 서비스만 건너뜁니다(0으로 채우지 않음, 기존 기록 유지).
- 소비량 = 직전 기준값 − 이번 값(남은 % 또는 크레딧). 같은 값이면 0도 실제 기록입니다.
- 소비로 치지 않고 기준값만 다시 잡는 경우: 첫 수집, `resets_at` 10분 넘게 변경·경과, 남은 값 증가
  (초기화·충전), 단위 전환, 기준값과 15분 넘는 공백. 예외로 시작 전 창(100%, 초기화 시각 없음)이
  시작된 경우는 100%에서 줄어든 만큼만 기록합니다.
- 시리즈당 최근 40개. 한 번의 수집에서 나온 표본은 모두 같은 `at`(그 수집 결과의 시각)을 씁니다.

## 파일

| 파일 | 내용 | 공개 |
|---|---|---|
| `~/.local/share/hanstree-workroom/ccmb-usage/CCMB-nas-consumption-history-v1.json` | 앱이 읽는 기록 | `GET /api/ccmb/files?name=...`(마스터 로그인 필요) |
| `~/.local/share/hanstree-workroom/ccmb-nas-consumption-state-v1.json` | 기준값 + 기록 원본 | 내보내지 않음 |
| `~/.local/share/hanstree-workroom/ccmb-nas-consumption-state-v1.lock` | 실행 중 잠금(끝나면 삭제) | — |

모두 0600, 같은 폴더 임시 파일 → fsync → rename. 기준값을 먼저 저장하고 기록을 내보내므로, 중간에 멈춰도
같은 구간을 두 번 세지 않습니다. 실제 폴더가 아니거나(symlink), 대상이 symlink·hardlink·다른 형식이면
쓰지 않고 거부합니다. 예전 Mac relay 파일 `CCMB-consumption-history-v1.json`은 건드리지 않습니다.

계약(앱 쪽 엄격 파서와 동일):

```json
{"schemaVersion":1,"source":"nas","intervalSeconds":180,"slotCount":40,
 "collectedAt":"2026-10-01T07:45:12.345Z","codexUnit":"percent",
 "consumptionHistory":{"codex":[{"at":"…Z","amount":0.5}],"codexCredits":[],
   "claude":[],"claudeFable":[],"gemini":[]}}
```

`collectedAt`은 마지막으로 새 값을 받아들인 시각입니다. 첫 수집(기준값만)부터 파일이 생기며, 두 번째
새 수집부터 표본이 생깁니다.

5분 → 3분 전환: 기록기는 이미 있는 `intervalSeconds: 300` 기록도 읽어(허용 값은 300과 180 두 개뿐) 시각·값을
지우거나 바꾸지 않고 이어 받고, 다음 내보내기부터 `180`으로 씁니다. 기준값(state) 파일 구조는 그대로이며
기준값을 새로 잡지 않습니다. 앱은 `180`만 받으므로, 전환 전 기기에 보관된 300 기록은 다음 NAS 기록(3분 이내)을
받을 때까지 표시되지 않을 수 있습니다.

## 배포 (승인 후)

사전 조건: 운영 파일이 아래 "알려진" sha256 중 하나여야 합니다. 다르면 스크립트가 아무것도 바꾸지 않고 멈춥니다.

| 파일 | 원본 / 5분 시절 (업그레이드 대상) | 3분 (결과) |
|---|---|---|
| `server-app.mjs` | `5f8af1b2…dcec1`(원본, 4줄 패치) / `3960bfa0…5fc7fb`(주석 1줄 교체) | `6b9f3bdf…99ad36` |
| `usage.py` | `d2c4ff19…eba50a` | `5d6b55bc…94da6` |
| `ccmb-usage-history.mjs` | 없음 / `d38b626c…36c329c` | 이 폴더의 파일 |
| `ccmb-usage-history-sidecar.mjs` | 없음 / `7cc159bf…7aa4c` | 이 폴더의 파일 |

```sh
cd scripts/nas-usage-history
./deploy.sh            # 점검만
./deploy.sh --apply    # 한 백업 폴더에 원본 보존(cp -p) 후 원자적 교체. 재시작은 하지 않음. 다시 실행해도 같은 결과
```

### 5분 → 3분 업그레이드 (재시작 없이)

지금 떠 있는 사이드카는 옛 모듈(300초)을 메모리에 들고 있으므로, `--apply` 뒤 사이드카만 바꿔 띄웁니다.
서버(server-app)는 끄거나 다시 띄우지 않습니다.

```sh
./deploy.sh --apply
# 사이드카만 종료: pid 파일의 PID가 시작 시각·명령줄까지 사이드카와 일치할 때만 SIGTERM(서버 PID는 거부)
ssh hanstree-dev python3 - <<'PY'
import os, signal, time
pid, ticks, server, _ = open(os.path.expanduser("~/.local/share/hanstree-workroom/ccmb-nas-consumption-sidecar.pid")).read().split()
stat = open("/proc/%s/stat" % pid).read()
cmd = open("/proc/%s/cmdline" % pid).read().split("\0")
assert pid != server and stat[stat.rindex(")") + 2:].split()[19] == ticks, "pid 파일과 다른 프로세스"
assert cmd[1:3] == ["/workspace/web-app/ccmb-usage-history-sidecar.mjs", server], "사이드카가 아님"
os.kill(int(pid), signal.SIGTERM)
for _ in range(50):
    if not os.path.exists("/proc/" + pid): break
    time.sleep(0.1)
print("사이드카 PID", pid, "종료" if not os.path.exists("/proc/" + pid) else "아직 종료 중")
PY
./deploy.sh --sidecar  # 새 모듈(180초)로 같은 server-app PID에 다시 붙임
./deploy.sh --status   # history interval=180(다음 수집 뒤), sidecar: 새 PID 실행 중
```

사이드카는 SIGTERM을 받으면 기록기를 멈추고 자기 pid 파일만 지운 뒤 끝납니다(진행 중 수집은 잠금·수집
시각 검사로 중복 기록되지 않음). 다음 정상 재시작 뒤에는 패치된 서버가 같은 새 모듈을 직접 띄웁니다.

### 재시작 없이 바로 활성화 (사이드카)

재시작은 진행 중인 대화를 모두 끊으므로, `--apply` 직후에는 서버를 그대로 두고 사이드카로 시작합니다.

```sh
./deploy.sh --sidecar  # 패치·모듈 설치 확인 → 사이드카 설치 → 지금 떠 있는 server-app PID에 붙여 시작
./deploy.sh --status   # sidecar: PID … (server-app PID …) 실행 중
```

- `ccmb-usage-history-sidecar.mjs`(`/workspace/web-app/`, 0600)가 같은 `startCcmbUsageHistory`를 불러 씁니다.
  수집은 서버와 같은 `python3 usage.py --json`이며, 서버 프로세스 환경(`/proc/<pid>/environ`)은 읽지 않고
  같은 계정인 사이드카 자신의 환경·홈으로 앱 폴더(`/workspace/web-app`)에서 실행합니다. `DATA_DIR`은 서버 기본값
  (`~/.local/share/hanstree-workroom`)을 따릅니다(usage.py의 서비스별 180초 캐시를 서버와 공유, 새 인증 없음).
- 서버 PID와 시작 시각(`/proc/<pid>/stat`)을 5초마다 확인해, 그 프로세스가 끝나거나 바뀌면 멈추고 종료합니다.
- 한 번에 하나: `~/.local/share/hanstree-workroom/ccmb-nas-consumption-sidecar.pid`가 살아 있는 사이드카를
  가리키면 다시 실행해도 시작하지 않습니다. 패치된 파일 이후에 시작된 서버(기록기 내장)에는 붙지 않습니다.
- 로그: 같은 폴더 `ccmb-nas-consumption-sidecar.log`(0600, 시작/종료/결과 코드만).
- 인계: 다음 정상 재시작 때 사이드카는 5초 안에 종료되고, 새 서버는 패치로 기록기를 직접 띄웁니다(첫 수집은
  마지막 수집 + 185초, 최소 30초 뒤). 겹치더라도 잠금 파일과 수집 시각 검사가 같은 구간을 두 번 세지 않습니다.
  인계 확인 후 `/workspace/web-app/ccmb-usage-history-sidecar.mjs`는 지워도 됩니다.
- 수동 중지: `kill -TERM <사이드카 PID>`(서버에는 영향 없음).

### 재시작

재시작(웹 화면에서 진행 중인 대화가 없는지 먼저 확인). 감독 프로세스(server.mjs)가 자식을 다시 띄웁니다:

```sh
ssh hanstree-dev 'pid=$(pgrep -fx "/usr/local/bin/node /workspace/web-app/server-app.mjs"); \
  sup=$(pgrep -fx "node /workspace/web-app/server.mjs"); \
  [ -n "$pid" ] && [ "$(ps -o ppid= -p "$pid" | tr -d " ")" = "$sup" ] && kill -TERM "$pid"'
```

확인: 약 30초~2분 뒤 `./deploy.sh --status`에 `history:`와 `state:`가 생기고(표본 0개), 약 3분 뒤 두 번째
수집부터 개수가 늘어나야 합니다.

되돌리기: `--apply`가 출력한 백업 폴더에 있는 파일만 같은 방식으로 되돌린 뒤 같은 방법으로 재시작합니다
(사이드카를 쓰는 중이면 위 절차로 사이드카도 다시 띄웁니다). 기록·기준값 파일은 그대로 둡니다.

```sh
ssh hanstree-dev 'B=/workspace/web-app/backup-ccmb-history-<시각>; cd /workspace/web-app && \
  for f in "$B"/*; do n=$(basename "$f"); cp -p "$f" ".$n.ccmb-rb" && mv -f ".$n.ccmb-rb" "$n"; done'
```

기록 저장 위치는 서버 `DATA_DIR/ccmb-usage`(기존 `/workspace/projects/CCMB-Usage` 프로젝트 폴더에서 이전됨)이며,
iPhone은 삭제된 프로젝트 다운로드 API 대신 서버 전용 `GET /api/ccmb/files?name=...`로 읽습니다.

주의: 관리 자동 배포(support-automation)는 운영 `server-app.mjs`가 GitHub 저장소
(`armsone/Hanstree-Workroom` main)와 같아야 진행합니다. 적용 후에는 같은 변경(패치 + 모듈)을 그
저장소에도 반영해야 이후 `server-app.mjs` 자동 배포가 "운영 소스와 저장소가 다릅니다"로 막히지 않습니다.
