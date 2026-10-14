/**
 * 현장 보드판 ↔ 구글 시트 목록 연동 (Apps Script)
 *
 * 붙이는 법
 *  1. 구글 시트를 새로 만들고 [확장 프로그램] → [Apps Script]를 엽니다.
 *  2. 편집기 내용을 모두 지우고 이 파일 내용을 붙여 넣은 뒤 저장합니다.
 *  3. [배포] → [새 배포] → 유형 [웹 앱]
 *       다음 사용자 인증 정보로 실행: 나
 *       액세스 권한이 있는 사용자: 모든 사용자
 *     → [배포] → 권한 허용 → 나오는 "웹 앱 URL"(…/exec)을 복사합니다.
 *  4. 앱 홈 화면 [목록 백업 (구글 시트)]에 그 주소를 붙여 넣고 [시트로 올리기]를 누릅니다.
 *
 * 시트 구성
 *  '목록'    시설물 종류 | 부재명 | 손상명   (한 줄에 손상 하나. 손상이 없는 부재는 손상명 칸을 비움)
 *  '시설명'  시설물 종류 | 시설명
 *  '_앱백업' (숨김) 위치 양식까지 담은 앱 목록 전체. 직접 고치지 마세요.
 *
 * 스크립트를 고친 뒤에는 [배포] → [배포 관리] → 연필 → 버전 [새 버전]으로 다시 배포해야 반영됩니다.
 */
var LIST = '목록', SITES = '시설명', BACKUP = '_앱백업';
var LIST_HEAD = ['시설물 종류', '부재명', '손상명'];
var SITES_HEAD = ['시설물 종류', '시설명'];

function doGet() {
  try {
    var ss = SpreadsheetApp.getActive();
    var l = ss.getSheetByName(LIST), s = ss.getSheetByName(SITES), b = ss.getSheetByName(BACKUP);
    return out({
      ok: true,
      list: l ? rows(l, 3) : [],
      sites: s ? rows(s, 2) : null,   // 탭이 없으면 null → 앱은 기존 시설명을 유지
      backup: b ? readBackup(b) : ''
    });
  } catch (err) {
    return out({ ok: false, error: String(err) });
  }
}

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    var d = JSON.parse(e.postData.contents);
    if (!d || !Array.isArray(d.list) || !d.list.length) throw new Error('보낸 목록이 비어 있습니다');
    lock.waitLock(20000);
    // 백업을 먼저 쓴다: 백업 쓰기가 실패하면 보이는 탭은 그대로 남는다
    writeBackup(sheet(BACKUP), String(d.backup || ''));
    put(sheet(LIST), LIST_HEAD, d.list);
    put(sheet(SITES), SITES_HEAD, Array.isArray(d.sites) ? d.sites : []);
    return out({ ok: true, at: new Date().toISOString() });
  } catch (err) {
    return out({ ok: false, error: String(err && err.message || err) });
  } finally {
    try { lock.releaseLock(); } catch (x) {}
  }
}

function sheet(name) {
  var ss = SpreadsheetApp.getActive();
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

// 머리줄 아래, 내용이 하나라도 있는 줄만 (보이는 그대로의 글자로)
function rows(sh, n) {
  var last = sh.getLastRow();
  if (last < 2) return [];
  return sh.getRange(2, 1, last - 1, n).getDisplayValues().filter(function (r) {
    return r.some(function (v) { return String(v).trim() !== ''; });
  });
}

function put(sh, head, data) {
  sh.clearContents();
  sh.getRange(1, 1, 1, head.length).setValues([head]).setFontWeight('bold');
  sh.setFrozenRows(1);
  if (!data.length) return;
  var vals = data.map(function (r) {
    return head.map(function (_, i) { return r[i] == null ? '' : String(r[i]); });
  });
  // 글자 서식으로 넣어야 '=' '0' 등으로 시작하는 이름이 수식·숫자로 바뀌지 않는다
  sh.getRange(2, 1, vals.length, head.length).setNumberFormat('@').setValues(vals);
}

// 셀 하나에 5만 자까지라 4만 자씩 A열 여러 칸에 나눠 둔다
var CHUNK = 40000;
function writeBackup(b, text) {
  var parts = [];
  for (var i = 0; i < text.length; i += CHUNK) parts.push([text.substr(i, CHUNK)]);
  if (!parts.length) parts.push(['']);
  b.clearContents();
  b.getRange(1, 1, parts.length, 1).setNumberFormat('@').setValues(parts);
  if (!b.isSheetHidden()) b.hideSheet();
}
function readBackup(b) {
  var n = b.getLastRow();
  if (n < 1) return '';
  return b.getRange(1, 1, n, 1).getValues().map(function (r) { return String(r[0] || ''); }).join('');
}

function out(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
