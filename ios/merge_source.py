"""다른 앱(현장내비)의 SideStore 소스를 받아 이 저장소의 source.json에 합친다.
사용법: merge_source.py 소스주소 [소스주소 ...] 출력파일
현장내비 저장소는 비공개라 ipa와 소스를 Cloudflare Pages(site-navi.pages.dev/app/)에 올리고,
여기서 그 소스를 읽어 같은 앱(bundleIdentifier) 항목만 바꿔 끼운다. 받기 실패하면 그대로 둔다."""
import json, sys, urllib.request

urls, out = sys.argv[1:-1], sys.argv[-1]
with open(out, encoding="utf-8") as f:
    source = json.load(f)
apps = source.get("apps", [])

for url in urls:
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            incoming = json.load(r).get("apps", [])
    except Exception as e:
        print(f"건너뜀 {url}: {e}")
        continue
    for app in incoming:
        bid = app.get("bundleIdentifier")
        apps = [a for a in apps if a.get("bundleIdentifier") != bid] + [app]

source["apps"] = apps
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
