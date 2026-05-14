-- ============================================================
-- AE Hub · 擴充既有 schema（V3 — 不動既有 39 張表，只 ADD 3 張新表）
-- 套用環境：project yincuegybnuzgojakkuc（已有 medsec_* 完整 schema）
--
-- 設計原則：
--   1. 完全不動 hospitals / products / medsec_* 39 張表
--   2. 新增 3 張底層共用表，跟既有結構並存
--   3. 用 ON CONFLICT DO NOTHING 把資料灌進既有 medsec_hospitals / medsec_products / medsec_secretary_assignments
-- ============================================================

-- 預備
create extension if not exists pg_trgm;
create extension if not exists "uuid-ossp";

-- ============================================================
-- 1. hospital_systems · 醫院體系主檔（新建）
--    對應既有 medsec_hospitals.system_prefix（既有是文字欄位、無外鍵）
--    33 種體系從 COPI01 通路別名稱抽出
-- ============================================================
create table if not exists public.hospital_systems (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,                     -- 'VGH' / 'NTU' / 'CGMH' / 'NONE' / ...
  name        text not null unique,            -- '長庚體系' / '署立體系' / ...
  copi01_name text,                            -- COPI01 通路別名稱（原值）
  note        text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create index if not exists hospital_systems_code_idx on public.hospital_systems(code);

comment on table public.hospital_systems
  is 'AE Hub 共用 · 醫院體系主檔（source: COPI01 通路別名稱）';

-- ============================================================
-- 2. product_base_prices · 產品業務底價（新建）
--    Lynn 拍板：鎖最高權限，只 manager 可讀寫
--    既有 medsec_products.id 是 text（INVI02 品號），這裡 FK 用 text
-- ============================================================
create table if not exists public.product_base_prices (
  product_id          text primary key references public.medsec_products(id) on delete cascade,
  base_price          numeric(12,2) not null,
  base_price_with_tax numeric(12,2),
  effective_from      date,
  effective_to        date,
  source              text,
  note                text,
  updated_by          uuid references public.profiles(id),
  updated_at          timestamptz not null default now()
);

create index if not exists pbp_effective_idx
  on public.product_base_prices(effective_from, effective_to);

comment on table public.product_base_prices
  is 'AE Hub · 產品業務底價（RLS 只 manager 可讀寫）';

-- ============================================================
-- 3. medsec_salesperson_assignments · 業務 ↔ 醫院 分區（新建）
--    Lynn 拍板：業務要有共管結構
--    既有 medsec_secretary_assignments 是「主祕 + 副祕」二人欄位設計；
--    業務最多 5 人共管，需要 normalized 結構（一行一個關係）
-- ============================================================
create table if not exists public.medsec_salesperson_assignments (
  id              uuid primary key default gen_random_uuid(),
  hospital_id     text not null references public.medsec_hospitals(id) on delete cascade,
  salesperson_id  uuid not null references public.profiles(id)         on delete cascade,
  is_primary      boolean not null default true,
  display_order   integer not null default 0,         -- 0 = 主、1+ = 共管
  effective_date  date not null default current_date,
  source          text,                               -- 'csv' / 'copi01' / 'manual'
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (hospital_id, salesperson_id)
);

create index if not exists msa_hospital_idx on public.medsec_salesperson_assignments(hospital_id);
create index if not exists msa_sales_idx    on public.medsec_salesperson_assignments(salesperson_id);

comment on table public.medsec_salesperson_assignments
  is 'medsec · 業務 ↔ 醫院 共管分區（normalized，一行一關係）';

-- ============================================================
-- 4. updated_at trigger
-- ============================================================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists pbp_updated_at on public.product_base_prices;
create trigger pbp_updated_at before update on public.product_base_prices
  for each row execute function public.touch_updated_at();

drop trigger if exists msa_updated_at on public.medsec_salesperson_assignments;
create trigger msa_updated_at before update on public.medsec_salesperson_assignments
  for each row execute function public.touch_updated_at();
