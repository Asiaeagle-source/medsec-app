// ============================================================
// mail-triage 規則單元測試 — 分院名稱解析
// ------------------------------------------------------------
// 只測純函式(不查 DB):
//   splitBranchTokens — 把「XX分院」拆成 { 主名候選, 分院地名 }
//   pickBranchRow     — 從撈回的候選列挑出正確分院(含生醫園區排除)
// 跑法:node --test  (或 npm test)
// ============================================================
import { test } from "node:test";
import assert from "node:assert/strict";
import { splitBranchTokens, pickBranchRow } from "./rules.js";

// ---- splitBranchTokens:主名 + 地名拆解 ----
const CASES = [
  // 馬偕體系:地名緊貼「分院」前(原本就對,確保不回歸)
  { name: "馬偕淡水分院",        loc: "淡水", wantMain: "馬偕紀念" },
  { name: "成大斗六分院",        loc: "斗六", wantMain: "成功大學" },
  // 臺大體系:地名在主名之後(原「前 2 字」邏輯會拿到臺大而失效)
  { name: "新竹臺大分院",        loc: "新竹", wantMain: "臺灣大學" },
  { name: "臺大新竹臺大分院",    loc: "新竹", wantMain: "臺灣大學" },
  // 括號別名要先去掉,地名取雲林而非括號裡的斗六
  { name: "臺大雲林分院(斗六)",  loc: "雲林", wantMain: "臺灣大學" },
  { name: "臺大雲林分院（斗六）", loc: "雲林", wantMain: "臺灣大學" },  // 全形括號
  // 主名含地名(高雄),地名要取最靠近「分院」的台南
  { name: "高雄榮總台南分院",    loc: "台南", wantMain: "高雄榮民" },
  { name: "國泰汐止分院",        loc: "汐止", wantMain: "國泰" },
];

for (const c of CASES) {
  test(`splitBranchTokens: ${c.name} → 地名 ${c.loc} / 主名含 ${c.wantMain}`, () => {
    const got = splitBranchTokens(c.name);
    assert.ok(got, `${c.name} 應解析出分院 token,不該是 null`);
    assert.equal(got.loc, c.loc, `${c.name} 分院地名應是 ${c.loc},實得 ${got.loc}`);
    assert.ok(
      got.mains.includes(c.wantMain),
      `${c.name} 主名候選應含 ${c.wantMain},實得 [${got.mains.join(", ")}]`
    );
  });
}

// 主名正規化後應同時含 台大 / 臺大 / 臺灣大學(全形半形都要能對 name_short/name_full)
test("splitBranchTokens: 臺大主名候選含 台大 + 臺大 + 臺灣大學", () => {
  const got = splitBranchTokens("臺大雲林分院(斗六)");
  for (const w of ["台大", "臺大", "臺灣大學"]) {
    assert.ok(got.mains.includes(w), `mains 應含 ${w},實得 [${got.mains.join(", ")}]`);
  }
});

test("splitBranchTokens: 括號別名不被當地名 (雲林分院(斗六) → 雲林,不是斗六)", () => {
  const got = splitBranchTokens("臺大雲林分院(斗六)");
  assert.equal(got.loc, "雲林");
  assert.notEqual(got.loc, "斗六");
});

test("splitBranchTokens: 非分院 / 空值 / 未知地名 → null", () => {
  assert.equal(splitBranchTokens("林口長庚"), null);
  assert.equal(splitBranchTokens("臺北榮民總醫院"), null);
  assert.equal(splitBranchTokens(""), null);
  assert.equal(splitBranchTokens(null), null);
  assert.equal(splitBranchTokens(undefined), null);
  assert.equal(splitBranchTokens("某某未知分院"), null);
});

// ---- pickBranchRow:從候選列挑正確分院 ----
// 模擬 medsec_hospitals 實際資料(name_short 常用半形「台」)
const ROWS = {
  NTHN: { id: "NTHN", name_short: "台大新竹",     name_full: "國立臺灣大學醫學院附設醫院新竹分院" },
  NTNN: { id: "NTNN", name_short: "台大新竹生醫", name_full: "國立臺灣大學醫學院附設醫院新竹生醫園區分院" },
  NTYM: { id: "NTYM", name_short: "台大雲林",     name_full: "國立臺灣大學醫學院附設醫院雲林分院" },
  VGTS: { id: "VGTS", name_short: "永榮",         name_full: "高雄榮民總醫院臺南分院(永康榮民醫院)" },
  CAXN: { id: "CAXN", name_short: "國泰汐止",     name_full: "國泰綜合醫院汐止分院" },
};
const pick = (rawName, rows) => pickBranchRow(rows, splitBranchTokens(rawName), rawName);

test("pickBranchRow: 臺大雲林分院(斗六) → NTYM", () => {
  assert.equal(pick("臺大雲林分院(斗六)", [ROWS.NTYM, ROWS.VGTS])?.id, "NTYM");
});

test("pickBranchRow: 高雄榮總台南分院 → VGTS", () => {
  assert.equal(pick("高雄榮總台南分院", [ROWS.VGTS, ROWS.NTYM])?.id, "VGTS");
});

test("pickBranchRow: 國泰汐止分院 → CAXN", () => {
  assert.equal(pick("國泰汐止分院", [ROWS.CAXN])?.id, "CAXN");
});

// edge case:新竹 vs 新竹生醫。來信「新竹臺大分院」要中 NTHN,不可誤中 NTNN(生醫園區)。
test("pickBranchRow: 新竹臺大分院 → NTHN,排除生醫園區 NTNN(順序無關)", () => {
  assert.equal(pick("新竹臺大分院", [ROWS.NTHN, ROWS.NTNN])?.id, "NTHN");
  assert.equal(pick("新竹臺大分院", [ROWS.NTNN, ROWS.NTHN])?.id, "NTHN");
});

test("pickBranchRow: 指名生醫時才回 NTNN(新竹臺大生醫分院)", () => {
  assert.equal(pick("新竹臺大生醫分院", [ROWS.NTHN, ROWS.NTNN])?.id, "NTNN");
});

test("pickBranchRow: 只剩生醫園區但沒指名 → null(不亂猜)", () => {
  assert.equal(pick("新竹臺大分院", [ROWS.NTNN]), null);
});

test("pickBranchRow: 主名對不上 → null", () => {
  assert.equal(pick("國泰汐止分院", [ROWS.NTYM]), null);
  assert.equal(pickBranchRow([], splitBranchTokens("國泰汐止分院"), "國泰汐止分院"), null);
});
