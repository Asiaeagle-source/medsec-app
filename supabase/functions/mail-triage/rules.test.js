// ============================================================
// mail-triage 規則單元測試 — 分院名稱解析 (splitBranchTokens)
// ------------------------------------------------------------
// 只測純字串解析(不查 DB),驗證「主名 + 分院地名」拆解正確。
// 跑法:node --test  (或 npm test)
// ============================================================
import { test } from "node:test";
import assert from "node:assert/strict";
import { splitBranchTokens } from "./rules.js";

// 每筆:輸入名稱 → 期望地名 loc + mains 應含的主名候選
const CASES = [
  // --- 馬偕體系:地名緊貼「分院」前(原本就對,確保不回歸)---
  { name: "馬偕淡水分院",        loc: "淡水", wantMain: "馬偕紀念" },
  { name: "成大斗六分院",        loc: "斗六", wantMain: "成功大學" },

  // --- 臺大體系:地名在主名之後(原「前 2 字」邏輯會拿到臺大而失效)---
  { name: "新竹臺大分院",        loc: "新竹", wantMain: "臺灣大學" },
  { name: "臺大新竹臺大分院",    loc: "新竹", wantMain: "臺灣大學" },

  // --- 括號別名要先去掉,地名取雲林而非括號裡的斗六 ---
  { name: "臺大雲林分院(斗六)",  loc: "雲林", wantMain: "臺灣大學" },
  { name: "臺大雲林分院（斗六）", loc: "雲林", wantMain: "臺灣大學" },  // 全形括號

  // --- 主名含地名(高雄),地名要取最靠近「分院」的台南,不是高雄 ---
  { name: "高雄榮總台南分院",    loc: "台南", wantMain: "高雄榮民" },

  // --- 國泰:單純主名 + 地名 ---
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

// 括號裡的別名不可被誤當地名
test("splitBranchTokens: 括號別名不被當地名 (雲林分院(斗六) → 雲林,不是斗六)", () => {
  const got = splitBranchTokens("臺大雲林分院(斗六)");
  assert.equal(got.loc, "雲林");
  assert.notEqual(got.loc, "斗六");
});

// 非分院 / 空值 → null(交給 A 段整段 ilike 或 C 段去通用詞)
test("splitBranchTokens: 非分院名稱回 null", () => {
  assert.equal(splitBranchTokens("林口長庚"), null);
  assert.equal(splitBranchTokens("臺北榮民總醫院"), null);
});

test("splitBranchTokens: 空值回 null", () => {
  assert.equal(splitBranchTokens(""), null);
  assert.equal(splitBranchTokens(null), null);
  assert.equal(splitBranchTokens(undefined), null);
});

// 認不出已知地名 → null(避免亂拆)
test("splitBranchTokens: 分院但地名不在清單 → null", () => {
  assert.equal(splitBranchTokens("某某未知分院"), null);
});
