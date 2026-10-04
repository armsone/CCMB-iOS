# CCMB for iPhone

Mac 메뉴 막대 앱 [CCMB](../CCMB-MacOS)의 원격 동반 대시보드입니다.
Mac의 CCMB가 Codex·Claude·Gemini(그리고 보조로 Grok)의 남은 사용량을 읽어
사용자의 iCloud **개인 데이터베이스**에 올리면, 같은 Apple ID로 로그인한
iPhone이 어디서든 그 값을 읽어 보여 줍니다.

## 사용 방법 (주 경로: iCloud 원격 동기화)

1. iPhone과 Mac을 **같은 Apple ID**로 iCloud에 로그인합니다.
2. Mac에서 CCMB를 실행하고 메뉴의 **iPhone 원격 동기화**가 켜져 있는지 확인합니다.
3. iPhone에서 CCMB를 열고 **iCloud에서 불러오기**를 누릅니다. 이후에는 앱을
   열거나, 전경으로 돌아오거나, 당겨서 새로 고침할 때마다 최신 값을 읽습니다.

값은 Mac이 켜져 있고 CCMB가 새 사용량을 올려야 갱신됩니다. iPhone은 서비스에
직접 조회하지 않고, iCloud에 쓰지도 않습니다(읽기 전용).

## 보조 원격 경로: Dropbox·Google Drive·iCloud Drive

Mac CCMB의 **iPhone 원격 동기화 → Dropbox·Google Drive 폴더 선택…**에서
파일 제공자 폴더를 한 번 선택하면 `CCMB-usage-v1.json`을 자동 갱신합니다. iPhone은
Files 앱에서 같은 파일을 한 번 선택한 뒤 새로 고침할 때마다 다시 읽습니다. Dropbox,
Google Drive, iCloud Drive, OneDrive 등 Files/파일 앱에 나타나는 제공자를 같은 코드로
지원하며 CCMB는 서비스 OAuth 토큰이나 비밀번호를 받지 않습니다.

## 세 번째 경로: NAS

Mac·iCloud와 무관하게, 놀이터 웹사이트(`https://hanstree.synology.me:5443`)를
직접 운영 중인 NAS에서 남은 사용량을 읽어올 수 있습니다.

1. 메뉴(≡) 또는 첫 화면의 **NAS에서 불러오기**를 누릅니다.
2. 아직 로그인되어 있지 않으면 NAS 웹사이트의 로그인 화면이 그대로 뜹니다. 평소
   쓰던 비밀번호로 로그인하면 창이 자동으로 닫히고 사용량을 불러옵니다.
3. 이후에는 iCloud·파일과 동일하게 자동 새로 고침·당겨서 새로 고침이 동작합니다.
   세션은 iOS의 웹 로그인 저장소에 남아 있어 보통 다시 로그인할 필요가 없습니다.
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

- **가장 먼저 소진될 한도**: 실제 값이 있는 주요 한도 중 남은 비율이 가장 낮은
  항목을 홈 상단에 가장 크게 표시합니다.
- **Codex**: 세션(현재 Mac 데이터에 필드가 없어 "Mac 데이터에서 제공되지 않음"으로
  표시) · 주간 · 크레딧 잔액.
- **Claude**: 5시간 세션 · Fable 주간(모델별 주간 한도에서) · 전체 주간.
- **Gemini**: 5시간 세션 · 주간 · AI 크레딧 잔액.
- **Grok**: 보조 카드로 요약만 표시. 각 카드와 세부 화면에 초기화 시각과
  데이터 기준 시각을 함께 보여 줍니다.

원격 실패 시 마지막 정상 스냅샷을 유지하고, iCloud 미로그인·네트워크 없음·
레코드 없음·컨테이너 설정 오류·오래된 데이터를 구분해 할 일을 먼저 안내합니다.

## 개인정보

- 동기화 데이터는 사용자 본인 Apple ID의 iCloud 개인 영역에만 저장되며 전송과
  저장은 Apple이 보호합니다. 다른 사용자·공개 DB에는 어떤 데이터도 올라가지 않습니다.
- 스냅샷에는 남은 비율·초기화 시각·크레딧 잔액 등 표시용 값만 있습니다. 토큰,
  쿠키, OAuth 자격증명, 원시 CLI 응답, 로컬 경로는 포함되지 않습니다.
- 기록은 쌓이지 않습니다. Mac은 고정 레코드 하나(`latest-usage-v1`)를 덮어씁니다.
- NAS 경로는 NAS 웹사이트가 발급한 로그인 세션 쿠키만 사용하며, 그 쿠키 값이나
  NAS 비밀번호를 앱의 저장소(UserDefaults·파일)에 직접 기록하지 않습니다. 로그인
  상태는 iOS의 웹 로그인 저장소가 관리합니다.

## 빌드와 남은 외부 설정

`CCMB.xcodeproj`를 Xcode 16 이상에서 열어 빌드합니다(iOS 17+, iPhone/iPad).
CloudKit 소스와 entitlement(`CCMB/CCMB.entitlements`, 컨테이너
`iCloud.com.armsone.ccmb`)는 준비되어 있지만, 다음은 Apple Developer 계정의
**외부 설정으로 아직 남아 있습니다**:

1. 컨테이너 `iCloud.com.armsone.ccmb`를 Apple Developer 계정에 등록하고
   iOS·macOS 두 앱 식별자에 활성화.
2. 두 앱의 서명/프로비저닝 프로파일에 iCloud capability 반영
   (Mac 쪽은 `CCMB-MacOS/Configuration/CCMB.entitlements` 참고).
3. CloudKit Console에서 레코드 타입 `CCMBUsageSnapshot` 스키마를 development에서
   production으로 배포.

이 설정이 끝나기 전에는 원격 동기화가 동작하지 않고, 앱은 그 상태를 컨테이너
설정 오류로 안내합니다.

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
