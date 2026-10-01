#!/bin/bash
# CCMB NAS 소비 기록기 배포 (Mac에서 실행, 기존 SSH 경로 hanstree-dev 사용).
#
#   ./deploy.sh            점검만: 사전 조건 확인 + NAS 임시 폴더에서 패치/구문 검사. 운영 파일은 바꾸지 않는다.
#   ./deploy.sh --apply    점검 통과 시 모듈·사이드카 런처 설치/업그레이드 + server-app.mjs 최소 패치 + usage.py
#                          3분 캐시 적용(백업 후 원자적 교체). 재시작은 하지 않는다. 다시 실행해도 같은 결과다.
#   ./deploy.sh --sidecar  --apply 이후, 재시작 없이 지금 떠 있는 server-app 옆에서 같은 기록기를 사이드카로 시작한다.
#                          사이드카는 그 서버 PID가 끝나면 스스로 멈추고, 재시작된 서버가 기록기를 이어받는다.
#   ./deploy.sh --status   NAS 기록/기준값 파일의 요약(개수·시각·단위)만 출력한다. 값·경로·계정은 출력하지 않는다.
#
# 운영 파일은 아래에 적은 "알려진 이전 sha256"일 때만 바꾼다. 모르는 내용이면 아무것도 바꾸지 않고 멈춘다.
# 재시작·되돌리기·사이드카 교체는 README.md의 별도 명령으로만 한다.
set -euo pipefail

HOST=hanstree-dev
HERE=$(cd "$(dirname "$0")" && pwd)
MODULE="$HERE/ccmb-usage-history.mjs"
PATCH="$HERE/server-app.patch"
LAUNCHER="$HERE/ccmb-usage-history-sidecar.mjs"
MODE=${1:-check}
SSH=(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

case "$MODE" in
  check|--apply|--sidecar) ;;
  --status)
    "${SSH[@]}" python3 - <<'PY'
import json, os
def summary(path, series_key):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return "없음"
    if not os.path.isfile(path) or os.path.islink(path):
        return "일반 파일 아님"
    try:
        doc = json.load(open(path))
        series = doc[series_key]
        counts = ",".join("%s=%d" % (k, len(v)) for k, v in series.items())
        interval = " interval=%s" % doc.get("intervalSeconds") if "intervalSeconds" in doc else ""
        return "mode=%o collectedAt=%s codexUnit=%s%s %s" % (st.st_mode & 0o777, doc.get("collectedAt"), doc.get("codexUnit"), interval, counts)
    except Exception:
        return "형식 확인 실패"
print("history:", summary("/workspace/projects/CCMB-Usage/CCMB-nas-consumption-history-v1.json", "consumptionHistory"))
print("state:  ", summary(os.path.expanduser("~/.local/share/hanstree-workroom/ccmb-nas-consumption-state-v1.json"), "series"))
def sidecar():
    try:
        pid, ticks, server, _ = open(os.path.expanduser("~/.local/share/hanstree-workroom/ccmb-nas-consumption-sidecar.pid")).read().split()
    except FileNotFoundError:
        return "없음"
    except Exception:
        return "pid 파일 형식 확인 실패"
    try:
        stat = open("/proc/%s/stat" % pid).read()
        alive = stat[stat.rindex(")") + 2:].split()[19] == ticks
    except Exception:
        alive = False
    return "PID %s (server-app PID %s) %s" % (pid, server, "실행 중" if alive else "종료됨(남은 pid 파일)")
print("sidecar:", sidecar())
PY
    exit 0 ;;
  *) echo "사용법: $0 [--apply|--sidecar|--status]" >&2; exit 2 ;;
esac

MODULE_SHA=$(shasum -a 256 "$MODULE" | cut -d' ' -f1)
PATCH_SHA=$(shasum -a 256 "$PATCH" | cut -d' ' -f1)
LAUNCHER_SHA=$(shasum -a 256 "$LAUNCHER" | cut -d' ' -f1)
STAGE=/tmp/ccmb-nas-history-stage
"${SSH[@]}" "rm -rf $STAGE && mkdir -m 700 $STAGE"
/usr/bin/scp -q -o BatchMode=yes "$MODULE" "$PATCH" "$LAUNCHER" "$HOST:$STAGE/"

