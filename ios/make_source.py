"""SideStore 소스(source.json) 생성. 사용법: make_source.py 버전 ipa주소 ipa크기 출력파일"""
import json, sys, datetime

version, url, size, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
repo = "https://github.com/josang0909-svg/sahsid-cydwi1-defTom"
date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
icon = "https://raw.githubusercontent.com/josang0909-svg/sahsid-cydwi1-defTom/main/icon-512.png"

source = {
    "name": "현장 보드판",
    "identifier": "com.josang0909.fieldboard.source",
    "website": repo,
    "apps": [{
        # SideStore가 이 이름으로 애플 App ID를 만들 수 있어 영문만 사용
        "name": "FieldBoard",
        "bundleIdentifier": "com.josang0909.fieldboard",
        "developerName": "josang0909",
        "localizedDescription": "현장 보드판: 현장 사진 보드판 (개인용)",
        "iconURL": icon,
        "version": version,
        "versionDate": date,
        "downloadURL": url,
        "size": size,
        "versions": [{
            "version": version,
            "date": date,
            "downloadURL": url,
            "size": size,
            "minOSVersion": "15.0",
        }],
    }],
    "news": [],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
