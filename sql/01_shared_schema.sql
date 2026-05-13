-- ============================================================
-- AE Hub · 共用底層 schema（V2 — 整合 COPI01 + INVI02 完整欄位）
-- 套用對象：所有 AE Hub app（medteam-app、medsec-app、未來新 app）
-- 套用順序：在 medsec_* 表之前
--
-- 設計原則：
--   1. 員工 / 客戶 / 區域分配 / 產品 全平台共用一套
--   2. 必要欄獨立 column（給 RLS / index / 查詢用）
--   3. 鼎新匯出的完整 159 / 187 欄全留在 raw_*_data jsonb 內，未來不漏資料
-- ============================================================

-- 0. 預備：擴充功能
create extension if not exists pg_trgm;        -- 模糊搜尋
create extension if not exists "uuid-ossp";    -- gen_random_uuid 備援

-- ============================================================
-- 1. hospital_systems · 醫院體系主檔
--    source：COPI01 通路別名稱 unique 抽出（34 種）
-- ============================================================
create table if not exists public.hospital_systems (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,                     -- 內部代碼（VGH / NTU / CGMH / NONE / …）
  name        text not null unique,            -- '長庚體系' / '署立體系' / '無' …
  copi01_name text,                            -- COPI01 原始通路別名稱（多半 = name）
  note        text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

comment on table public.hospital_systems is 'AE Hub 共用 · 醫院體系主檔（source: COPI01 通路別名稱）';

-- ============================================================
-- 2. hospitals · 醫院主檔
--    source：COPI01 篩出醫院（型態別 ∈ 醫學中心/區域/地區/大學/動物醫院/診所）
--    範圍：以 CSV (Lynn 確認的 186 家) 為「白名單」交集
--    博仁綜合醫院 COPI01 沒、暫跳過
-- ============================================================
create table if not exists public.hospitals (
  id              uuid primary key default gen_random_uuid(),

  -- 識別
  copi01_code     text unique not null,          -- 客戶代號（PK 業務語意）
  name            text not null,                 -- 客戶全名
  short_name      text,                          -- 客戶簡稱（顯示用）
  aliases         text[],                        -- 別名陣列（CSV aliases 「、」拆出來）

  -- 體系 / 分類
  system_id       uuid references public.hospital_systems(id) on delete set null,
  level           text,                          -- 型態別名稱：醫學中心/區域醫院/地區醫院/大學/動物醫院/診所

  -- 區域
  region          text,                          -- CSV area：北/中/南/花東/宜蘭/離島
  region_copi01   text,                          -- COPI01 地區別名稱：北區/中區/南區/...

  -- 統編與聯絡
  tax_id          text,                          -- 統一編號
  contact_name    text,                          -- 連絡人
  phone           text,                          -- TEL_NO(一)
  phone2          text,                          -- TEL_NO(二)
  fax             text,
  email           text,
  registered_address text,                       -- 登記地址（拼接）
  shipping_address   text,                       -- 送貨地址（拼接）
  invoice_address    text,                       -- 發票地址（拼接）

  -- CRM 規則（即 Week 6-7 知識庫，從 COPI01 一次帶到位）
  payment_term    text,                          -- 付款條件名稱：60天收款/90天收款/...
  payment_term_code  text,                       -- 付款條件代碼：B060/B090/...
  invoice_type    text,                          -- 發票聯數：1:二聯/2:三聯/7:電子發票
  delivery_method text,                          -- 單據發送方式：4:E-MAIL/紙本...
  payment_method  text,                          -- 收款方式
  tax_category    text,                          -- 課稅別

  -- 信用 / 評等
  credit_rating   text,
  sales_rating    text,
  credit_limit    numeric(14,2),

  -- 交易紀錄
  first_dealt_at  date,                          -- 初次交易
  last_dealt_at   date,                          -- 最近交易

  -- 鼎新登記業務（一家只能登 1 人；多人共管實況 → hospital_assignments）
  copi01_salesperson_id    text,
  copi01_salesperson_name  text,

  -- 備註
  note            text,

  -- 鼎新完整原始資料留存（159 欄全帶）
  raw_copi01_data jsonb,

  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists hospitals_system_idx     on public.hospitals(system_id);
create index if not exists hospitals_region_idx     on public.hospitals(region);
create index if not exists hospitals_level_idx      on public.hospitals(level);
create index if not exists hospitals_name_trgm      on public.hospitals using gin (name gin_trgm_ops);
create index if not exists hospitals_short_trgm     on public.hospitals using gin (short_name gin_trgm_ops);

comment on table public.hospitals is 'AE Hub 共用 · 醫院主檔（source: COPI01 + CSV 業務分區）';

-- ============================================================
-- 3. products · 產品主檔（INVI02 5239 筆，過濾「商品分類一=商品」）
--    刻意不做列表頁，只用 search_products() RPC 模糊搜尋
-- ============================================================
create table if not exists public.products (
  id              uuid primary key default gen_random_uuid(),

  -- 識別
  invi02_code     text unique not null,          -- 品號
  name            text not null,                 -- 品名
  spec            text,                          -- 規格
  size            text,                          -- SIZE
  unit            text,                          -- 單位 EA / PC / BOX

  -- 分類（INVI02 商品分類 1-9 + A-C，挑常用 4 個）
  category_2      text,                          -- 商品分類二名稱
  category_3      text,                          -- 商品分類三名稱
  category_5      text,                          -- 商品分類五名稱
  category_7      text,                          -- 商品分類七名稱
  product_line    text,                          -- 產品系列

  -- 廠商
  vendor          text,                          -- 原廠（代碼）
  supplier_code   text,                          -- 主供應商代碼
  supplier_name   text,                          -- 主供應商名稱

  -- 描述
  description     text,                          -- 商品描述（含衛署字號）

  -- 衛署 / QSD（一級重要，Cindie 模組用）
  moh_license     text,                          -- 衛署字號（從 description regex 抽出）
  moh_expiry      date,                          -- 衛署到期日（待手動填）
  qsd_version     text,                          -- QSD 版本（待 Cindie 填）
  qsd_expiry      date,                          -- QSD 到期日（待 Cindie 填）

  -- 採購
  purchaser_id    text,                          -- 採購人員（多為 0003 周佳蓉）
  purchaser_name  text,

  -- 價格
  std_price       numeric(12,2),                 -- 標準售價（INVI02 提供，公開）
  cost_unit       numeric(12,2),                 -- 單位成本（敏感、暫共用，未來可遷出）
  -- 業務底價：拆到 product_base_prices 表 + RLS 鎖只 manager 可讀寫

  -- 庫存
  stock_qty       integer,                      -- 庫存數量
  stock_value     numeric(14,2),                 -- 庫存金額
  warehouse_code  text,                          -- 主要庫別
  warehouse_name  text,                          -- 庫別名稱

  -- 條碼 / 有效期
  barcode         text,
  shelf_life_days integer,
  shelf_life_unit text,                          -- 1.天 / 2.月 / 3.年

  -- 完整原始資料留存（187 欄全帶）
  raw_invi02_data jsonb,

  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- 模糊搜尋 trgm index
create index if not exists products_invi02_trgm  on public.products using gin (invi02_code gin_trgm_ops);
create index if not exists products_name_trgm    on public.products using gin (name        gin_trgm_ops);
create index if not exists products_spec_trgm    on public.products using gin (spec        gin_trgm_ops);
create index if not exists products_vendor_trgm  on public.products using gin (supplier_name gin_trgm_ops);
create index if not exists products_moh_trgm     on public.products using gin (moh_license gin_trgm_ops);
create index if not exists products_desc_trgm    on public.products using gin (description gin_trgm_ops);
create index if not exists products_moh_expiry   on public.products(moh_expiry);
create index if not exists products_qsd_expiry   on public.products(qsd_expiry);
create index if not exists products_purchaser    on public.products(purchaser_id);

comment on table public.products is 'AE Hub 共用 · 產品主檔（source: INVI02 5239 筆）';

-- ============================================================
-- 4. hospital_assignments · 通用「誰負責哪家」分配表（方案 A）
--    一張表搞定業務、業祕、代理人
-- ============================================================
do $$
begin
  if not exists (select 1 from pg_type where typname = 'hospital_assignment_role') then
    create type public.hospital_assignment_role as enum (
      'salesperson',         -- 業務
      'secretary',           -- 業祕主分區
      'backup_secretary'     -- 業祕代理人
    );
  end if;
end$$;

create table if not exists public.hospital_assignments (
  id           uuid primary key default gen_random_uuid(),
  hospital_id  uuid not null references public.hospitals(id) on delete cascade,
  staff_id     uuid not null references public.profiles(id)  on delete cascade,
  role         public.hospital_assignment_role not null,
  is_primary   boolean not null default true,
  backup_for   uuid references public.profiles(id),
  source       text,                              -- 'csv' / 'copi01' / 'xlsx_20260511' / 'manual'
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (hospital_id, staff_id, role)
);

create index if not exists hospital_assignments_staff_idx on public.hospital_assignments(staff_id, role);
create index if not exists hospital_assignments_hosp_idx  on public.hospital_assignments(hospital_id, role);

comment on table public.hospital_assignments is 'AE Hub 共用 · 醫院 ↔ 員工 分配（業務 + 業祕 + 代理人）';

-- ============================================================
-- 5. updated_at trigger
-- ============================================================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists hospitals_updated_at on public.hospitals;
create trigger hospitals_updated_at before update on public.hospitals
  for each row execute function public.touch_updated_at();

drop trigger if exists products_updated_at on public.products;
create trigger products_updated_at before update on public.products
  for each row execute function public.touch_updated_at();

drop trigger if exists hospital_assignments_updated_at on public.hospital_assignments;
create trigger hospital_assignments_updated_at before update on public.hospital_assignments
  for each row execute function public.touch_updated_at();

-- ============================================================
-- 6. product_base_prices · 產品業務底價（敏感）
--    Lynn 拍板：鎖定最高權限，只 manager 可讀寫
--    schema 先建空表，Lynn 之後提供底價檔再 import
-- ============================================================
create table if not exists public.product_base_prices (
  product_id          uuid primary key references public.products(id) on delete cascade,
  base_price          numeric(12,2) not null,         -- 業務底價（未稅）
  base_price_with_tax numeric(12,2),                  -- 業務底價（含稅）
  effective_from      date,                           -- 此底價生效日（用於審核歷史）
  effective_to        date,                           -- 此底價結束日，null = 仍生效
  source              text,                           -- 'manual' / 'lynn_upload_20260513' / ...
  note                text,
  updated_by          uuid references public.profiles(id),
  updated_at          timestamptz not null default now()
);

create index if not exists pbp_effective_idx on public.product_base_prices(effective_from, effective_to);

comment on table public.product_base_prices
  is 'AE Hub · 產品業務底價（RLS 限只 manager 可讀寫；Lynn 拍板的敏感資料）';

drop trigger if exists pbp_updated_at on public.product_base_prices;
create trigger pbp_updated_at before update on public.product_base_prices
  for each row execute function public.touch_updated_at();
