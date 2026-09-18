import CloudKit
import Foundation

/// The one CloudKit contract shared with the Mac app. The Mac's
/// CloudSyncUploader writes exactly these constants; changing any value here
/// without changing the Mac side breaks the remote path silently.
enum CCMBCloudKit {
    /// Same constant in CCMB-MacOS `CloudSyncUploader.swift`.
    static let containerIdentifier = "iCloud.com.armsone.ccmb"
    static let recordType = "CCMBUsageSnapshot"
    /// Fixed record name: the Mac overwrites this one record instead of
    /// appending history, so the private database never grows.
    static let recordName = "latest-usage-v1"

    enum Field {
        static let schemaVersion = "schemaVersion"
        /// The full `usage-v1.json` bytes, unchanged. No tokens, cookies,
        /// OAuth credentials, raw CLI responses, or local paths are ever in
        /// that file's schema, so none can end up in CloudKit.
        static let snapshot = "snapshot"
        static let macPublishedAt = "macPublishedAt"
        static let macAppVersion = "macAppVersion"
    }
}

/// Reasons the phone could not read the Mac's snapshot from iCloud. Each
/// message leads with what the user should do; the technical cause follows.
enum CloudFetchError: LocalizedError {
    case notSignedIn
    case restricted
    case network
    case noRecordYet
    case containerMisconfigured
    case unreadableRecord
    case other(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "설정 앱에서 Mac과 같은 Apple ID로 iCloud에 로그인해 주세요. 지금은 iCloud 계정을 사용할 수 없습니다."
        case .restricted:
            return "iCloud 사용이 제한된 기기입니다. 스크린 타임/프로파일 제한을 확인해 주세요."
        case .network:
            return "네트워크에 연결한 뒤 다시 시도해 주세요. iCloud에 접속하지 못했습니다."
        case .noRecordYet:
            return "Mac에서 CCMB를 실행하고 메뉴의 iPhone 원격 동기화가 켜져 있는지 확인해 주세요. iCloud에 아직 업로드된 사용량이 없습니다."
        case .containerMisconfigured:
            return "앱의 iCloud 컨테이너 설정이 완료되지 않았습니다. Apple Developer 계정에서 iCloud.com.armsone.ccmb 컨테이너 등록과 서명이 필요합니다."
        case .unreadableRecord:
            return "Mac의 CCMB를 최신 버전으로 업데이트해 주세요. iCloud의 사용량 데이터를 이 버전의 앱이 읽을 수 없습니다."
        case .other(let message):
            return "잠시 후 다시 시도해 주세요. iCloud 오류: \(message)"
        }
    }
}

/// What one successful CloudKit read carries back to the store.
struct CloudFetchResult {
    let data: Data
    let macPublishedAt: Date?
    let macAppVersion: String?
}

/// Reads the single latest-snapshot record from the user's own CloudKit
/// private database. Read-only by design: the phone never writes, so a phone
/// bug can never corrupt what the Mac published.
struct CloudSnapshotClient {
    func fetchLatest() async throws -> CloudFetchResult {
        let container = CKContainer(identifier: CCMBCloudKit.containerIdentifier)

        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            throw classify(error)
        }
        switch accountStatus {
        case .available:
            break
        case .noAccount, .temporarilyUnavailable:
            throw CloudFetchError.notSignedIn
        case .restricted:
            throw CloudFetchError.restricted
        case .couldNotDetermine:
            throw CloudFetchError.other("계정 상태를 확인할 수 없습니다.")
        @unknown default:
            throw CloudFetchError.other("계정 상태를 확인할 수 없습니다.")
        }

        let recordID = CKRecord.ID(recordName: CCMBCloudKit.recordName)
        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: recordID)
        } catch {
            throw classify(error)
        }

        guard let schemaVersion = record[CCMBCloudKit.Field.schemaVersion] as? Int64,
              schemaVersion == 1,
              let data = record[CCMBCloudKit.Field.snapshot] as? Data else {
            throw CloudFetchError.unreadableRecord
        }
        return CloudFetchResult(
            data: data,
            macPublishedAt: record[CCMBCloudKit.Field.macPublishedAt] as? Date,
            macAppVersion: record[CCMBCloudKit.Field.macAppVersion] as? String
        )
    }

    private func classify(_ error: Error) -> CloudFetchError {
        guard let ckError = error as? CKError else {
            return .other(error.localizedDescription)
        }
        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .network
        case .unknownItem, .zoneNotFound:
            // The record (or even the default zone) does not exist until the
            // Mac's first successful upload.
            return .noRecordYet
        case .notAuthenticated:
            return .notSignedIn
        case .badContainer, .missingEntitlement, .permissionFailure, .badDatabase, .managedAccountRestricted:
            return .containerMisconfigured
        default:
            return .other(ckError.localizedDescription)
        }
    }
}