"${SSH[@]}" bash -s -- "$STAGE" "$MODULE_SHA" "$PATCH_SHA" "$MODE" "$LAUNCHER_SHA" <<'REMOTE'
set -euo pipefail
STAGE=$1 MODULE_SHA=$2 PATCH_SHA=$3 MODE=$4 LAUNCHER_SHA=$5
APP=/workspace/web-app
PROJECT=/workspace/projects/CCMB-Usage
# server-app.mjs: 패치 기준 원본, 5분 시절 패치 결과(주석 한 줄만 다름), 현재(3분) 패치 결과.
BASE_SHA=5f8af1b2b1b84478bde3d901ee9b91d851c3d4e26ebe212094ae817ceb2dcec1
OLD_PATCHED_SHA=3960bfa0817ba2af9491dc5b939bf78fbc8d57d836ce849ea4fa4f41485fc7fb
PATCHED_SHA=6b9f3bdf8a7dc0543ffb35cf703a10a93979d64c2a46b46dc9671fd8a999ad36
# 5분 시절에 설치된 모듈·사이드카 런처. 이 내용일 때만 새 내용으로 올린다.
MODULE_OLD_SHA=d38b626cc5a61f9e9c8264858132b739223cee1edc9862727b25ded1936c329c
LAUNCHER_OLD_SHA=7cc159bf4b0cd6c4fd39e1f61a9b87864ef5a855f7c505c128a84b6a8217aa4c
# usage.py(작업실 어댑터): 기존 내용 → CACHE_TTL 180 한 줄(+주석)을 더한 내용. 공유 원본(/workspace/tools)은 건드리지 않는다.
USAGE_OLD_SHA=d2c4ff199b7d0918629cc47aa08bcc2eee959b671b3435707e1642a363eba50a
USAGE_SHA=5d6b55bc896a15c07900672aba70e0d910b1d0cf307812d3025a93b9d6294da6
fail() { echo "중단: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# 알려진 줄 하나를 정확히 한 번만 바꿔 stage에 쓴다. 결과는 호출한 쪽에서 sha256으로 다시 확인한다.
rewrite() {
  python3 - "$@" <<'PY'
import sys
kind, src, dst = sys.argv[1:4]
if kind == "server":
    old = '  // CCMB "나의 AI 열정": Mac 없이 기존 getUsage() 결과로 5분마다 소비 기록을 남긴다. 모듈이 없거나 실패해도 서버는 그대로 뜬다.\n'
    new = old.replace("5분마다", "3분마다")
else:
    old = "_orig_parse_claude = _base.parse_claude\n"
    new = ("# CCMB NAS 소비 기록이 3분 간격이 되도록 서비스별 캐시를 180초로 줄인다(공유 원본의 300초는 그대로).\n"
           "# 공유 도구는 CACHE_TTL을 호출 시점에 모듈 전역으로 읽으므로 이 값 하나만 바꾸면 된다.\n"
           "_base.CACHE_TTL = 180\n\n" + old)
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.exit("바꿀 기준 줄이 정확히 하나가 아님: " + kind)
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

[ "$(sha "$STAGE/ccmb-usage-history.mjs")" = "$MODULE_SHA" ] || fail "모듈 전송 확인 실패"
[ "$(sha "$STAGE/server-app.patch")" = "$PATCH_SHA" ] || fail "패치 전송 확인 실패"
[ "$(sha "$STAGE/ccmb-usage-history-sidecar.mjs")" = "$LAUNCHER_SHA" ] || fail "사이드카 전송 확인 실패"
[ -d "$PROJECT" ] && [ "$(realpath "$PROJECT")" = "$PROJECT" ] || fail "CCMB-Usage 프로젝트 폴더가 실제 폴더가 아님"
[ ! -L "$APP/server-app.mjs" ] && [ -f "$APP/server-app.mjs" ] || fail "server-app.mjs가 일반 파일이 아님"
[ ! -L "$APP/usage.py" ] && [ -f "$APP/usage.py" ] || fail "usage.py가 일반 파일이 아님"
for f in "$PROJECT/CCMB-nas-consumption-history-v1.json" "$APP/ccmb-usage-history.mjs" "$APP/ccmb-usage-history-sidecar.mjs"; do
  [ ! -L "$f" ] || fail "symlink 거부: $(basename "$f")"
done

# 모듈·런처: 없음(새로 설치) / 이미 새 내용 / 알려진 옛 내용(업그레이드)만 허용한다.
NEED_MODULE=0 NEED_LAUNCHER=0 MODULE_CUR=
if [ ! -e "$APP/ccmb-usage-history.mjs" ]; then NEED_MODULE=1
else MODULE_CUR=$(sha "$APP/ccmb-usage-history.mjs"); case "$MODULE_CUR" in
  "$MODULE_SHA") ;;
  "$MODULE_OLD_SHA") NEED_MODULE=1 ;;
  *) fail "알 수 없는 내용의 ccmb-usage-history.mjs가 이미 있음" ;;
