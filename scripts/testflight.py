#!/usr/bin/env python3
"""App Store Connect API CLI for CCMB-iOS TestFlight 관리.

표준 라이브러리만 사용한다 (urllib, json, hashlib, base64, subprocess).
원격 실행/업로드/Git 작업은 이 스크립트의 책임이 아니다.

사용법:
    python3 scripts/testflight.py status --build-number <번호>
    python3 scripts/testflight.py prepare --build-number <번호> --notes-file <파일>
    python3 scripts/testflight.py submit --build-number <번호>

환경 변수 (기본값은 대표님 로컬 키로 고정):
    CCMB_ASC_KEY_PATH  기본값 ~/.private_keys/AuthKey_6YU37JNN2D.p8
    CCMB_ASC_KEY_ID    기본값 6YU37JNN2D
    CCMB_ASC_ISSUER_ID 기본값 69a6de89-aa4c-47e3-e053-5b8c7c11a4d1
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API_BASE = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.armsone.ccmb.ios"

DEFAULT_KEY_PATH = os.path.expanduser("~/.private_keys/AuthKey_6YU37JNN2D.p8")
DEFAULT_KEY_ID = "6YU37JNN2D"
DEFAULT_ISSUER_ID = "69a6de89-aa4c-47e3-e053-5b8c7c11a4d1"


class ApiError(Exception):
    def __init__(self, status, errors):
        self.status = status
        self.errors = errors
        super().__init__(f"HTTP {status}")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_ecdsa_to_jose(der_sig: bytes, size: int = 32) -> bytes:
    # DER: 0x30 len 0x02 rlen r 0x02 slen s
    if der_sig[0] != 0x30:
        raise ValueError("서명 형식이 올바르지 않습니다 (DER SEQUENCE 아님)")
    idx = 2 if der_sig[1] < 0x80 else 2 + (der_sig[1] & 0x7F)
    if der_sig[idx] != 0x02:
        raise ValueError("서명 형식이 올바르지 않습니다 (r INTEGER 아님)")
    rlen = der_sig[idx + 1]
    r = der_sig[idx + 2: idx + 2 + rlen]
    idx = idx + 2 + rlen
    if der_sig[idx] != 0x02:
        raise ValueError("서명 형식이 올바르지 않습니다 (s INTEGER 아님)")
    slen = der_sig[idx + 1]
    s = der_sig[idx + 2: idx + 2 + slen]

    def fixed(b: bytes) -> bytes:
        b = b.lstrip(b"\x00")
        if len(b) > size:
            raise ValueError("정수 크기가 예상보다 큽니다")
        return b.rjust(size, b"\x00")

    return fixed(r) + fixed(s)


def generate_token(key_path: str, key_id: str, issuer_id: str) -> str:
    """ES256 JWT를 메모리에서만 생성한다 (파일 출력 없음, 5분 유효)."""
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 300,
        "aud": "appstoreconnect-v1",
    }
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    ).encode("ascii")

    with tempfile.NamedTemporaryFile(suffix=".sig", delete=True) as sig_file:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, "-out", sig_file.name],
            input=signing_input,
            capture_output=True,
        )
        if proc.returncode != 0:
            raise RuntimeError("JWT 서명 실패 (openssl 오류)")
        der_sig = sig_file.read()

    jose_sig = der_ecdsa_to_jose(der_sig)
    return signing_input.decode("ascii") + "." + b64url(jose_sig)


def api_request(token: str, method: str, path: str, params=None, body=None):
    url = API_BASE + path
    if params:
        query = urllib.parse.urlencode(params, doseq=True)
        url = f"{url}?{query}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
            errors = parsed.get("errors", [])
        except json.JSONDecodeError:
            errors = [{"code": str(e.code), "title": "HTTP 오류", "detail": raw.decode(errors="replace")}]
        raise ApiError(e.code, errors) from None


import urllib.parse  # noqa: E402  (urlencode 사용을 위해 뒤늦게 import)


def print_api_error(err: ApiError):
    for e in err.errors:
        print(
            f"오류 [{e.get('code', '?')}] {e.get('title', '')}: {e.get('detail', '')}",
            file=sys.stderr,
        )
    if not err.errors:
        print(f"오류 HTTP {err.status}", file=sys.stderr)


def get_app_id(token: str) -> str:
    resp = api_request(token, "GET", "/v1/apps", params={"filter[bundleId]": BUNDLE_ID})
    data = resp.get("data", [])
    if not data:
        raise RuntimeError(f"번들 ID {BUNDLE_ID} 에 해당하는 앱을 찾을 수 없습니다")
    return data[0]["id"]


def find_build(token: str, app_id: str, build_number: str):
    resp = api_request(
        token,
        "GET",
        "/v1/builds",
        params={
            "filter[app]": app_id,
            "filter[version]": build_number,
            "include": "preReleaseVersion,betaBuildLocalizations,betaAppReviewSubmission",
            "fields[builds]": "version,processingState,betaAppReviewSubmission,buildBetaDetail",
        },
    )
    data = resp.get("data", [])
    if not data:
        return None, resp
    return data[0], resp


def find_public_beta_group(token: str, app_id: str):
    resp = api_request(
        token,
        "GET",
        f"/v1/apps/{app_id}/betaGroups",
        params={"fields[betaGroups]": "name,isInternalGroup,publicLinkEnabled"},
    )
    public_groups = [g for g in resp.get("data", []) if not g["attributes"]["isInternalGroup"]]
    return public_groups


def cmd_status(args, token: str):
    app_id = get_app_id(token)
    groups = find_public_beta_group(token, app_id)

    print(f"appId: {app_id}")

    if args.build_number:
        build, build_resp = find_build(token, app_id, args.build_number)
        if build is None:
            print(f"buildId: (버전 {args.build_number} 빌드를 찾을 수 없음)")
        else:
            attrs = build["attributes"]
            print(f"buildId: {build['id']}")
            print(f"version: {attrs.get('version')}")
            print(f"processingState: {attrs.get('processingState')}")

            included = build_resp.get("included", [])
            betad = [i for i in included if i["type"] == "betaAppReviewSubmissions"]
            if betad:
                print(f"betaTestingState: {betad[0]['attributes'].get('betaReviewState')}")
            else:
                print("betaTestingState: (제출 없음)")

    print("betaGroups:")
    for g in groups:
        a = g["attributes"]
        print(
            f"  - name={a.get('name')} id={g['id']} isInternal={a.get('isInternalGroup')} "
            f"publicLinkEnabled={a.get('publicLinkEnabled')}"
        )


def get_group_builds(token: str, group_id: str):
    resp = api_request(token, "GET", f"/v1/betaGroups/{group_id}/relationships/builds")
    return {b["id"] for b in resp.get("data", [])}


def get_existing_localization(token: str, build_id: str, locale: str = "ko"):
    resp = api_request(
        token,
        "GET",
        "/v1/betaBuildLocalizations",
        params={"filter[build]": build_id, "filter[locale]": locale},
    )
    data = resp.get("data", [])
    return data[0] if data else None


def cmd_prepare(args, token: str):
    app_id = get_app_id(token)
    build, _ = find_build(token, app_id, args.build_number)
    if build is None:
        print(f"오류: 버전 {args.build_number} 빌드를 찾을 수 없습니다", file=sys.stderr)
        sys.exit(1)

    processing_state = build["attributes"].get("processingState")
    if processing_state != "VALID":
        print(f"오류: 빌드 처리 상태가 VALID가 아닙니다 (현재: {processing_state})", file=sys.stderr)
        sys.exit(1)

    build_id = build["id"]

    public_groups = find_public_beta_group(token, app_id)
    if len(public_groups) == 0:
        print("오류: Public Beta 그룹을 찾을 수 없습니다", file=sys.stderr)
        sys.exit(1)
    if len(public_groups) > 1:
        names = ", ".join(g["attributes"].get("name", "?") for g in public_groups)
        print(f"오류: Public Beta 그룹이 여러 개입니다 ({names}). 하나로 지정해 주세요.", file=sys.stderr)
        sys.exit(1)
    group = public_groups[0]
    group_id = group["id"]

    try:
        with open(args.notes_file, "r", encoding="utf-8") as f:
            notes = f.read().strip()
    except OSError as e:
        print(f"오류: 노트 파일을 읽을 수 없습니다 ({e})", file=sys.stderr)
        sys.exit(1)

    existing_loc = get_existing_localization(token, build_id, "ko")
    try:
        if existing_loc is not None:
            api_request(
                token,
                "PATCH",
                f"/v1/betaBuildLocalizations/{existing_loc['id']}",
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": existing_loc["id"],
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
            print(f"betaBuildLocalization 업데이트됨: {existing_loc['id']}")
        else:
            resp = api_request(
                token,
                "POST",
                "/v1/betaBuildLocalizations",
                body={
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": "ko", "whatsNew": notes},
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
            )
            print(f"betaBuildLocalization 생성됨: {resp['data']['id']}")

        build_beta_detail_id = build.get("relationships", {}).get("buildBetaDetail", {}).get("data", {}).get("id")
        if build_beta_detail_id:
            api_request(
                token,
                "PATCH",
                f"/v1/buildBetaDetails/{build_beta_detail_id}",
                body={
                    "data": {
                        "type": "buildBetaDetails",
                        "id": build_beta_detail_id,
                        "attributes": {"autoNotifyEnabled": True},
                    }
                },
            )
            print("buildBetaDetails autoNotifyEnabled=true 설정됨")
        else:
            print("경고: buildBetaDetail 관계를 찾을 수 없어 autoNotifyEnabled 설정을 건너뜁니다", file=sys.stderr)

        existing_build_ids = get_group_builds(token, group_id)
        if build_id in existing_build_ids:
            print(f"빌드가 이미 그룹 '{group['attributes'].get('name')}'에 포함되어 있습니다 (건너뜀)")
        else:
            api_request(
                token,
                "POST",
                f"/v1/betaGroups/{group_id}/relationships/builds",
                body={"data": [{"type": "builds", "id": build_id}]},
            )
            print(f"빌드를 그룹 '{group['attributes'].get('name')}'에 추가했습니다")

    except ApiError as e:
        print_api_error(e)
        sys.exit(1)

    print("prepare 완료")


def cmd_submit(args, token: str):
    app_id = get_app_id(token)
    build, build_resp = find_build(token, app_id, args.build_number)
    if build is None:
        print(f"오류: 버전 {args.build_number} 빌드를 찾을 수 없습니다", file=sys.stderr)
        sys.exit(1)

    processing_state = build["attributes"].get("processingState")
    if processing_state == "PROCESSING":
        print("오류: 빌드가 아직 처리 중입니다 (PROCESSING)", file=sys.stderr)
        sys.exit(1)
    if processing_state != "VALID":
        print(f"오류: 빌드 처리 상태가 VALID가 아닙니다 (현재: {processing_state})", file=sys.stderr)
        sys.exit(1)

    build_id = build["id"]

    included = build_resp.get("included", [])
    existing_submission = next(
        (i for i in included if i["type"] == "betaAppReviewSubmissions"), None
    )
    if existing_submission is not None:
        state = existing_submission["attributes"].get("betaReviewState")
        print(f"이미 제출된 리뷰가 있습니다 (상태: {state}). 추가 제출하지 않습니다.")
        return

    try:
        resp = api_request(
            token,
            "POST",
            "/v1/betaAppReviewSubmissions",
            body={
                "data": {
                    "type": "betaAppReviewSubmissions",
                    "relationships": {
                        "build": {"data": {"type": "builds", "id": build_id}}
                    },
                }
            },
        )
    except ApiError as e:
        print_api_error(e)
        sys.exit(1)

    print(f"betaAppReviewSubmission 생성됨: {resp['data']['id']}")
    print("submit 완료")


def build_arg_parser():
    parser = argparse.ArgumentParser(description="CCMB-iOS TestFlight 관리 CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="앱/빌드/베타그룹 상태 조회")
    p_status.add_argument("--build-number", help="조회할 빌드 번호(버전)")

    p_prepare = sub.add_parser("prepare", help="Public Beta 그룹에 빌드 추가 및 노트 설정")
    p_prepare.add_argument("--build-number", required=True)
    p_prepare.add_argument("--notes-file", required=True)

    p_submit = sub.add_parser("submit", help="베타 앱 리뷰 제출")
    p_submit.add_argument("--build-number", required=True)

    return parser


def main():
    parser = build_arg_parser()
    args = parser.parse_args()

    key_path = os.environ.get("CCMB_ASC_KEY_PATH", DEFAULT_KEY_PATH)
    key_id = os.environ.get("CCMB_ASC_KEY_ID", DEFAULT_KEY_ID)
    issuer_id = os.environ.get("CCMB_ASC_ISSUER_ID", DEFAULT_ISSUER_ID)

    if not os.path.isfile(key_path):
        print(f"오류: 키 파일을 찾을 수 없습니다 ({key_path})", file=sys.stderr)
        sys.exit(1)

    try:
        token = generate_token(key_path, key_id, issuer_id)
    except (RuntimeError, ValueError) as e:
        print(f"오류: 토큰 생성 실패 ({e})", file=sys.stderr)
        sys.exit(1)

    try:
        if args.command == "status":
            cmd_status(args, token)
        elif args.command == "prepare":
            cmd_prepare(args, token)
        elif args.command == "submit":
            cmd_submit(args, token)
    except ApiError as e:
        print_api_error(e)
        sys.exit(1)
    except RuntimeError as e:
        print(f"오류: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
