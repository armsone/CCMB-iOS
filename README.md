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