esac; fi
if [ -e "$APP/ccmb-usage-history-sidecar.mjs" ]; then case "$(sha "$APP/ccmb-usage-history-sidecar.mjs")" in
  "$LAUNCHER_SHA") ;;
  "$LAUNCHER_OLD_SHA") NEED_LAUNCHER=1 ;;
  *) fail "알 수 없는 내용의 ccmb-usage-history-sidecar.mjs가 이미 있음" ;;
esac; fi

CURRENT=$(sha "$APP/server-app.mjs")
NEED_PATCH=1
case "$CURRENT" in
  "$PATCHED_SHA") echo "server-app.mjs: 이미 패치됨"; NEED_PATCH=0 ;;
  "$BASE_SHA")
    cp "$APP/server-app.mjs" "$STAGE/server-app.mjs"
    patch --no-backup-if-mismatch --quiet -p1 -d "$STAGE" < "$STAGE/server-app.patch" ;;
  "$OLD_PATCHED_SHA")
    echo "server-app.mjs: 5분 주석 → 3분 주석으로 업그레이드"
    rewrite server "$APP/server-app.mjs" "$STAGE/server-app.mjs" ;;
  *) fail "server-app.mjs가 알려진 기준과 다름 — 현재 소스로 패치를 다시 만들어야 함" ;;
esac
if [ "$NEED_PATCH" = 1 ]; then
  [ "$(sha "$STAGE/server-app.mjs")" = "$PATCHED_SHA" ] || fail "패치 결과가 예상과 다름"
  node --check "$STAGE/server-app.mjs"
fi

NEED_USAGE=1
case "$(sha "$APP/usage.py")" in
  "$USAGE_SHA") echo "usage.py: 이미 3분 캐시"; NEED_USAGE=0 ;;
  "$USAGE_OLD_SHA")
    rewrite usage "$APP/usage.py" "$STAGE/usage.py"
    [ "$(sha "$STAGE/usage.py")" = "$USAGE_SHA" ] || fail "usage.py 변경 결과가 예상과 다름"
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$STAGE/usage.py" ;;
  *) fail "usage.py가 알려진 기준과 다름 — 바꾸지 않음" ;;
esac
node --check "$STAGE/ccmb-usage-history.mjs"
node --check "$STAGE/ccmb-usage-history-sidecar.mjs"
echo "점검 통과 (모듈 $MODULE_SHA)"

