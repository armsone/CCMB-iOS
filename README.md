# CCMB for iPhone

Mac 메뉴 막대 앱 [CCMB](../CCMB-MacOS)의 원격 동반 대시보드입니다.
놀이터 웹사이트(`https://hanstree.synology.me:5443`)를 직접 운영 중인 NAS에서
Codex·Claude·Gemini(그리고 보조로 Grok)의 남은 사용량을 읽어 보여 줍니다.

## 사용 방법 (NAS)

1. 메뉴(≡) 또는 첫 화면의 **NAS에서 불러오기**를 누릅니다.
2. 아직 로그인되어 있지 않으면 NAS 웹사이트의 로그인 화면이 그대로 뜹니다. 평소
   쓰던 비밀번호로 로그인하면 창이 자동으로 닫히고 사용량을 불러옵니다.
3. 이후에는 앱을 열거나, 전경으로 돌아오거나, 당겨서 새로 고침하거나, 툴바 메뉴에서
   사용량 변화에 따라 자동으로 최신 값을 읽습니다. 세션은 iOS의 웹 로그인 저장소에
   남아 있어 보통 다시 로그인할 필요가 없습니다.
주소는 `https://hanstree.synology.me:5443`으로 고정되어 있으며, 주소를 입력하거나 변경할 필요가 없습니다.

CCMB는 NAS 비밀번호를 직접 입력받거나 저장하지 않습니다. 로그인은 항상 NAS
자체의 웹 로그인 화면에서 이루어지고, 앱은 그 결과로 생긴 로그인 세션 쿠키만
이용해 `GET /api/usage`를 읽습니다. NAS 경로의 Codex는 NAS 프런트엔드가 '토큰'
이라 부르는 잔액(플레이그라운드가 보고하는 금액성 잔액이며 입력/출력 토큰
소비량이 아닙니다)을 함께 보여 주며, 무제한인 경우 "무제한", 값이 없으면
"확인 불가"로 표시합니다. 그 외에는 Grok이 없으며 해당 항목은
"제공되지 않음"으로 정직하게 표시됩니다. 소비 기록(나의 AI 열정)은 NAS 조회
API에는 없고, 아래의 NAS 자체 기록 파일을 통해서만 표시됩니다(Mac 불필요). NAS 세션이 만료되면 마지막으로
불러온 값을 유지한 채 다시 로그인하라는 안내가 뜹니다.

### Gemini 온라인(O세션/O주간) — 개발자용 경로

NAS 경로는 자체적으로는 Gemini의 '온라인' 세션 값을 모릅니다(NAS 조회
API에는 애초에 해당 필드가 없습니다). 대신 **NAS에 저장된 하나의 bounded
JSON 파일**을 읽어 그 두 칸만 채웁니다:

- 원천: Mac이 이미 수집해 두는 `~/Library/Application Support/CCMB/usage-v1.json`의
  `gemini.online` (gemini.google.com 웹 세션 값). CLI는 이 파일을 건드리지 않습니다.
- 전송: `scripts/nas-gemini-online-relay/relay.py`가 60초마다(런치데몬 간격)
  기존 SSH 경로(`hanstree-dev`, BatchMode)로 값만 골라 전송합니다. NAS 쪽에는
  고정된(바뀌지 않는) 검증 코드만 base64 인자로, 실제 값은 표준입력으로 전달됩니다.
  비밀번호·토큰은 인자/출력 어디에도 없습니다.
- 저장 위치: 서버의 **비공개(private)** 데이터 폴더
  `DATA_DIR/ccmb-usage/CCMB-gemini-online-v1.json` 한 파일뿐입니다(이전에는 삭제된
  프로젝트 `CCMB-Usage`의 `/workspace/projects/CCMB-Usage/` 아래에 있었습니다).
  iPhone은 전용 `GET /api/ccmb/files?name=CCMB-gemini-online-v1.json`으로만 읽습니다.
  NAS 서버 코드 중 이 전용 조회 엔드포인트 외에는 권한·NAS 사용량 조회 UI가 바뀌지 않습니다.
