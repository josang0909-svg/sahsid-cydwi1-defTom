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
 * 스크립트를 고친 뒤에는 [배포] → [배포 관리] → 연필 → 버전 [새 버전] → [배포]로 다시 배포해야 반영됩니다.
 * (주소는 그대로입니다)
 *
 * 시트 구성
 *  시설물 종류마다 탭 하나 (탭 이름 = 시설물 종류, 탭 순서 = 앱 순서)
 *    1행: 부재명을 가로로 (A1, B1, C1 …)
 *    그 아래: 각 부재의 손상명을 세로로
 *  '시설명' 탭: 1행에 시설물 종류, 그 아래 시설명을 세로로
 *  '_앱백업' 탭(숨김): 위치 양식까지 담은 앱 목록 전체. 직접 고치지 마세요.
 *  새 시설물 종류는 탭을 추가하고 이름을 종류 이름으로 지으면 됩니다.
 */
var SITES = '시설명', BACKUP = '_앱백업', OLD_LIST = '목록';
var RESERVED = [SITES, BACKUP, OLD_LIST];

function doGet() {
  try {
    var ss = SpreadsheetApp.getActive();
    var cats = [];
    ss.getSheets().forEach(function (sh) {
      var name = sh.getName().trim();
      if (RESERVED.indexOf(name) >= 0 || sh.isSheetHidden() || !name) return;
      var cols = columns(sh);
      if (!cols.length && !isCatTab(sh)) return;   // 1행이 비어 있는 탭(예: 시트1)은 건너뜀
      cats.push({ name: name, members: cols.map(function (c) { return { name: c.head, notes: c.items }; }) });
    });
    var s = ss.getSheetByName(SITES), sites = null;
    if (s) {
      sites = {};
      columns(s).forEach(function (c) { sites[c.head] = (sites[c.head] || []).concat(c.items); });
    }
    var b = ss.getSheetByName(BACKUP);
    return out({ ok: true, cats: cats, sites: sites, backup: b ? readBackup(b) : '' });
  } catch (err) {
    return out({ ok: false, error: String(err && err.message || err) });
  }
}

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    var d = JSON.parse(e.postData.contents);
    if (!d || !Array.isArray(d.cats) || !d.cats.length) throw new Error('보낸 목록이 비어 있습니다');
    lock.waitLock(20000);
    var ss = SpreadsheetApp.getActive();
    // 백업을 먼저 쓴다: 백업 쓰기가 실패하면 보이는 탭은 그대로 남는다
    writeBackup(sheet(BACKUP), String(d.backup || ''));

    var names = d.cats.map(function (c) { return String(c.name).trim(); });
    d.cats.forEach(function (c, i) {
      var sh = sheet(names[i]);
      putColumns(sh, (c.members || []).map(function (m) { return { head: m.name, items: m.notes || [] }; }));
      if (sh.isSheetHidden()) sh.showSheet();
      ss.setActiveSheet(sh); ss.moveActiveSheet(i + 1);   // 탭 순서 = 앱 순서
    });
    var siteMap = d.siteMap || {};
    var s = sheet(SITES);
    putColumns(s, names.map(function (n) { return { head: n, items: siteMap[n] || [] }; }));
    ss.setActiveSheet(s); ss.moveActiveSheet(names.length + 1);

    // 앱에 없는 종류 탭·예전 '목록' 탭·빈 기본 탭은 지운다
    ss.getSheets().forEach(function (sh) {
      var n = sh.getName().trim();
      if (n === SITES || n === BACKUP || names.indexOf(n) >= 0) return;
      if (n === OLD_LIST || sh.getLastRow() === 0 || isCatTab(sh)) ss.deleteSheet(sh);
    });
    ss.setActiveSheet(ss.getSheetByName(names[0]));
    return out({ ok: true, at: new Date().toISOString() });
  } catch (err) {
    return out({ ok: false, error: String(err && err.message || err) });
  } finally {
    try { lock.releaseLock(); } catch (x) {}
  }
}

// 이 스크립트가 만든 종류 탭인지 (1행 고정 + 첫 칸이 굵게)
function isCatTab(sh) {
  return sh.getFrozenRows() === 1 && sh.getRange(1, 1).getFontWeight() === 'bold';
}

function sheet(name) {
  var ss = SpreadsheetApp.getActive();
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

// 1행 제목 아래로 세로 목록 읽기 → [{head, items}] (제목이 같은 열은 합침)
function columns(sh) {
  var lr = sh.getLastRow(), lc = sh.getLastColumn();
  if (lr < 1 || lc < 1) return [];
  var v = sh.getRange(1, 1, lr, lc).getDisplayValues();
  var out = [], byHead = {};
  for (var c = 0; c < lc; c++) {
    var head = String(v[0][c]).trim();
    if (!head) continue;
    var col = byHead[head];
    if (!col) { col = byHead[head] = { head: head, items: [] }; out.push(col); }
    for (var r = 1; r < lr; r++) {
      var x = String(v[r][c]).trim();
      if (x && col.items.indexOf(x) < 0) col.items.push(x);
    }
  }
  return out;
}

function putColumns(sh, cols) {
  sh.clear();
  var w = Math.max(cols.length, 1);
  var h = 1 + cols.reduce(function (m, c) { return Math.max(m, c.items.length); }, 0);
  var vals = [];
  for (var r = 0; r < h; r++) {
    var row = [];
    for (var c = 0; c < w; c++) {
      var col = cols[c];
      row.push(!col ? '' : r === 0 ? String(col.head) : (col.items[r - 1] == null ? '' : String(col.items[r - 1])));
    }
    vals.push(row);
  }
  // 글자 서식으로 넣어야 '=' '0' 등으로 시작하는 이름이 수식·숫자로 바뀌지 않는다
  sh.getRange(1, 1, h, w).setNumberFormat('@').setValues(vals).setWrap(true).setVerticalAlignment('top');
  sh.getRange(1, 1, 1, w).setFontWeight('bold').setBackground('#e8eef0');
  sh.setFrozenRows(1);
  sh.setColumnWidths(1, w, 150);
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
