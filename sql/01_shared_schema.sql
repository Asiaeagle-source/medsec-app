-- ============================================================
-- AE Hub · 共用底層 schema
-- 套用對象：所有 AE Hub app（medteam-app、medsec-app、未來新 app）
-- 套用順序：在 medsec_* 表之前
-- 設計原則：員工 / 客戶 / 區域分配 全平台共用一套
-- ============================================================

-- 0. 預備：擴充功能
create extension if not exists pg_trgm;        -- 模糊搜尋
create extension if not exists "uuid-ossp";    -- 若 gen_random_uuid 不可用時備援

-- ============================================================
-- 1. hospital_systems · 醫院體系主檔
--    例：榮總體系、台大體系、長庚體系、私人醫院、診所...
-- ============================================================
create table if not exists public.hospital_systems (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,            -- 'VGH' / 'NTU' / 'CGMH' / 'PRIV' / ...
  name       text not null,                   -- '榮總體系'
  note       text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.hospital_systems is 'AE Hub 共用 · 醫院體系主檔';

-- ============================================================
-- 2. hospitals · 醫院主檔（301 家）
--    來源：COPI01
-- ============================================================
create table if not exists public.hospitals (
  id           uuid primary key default gen_random_uuid(),
  copi01_code  text unique not null,          -- COPI01 客戶代碼，唯一
  name         text not null,                 -- 完整院名
  short_name   text,                          -- 縮寫（顯示用）
  system_id    uuid references public.hospital_systems(id) on delete set null,
  region       text,                          -- '北' / '中' / '南' / '東' / '離島'
  level        text,                          -- '醫學中心' / '區域' / '地區' / '診所'
  address      text,
  phone        text,
  note         text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists hospitals_system_idx  on public.hospitals(system_id);
create index if not exists hospitals_region_idx  on public.hospitals(region);
create index if not exists hospitals_name_trgm   on public.hospitals using gin (name gin_trgm_ops);
create index if not exists hospitals_short_trgm  on public.hospitals using gin (short_name gin_trgm_ops);

comment on table public.hospitals is 'AE Hub 共用 · 醫院主檔（COPI01 來源，301 家）';

-- ============================================================
-- 3. products · 產品主檔（5260 筆 INVI02）
--    刻意不做列表頁，只用 search_products() RPC 模糊搜尋
-- ============================================================
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  invi02_code   text unique not null,         -- 鼎新 INVI02 品號
  name          text not null,
  spec          text,
  product_line  text,                         -- 產品線
  vendor        text,                         -- 原廠 / 代理商
  health_code   text,                         -- 健保碼
  moh_license   text,                         -- 衛署字號
  moh_expiry    date,
  qsd_version   text,
  qsd_expiry    date,
  base_price    numeric(12,2),                -- 底價（Lynn 才看得到）
  note          text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists products_invi02_trgm  on public.products using gin (invi02_code gin_trgm_ops);
create index if not exists products_name_trgm    on public.products using gin (name        gin_trgm_ops);
create index if not exists products_spec_trgm    on public.products using gin (spec        gin_trgm_ops);
create index if not exists products_vendor_trgm  on public.products using gin (vendor      gin_trgm_ops);
create index if not exists products_health_trgm  on public.products using gin (health_code gin_trgm_ops);
create index if not exists products_moh_trgm     on public.products using gin (moh_license gin_trgm_ops);
create index if not exists products_moh_expiry   on public.products(moh_expiry);
create index if not exists products_qsd_expiry   on public.products(qsd_expiry);

comment on table public.products is 'AE Hub 共用 · 產品主檔（INVI02 來源，5260 筆）';

-- ============================================================
-- 4. hospital_assignments · 通用「誰負責哪家醫院」分配表
--    一張表搞定業務、業祕、代理人 — Lynn 拍板 方案 A
-- ============================================================
create type public.hospital_assignment_role as enum (
  'salesperson',         -- 業務
  'secretary',           -- 業祕（主負責）
  'backup_secretary'     -- 業祕代理人
);

create table if not exists public.hospital_assignments (
  id           uuid primary key default gen_random_uuid(),
  hospital_id  uuid not null references public.hospitals(id) on delete cascade,
  staff_id     uuid not null references public.profiles(id)  on delete cascade,
  role         public.hospital_assignment_role not null,
  is_primary   boolean not null default true,                -- 主負責 = true / 副手 = false
  backup_for   uuid references public.profiles(id),          -- 是誰的代理（請假用）
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (hospital_id, staff_id, role)                       -- 同一家 + 同一人 + 同一角色 唯一
);

create index if not exists hospital_assignments_staff_idx on public.hospital_assignments(staff_id, role);
create index if not exists hospital_assignments_hosp_idx  on public.hospital_assignments(hospital_id, role);

comment on table public.hospital_assignments is 'AE Hub 共用 · 醫院 ↔ 員工 分配（業務 + 業祕 + 代理人）';

-- ============================================================
-- 5. updated_at trigger（全表共用）
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
-- 6. Auth helper functions（給 RLS 用，定義在 02_rls.sql）
--    這裡先聲明 placeholder，實際邏輯放 02_rls.sql
-- ============================================================