- 계약: `{"schemaVersion":1,"gemini":{"online":{fiveHourRemainingPercent,
  weeklyRemainingPercent, fiveHourResetText, weeklyResetText, fetchedAt}}}`만
  허용합니다. `fetchedAt`은 Mac이 실제로 값을 읽은 시각이며, 중계된 시각으로
  절대 바뀌지 않습니다. 비율은 0~100의 유한한 숫자여야 하고(불리언 금지),
  최소 하나는 있어야 하며, 초기화 안내문은 160자 제한에 제어문자가 제거됩니다.
- iPhone: 짧은 타임아웃(약 15초)·8KiB 상한으로 같은 로그인 세션(`hw_session`
  쿠키, 같은 origin, 리다이렉트 금지)으로만 이 파일을 읽습니다. 파일이 없거나
  형식이 안 맞으면 O세션/O주간은 기존처럼 "NAS 데이터에서 제공되지 않음"으로
  남고, 다른 서비스나 NAS 본 조회 결과에는 전혀 영향이 없습니다.
- 표시: O세션/O주간 칸과 상세 화면에는 Gemini CLI/NAS 조회 시각과는 별도로
  "온라인 · Mac 수집 … · NAS 저장" 또는(1시간 초과 시) "오래된 값 · Mac 수집 …"이
  붙어, CLI 값이 최신이어도 온라인 값의 실제 수집 시각을 숨기지 않습니다.

설치(검토 후 직접 실행):

```sh
cd scripts/nas-gemini-online-relay
python3 install.py              # 드라이런: 아무것도 바꾸지 않고 계획만 출력
python3 install.py --install    # ~/Library/LaunchAgents에 이 작업 전용 LaunchAgent 설치
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.armsone.ccmb.gemini-nas-relay.plist
launchctl kickstart gui/$(id -u)/com.armsone.ccmb.gemini-nas-relay
```

