이 프로젝트에서 작업을 시작하기 전에 `/Users/armsone/git/AGENTS.md` 전체를 먼저 읽고 그 내용을 그대로 준수한다.

# CCMB-iOS 작업 지침

CCMB-iOS는 Mac 메뉴 막대 앱 CCMB(`/Users/armsone/git/CCMB-MacOS`)의 원격 동반 대시보드다.
Mac이 CLI 사용량을 읽어 사용자의 CloudKit 개인 데이터베이스에 스냅샷을 올리고,
iPhone은 같은 Apple ID의 개인 데이터베이스에서 읽기만 한다.

## 아키텍처 원칙

- **주 경로는 CloudKit, 보조 경로는 File Provider 파일.** `Store/CloudKitSync.swift`가
  개인 DB의 고정 레코드 하나를 읽고, `Store/SnapshotStore.swift`가 상태를 소유한다.
  Dropbox·Google Drive·iCloud Drive 등의 `CCMB-usage-v1.json`을 Files 앱에서 한 번
  선택하고 보안 bookmark로 다시 읽는 흐름을 보조 원격 수단으로 유지한다.
- **iPhone은 절대 쓰지 않는다.** CloudKit 업로드는 Mac 쪽 `CloudSyncUploader.swift`만 한다.
  공개 데이터베이스는 어느 쪽에서도 사용하지 않는다.
- **CloudKit 계약은 두 저장소가 동일해야 한다.** 컨테이너 `iCloud.com.armsone.ccmb`,
  레코드 타입 `CCMBUsageSnapshot`, 레코드 이름 `latest-usage-v1`, 필드
  `schemaVersion`/`snapshot`/`macPublishedAt`/`macAppVersion`. 한쪽을 바꾸면 반드시
  다른 쪽도 함께 바꾼다.
- **스냅샷 스키마는 Mac의 `usage-v1.json` schemaVersion 1이다.** 토큰, 쿠키, OAuth
  자격증명, 원시 CLI 응답, 로컬 경로는 스키마에 없고 앞으로도 넣지 않는다.
- **실패해도 마지막 정상 스냅샷을 유지한다.** 오류 메시지는 사용자가 할 행동을
  먼저 쓴다(iCloud 로그인, Mac 실행 확인, 네트워크 확인 등).

## 화면 정보 구조

- 홈 상단: 실제 값이 있는 주요 한도 중 남은 비율이 가장 낮은 것 하나를
  `가장 먼저 소진될 한도` 카드로 크게 보여 준다(Grok 제외).
- Codex 카드: 세션(데이터 없으면 "Mac 데이터에서 제공되지 않음") → 주간 → 크레딧.
- Claude 카드: 5시간 세션 → Fable 주간(`modelWeeklyLimits`에서) → 전체 주간.
- Gemini 카드: 5시간 세션 → 주간 → AI 크레딧. Grok은 보조 카드.
- `#E41E25`(signal red)는 낮은 잔량·오류·핵심 포인트에만 쓴다. Dynamic Type,
  VoiceOver, 다크 모드, iPad 적응형 레이아웃을 유지한다.

## 하지 말 것

- Mac 저장소의 기존 사용량 수집·메뉴 기능 리팩터링, 빌드 스크립트 수정.
- 새 서드파티 의존성 추가.
- CloudKit push/subscription 알림(현재 범위 밖: 열 때/새로 고침 때 읽으면 충분).