if [ "$MODE" = "--sidecar" ]; then
  # 재시작 후 인계 경로(패치 + 같은 모듈 + 3분 캐시)가 이미 설치된 경우에만 시작한다.
  [ "$NEED_PATCH" = 0 ] && [ "$NEED_MODULE" = 0 ] && [ "$NEED_USAGE" = 0 ] && [ "$NEED_LAUNCHER" = 0 ] \
    || fail "먼저 --apply로 모듈·런처·패치·usage.py를 설치해야 함"
  if [ ! -e "$APP/ccmb-usage-history-sidecar.mjs" ]; then
    install -m 600 "$STAGE/ccmb-usage-history-sidecar.mjs" "$APP/.ccmb-usage-history-sidecar.mjs.ccmb-tmp"
    mv -f "$APP/.ccmb-usage-history-sidecar.mjs.ccmb-tmp" "$APP/ccmb-usage-history-sidecar.mjs"
  fi
  rm -rf "$STAGE"
  SERVER_PID=$(pgrep -fx "/usr/local/bin/node $APP/server-app.mjs" || true)
  [ -n "$SERVER_PID" ] && [ "$(echo "$SERVER_PID" | wc -w)" = 1 ] || fail "실행 중인 server-app 프로세스가 정확히 하나가 아님"
  LOG="$HOME/.local/share/hanstree-workroom/ccmb-nas-consumption-sidecar.log"
  [ ! -L "$LOG" ] || fail "symlink 거부: $(basename "$LOG")"
  # 서버는 건드리지 않는다. 같은 서버 PID에 이미 사이드카가 있으면 사이드카가 스스로 시작을 거부한다.
  (umask 077; nohup /usr/local/bin/node "$APP/ccmb-usage-history-sidecar.mjs" "$SERVER_PID" </dev/null >>"$LOG" 2>&1 &)
  sleep 3
  tail -n 3 "$LOG"
  exit 0
fi

if [ "$MODE" != "--apply" ]; then
  rm -rf "$STAGE"
  echo "점검만 수행했습니다. 운영 파일은 바뀌지 않았습니다."
  exit 0
fi

if [ "$NEED_PATCH$NEED_MODULE$NEED_LAUNCHER$NEED_USAGE" = 0000 ]; then
  rm -rf "$STAGE"
  echo "이미 모두 최신입니다. 운영 파일은 바뀌지 않았습니다."
  exit 0
fi

# 이번 실행의 백업은 한 시각의 한 폴더에 모은다. cp -p로 원래 권한·수정 시각을 그대로 보존한다.
# 교체본은 원래 파일의 권한을 이어받고(새 파일은 0600), 수정 시각은 지금으로 바뀐다.
BACKUP="$APP/backup-ccmb-history-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 "$BACKUP"
# 같은 폴더 임시 파일 → 점검 때 본 sha256 그대로인지 다시 확인 → rename. 그사이 바뀌었으면 덮어쓰지 않는다.
replace() { # 대상 이름, stage 파일, 점검 때 sha(없던 파일이면 빈 값)
  local target="$APP/$1" tmp="$APP/.$1.ccmb-tmp"
  rm -f "$tmp"
  if [ -n "$3" ]; then
    cp -p "$target" "$BACKUP/$1"
    cp -p "$target" "$tmp"
    cat "$2" > "$tmp"
  else
    install -m 600 "$2" "$tmp"
  fi
  if [ -n "$3" ]; then
    [ "$(sha "$target")" = "$3" ] || { rm -f "$tmp"; fail "점검 이후 $1이 바뀜"; }
  else
    [ ! -e "$target" ] || { rm -f "$tmp"; fail "점검 이후 $1이 생김"; }
  fi
  mv -f "$tmp" "$target"
}
[ "$NEED_USAGE" = 0 ] || replace usage.py "$STAGE/usage.py" "$USAGE_OLD_SHA"
[ "$NEED_MODULE" = 0 ] || replace ccmb-usage-history.mjs "$STAGE/ccmb-usage-history.mjs" "$MODULE_CUR"
[ "$NEED_LAUNCHER" = 0 ] || replace ccmb-usage-history-sidecar.mjs "$STAGE/ccmb-usage-history-sidecar.mjs" "$LAUNCHER_OLD_SHA"
[ "$NEED_PATCH" = 0 ] || replace server-app.mjs "$STAGE/server-app.mjs" "$CURRENT"
rm -rf "$STAGE"
echo "적용 완료. 백업: $BACKUP/ — 재시작 전까지는 기존 서버가 그대로 동작합니다."
REMOTE