제거:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.armsone.ccmb.gemini-nas-relay.plist
rm -f ~/Library/LaunchAgents/com.armsone.ccmb.gemini-nas-relay.plist
rm -rf ~/Library/Application\ Support/CCMB/NASRelay
```

Mac이 꺼져 있거나 Gemini 웹 로그인이 만료되면 relay는 그냥 아무 것도 보내지
않고, NAS에는 **마지막으로 성공한 값**이 그대로 남습니다(오래된 값으로
표시됩니다). 이는 CCMB.app이나 기존 LaunchAgent와 무관한 별도의 작업이며,
기존 수집기·iPhone 원격 동기화·NAS 로그인 흐름은 전혀 바꾸지 않습니다.

이전 버전의 relay는 Mac의 소비 기록도 `CCMB-consumption-history-v1.json`으로 보냈지만,
이제는 Gemini 온라인 값만 보냅니다. 이미 저장된 그 파일은 지우지 않고 그대로 두며 앱은 읽지
않습니다. 설치된 LaunchAgent의 relay 사본은 위 설치 명령을 다시 실행할 때 갱신됩니다.

### 소비 기록(나의 AI 열정) — NAS 자체 기록, Mac 불필요

NAS 연결 때 아래 그래프는 **NAS가 스스로 3분마다** 모은 소비 기록을 보여 줍니다
(자세한 내용·배포: `scripts/nas-usage-history/README.md`).

- 수집: NAS 앱이 기존 사용량 수집기(`GET /api/usage?refresh=1`과 같은 경로, 서비스별 180초 캐시)를 3분마다 한 번 불러,
  서비스별 실제 수집 시각이 새로 바뀐 값만 씁니다. 새 인증·API·자격 증명은 없습니다.
- 대상: Codex 주간(주간 소진 + 크레딧 잔액이 있으면 크레딧, 서로 다른 시리즈), Claude 전체 주간 ·
  Fable 주간, Gemini 세션. 표본 = 직전 실제 값 대비 줄어든 양.
- 첫 수집은 기준값만 잡습니다(가짜 기록 없음). 실패·오래된 값은 그 서비스만 비워 두고(0으로 채우지
  않음), 초기화·충전·단위 전환·15분 넘는 공백은 소비로 치지 않고 기준값만 다시 잡습니다.
- 저장 위치: 서버의 비공개 데이터 폴더 `DATA_DIR/ccmb-usage/CCMB-nas-consumption-history-v1.json`
  (디스크에는 최근 400개까지 쌓이지만, 앱이 받는 값은 최근 40개입니다). 기준값은 같은 데이터 폴더 밖
  NAS 앱 데이터 폴더에 따로 두어 내보내지 않습니다.
- 계약: `{"schemaVersion":1,"source":"nas","intervalSeconds":180,"slotCount":40,"collectedAt",
  "codexUnit":"percent"|"credits","consumptionHistory":{codex,codexCredits,claude,claudeFable,gemini}}`만
  허용합니다. 표본은 `{at, amount}`, 시각은 시간대가 있는 ISO 8601(엄격히 증가, 5분 넘는 미래 금지),
  값은 유한한 0 이상 숫자(불리언 금지), 32KiB 상한. 다른 형식(예전 Mac 기록 포함)은 통째로 거부합니다.
- iPhone: 같은 로그인 세션·origin·리다이렉트 금지로 읽고, 검증된 기록만 NAS 주소와 묶어 기기에
  보관합니다(더 오래된 응답은 무시, 실패해도 마지막 기록 유지). 제목 옆에 "NAS 수집 · 3분 간격, 40개",
  그래프 아래에 마지막 기록 시각과 1시간 초과 시 "오래된 기록"을 표시하며, 첫 표본 전에는 "NAS에서
  기록을 모으는 중입니다"만 보여 줍니다.

## 화면 구성

- 첫 페이지는 Codex·Claude·Gemini 세 영역과 NAS 소비 그래프를 함께 보여 줍니다.
  큰 자동 새로 고침 카드 대신 상단의 작은 새로고침 버튼·카운트다운을 사용합니다.
- **Codex**: 주간 한도·리셋, 크레딧 잔액, 요금제·계정, 초기화 개수와 권별 만료시간.
- **Claude**: 세션·Fable·전체 주간과 각 리셋, 요금제·계정, 초기화 개수·만료시간.
- **Gemini**: 본·부계정의 세션·주간과 각 리셋, 본계정 요금제, 두 계정명.
  Gemini 크레딧과 호스트·실행기 상태 문구는 홈·상세 화면에 표시하지 않습니다.
- 초기화 만료시간은 작은 글씨로 연속 표시하고 오른쪽 정렬합니다. Gmail 접미사는 표시에서만
  생략하며 원본 신원은 유지합니다. NAS에서 받은 소비량·시각을 그대로 그래프에 사용합니다.
- 카드의 초기화 시각은 오늘이면 `HH:mm`, 내일·모레는 `내일 HH:mm`·`모레 HH:mm`, 글피부터와
  지난 시각은 `MM/dd(요일) HH:mm`(예: `10/25(일) 13:25`)으로 표시하며 날짜 경계는 기기 달력의
  자정 기준입니다. Codex 리셋권 만료 줄은 날짜·시각만 보여 주고, Codex 카드에도 다른 카드와
  같은 가로 남은 사용량 막대가 있습니다. 카드의 `24시간 사용` 제목 글자는 없으며 그래프의
  축과 `지금`/`24시간 전` 표시는 그대로입니다. Codex 토큰은 소수를 버린 정수와 쉼표로 보여
  주고 저장된 잔액 값은 바꾸지 않습니다. 24시간 그래프는 실제로 소비가 관측된 구간 아래에만
  옅은 면 채움을 칠하며 0 구간이나 수집 공백을 채우지 않습니다.
- 병기 스타일은 기존 색·컴포넌트에 정보 위계와 작은 간격을 적용합니다. 저장된 레퍼런스
  KTM 대시보드(확인 2026-10-16)의 짧은 시선·상태 위계,
  LINQ(2026-09-18)의 전문가 정보 구성, Apple HIG Branding(2026-09-20)의 절제된 색·서체를
  참고했으며 새 공개 웹 조사는 하지 않았습니다. 기본 글자 크기에서 정보를 한 페이지에 모으는
  것이 목표이고, 접근성 글자 크기에서는 자연스럽게 스크롤합니다. 별도 화면 대조·3초 테스트는
  사용자 지시대로 하지 않았으므로 실제 뷰포트 안의 배치는 미확인입니다.

자동 새로 고침은 NAS의 실제 수집 주기와 맞춘 180초(3분) 고정 간격입니다. 앱이
포그라운드에 있을 때만 타이머가 돌며, 백그라운드에서는 중지하고 복귀 시 바로
한 번 읽은 뒤 다시 180초 주기로 돌아갑니다. NAS의 실제 제공사 수집은 별도
정책과 Retry-After를 지키므로 중복 요청은 보내지 않습니다. 홈 화면 상단
도구 모음의 새로 고침 버튼으로 언제든 즉시 새로 고칠 수 있습니다. 원격 실패
시 마지막 정상 스냅샷을 유지하고, 네트워크 없음·NAS 로그인 만료·오래된
데이터를 구분해 할 일을 먼저 안내합니다.

## 개인정보

- 스냅샷에는 남은 비율·초기화 시각·크레딧 잔액 등 표시용 값만 있습니다. 토큰,
  쿠키, OAuth 자격증명, 원시 CLI 응답, 로컬 경로는 포함되지 않습니다.
- NAS 경로는 NAS 웹사이트가 발급한 로그인 세션 쿠키만 사용하며, 그 쿠키 값이나
  NAS 비밀번호를 앱의 저장소(UserDefaults·파일)에 직접 기록하지 않습니다. 로그인
  상태는 iOS의 웹 로그인 저장소가 관리합니다.

## 빌드

`CCMB.xcodeproj`를 Xcode 16 이상에서 열어 빌드합니다(iOS 17+, iPhone/iPad).
데이터 출처는 NAS 하나뿐이며 CloudKit·파일 제공자 관련 외부 설정은 필요하지
않습니다.

## TestFlight 관리 CLI (`scripts/testflight.py`)

App Store Connect API로 번들 ID `com.armsone.ccmb.ios`의 빌드 상태 조회,
Public Beta 그룹 등록, 베타 리뷰 제출을 돕는 표준 라이브러리 전용 Python
스크립트입니다. 업로드(Xcode/altool/xcrun)나 Git 작업은 포함하지 않습니다.

인증은 ES256 JWT(5분 유효, 메모리에서만 생성하고 파일로 출력하지 않음)를
사용하며, 키는 `openssl dgst -sha256 -sign`으로 서명합니다. 기본 키 경로와
ID는 대표님 로컬 키로 고정되어 있고, 필요하면 환경 변수로 덮어씁니다:

```sh
export CCMB_ASC_KEY_PATH=~/.private_keys/AuthKey_XXXX.p8
export CCMB_ASC_KEY_ID=XXXX
export CCMB_ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

사용법:

```sh
# 앱/빌드/공개 베타 그룹 상태 조회 (개인정보 없는 값만 출력)
python3 scripts/testflight.py status --build-number 202610011705

# 빌드를 Public Beta 그룹에 추가하고 한국어 WhatsNew·자동 알림 설정
python3 scripts/testflight.py prepare --build-number 202610011705 \
  --notes-file release-notes-0.2.0.md

# 베타 앱 리뷰 제출 (이미 제출돼 있으면 중복 제출하지 않음)
python3 scripts/testflight.py submit --build-number 202610011705
```

`prepare`는 빌드가 `VALID` 상태인지, Public Beta 그룹이 정확히 하나인지
확인한 뒤에만 진행하며, 모호하거나 조건이 안 맞으면 그룹을 새로 만들지
않고 오류로 안내합니다. 출력은 app ID·build ID·버전·처리 상태·베타 테스트
상태·그룹 이름/ID/공개 여부만 포함하고, 테스터나 리뷰 담당자 개인정보는
조회하지 않습니다.
