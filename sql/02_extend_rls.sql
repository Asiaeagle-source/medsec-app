-- ============================================================
-- AE Hub · 擴充 RLS（V3 — 對應新增的 3 張表）
-- 套用順序：01_extend_existing_schema.sql 之後
--
-- 既有 39 張表的 RLS 不動，這裡只開新表的 RLS
-- ============================================================

-- ============================================================
-- 1. Helper functions（若 medteam-app 已建則 idempotent）
-- ============================================================
create or replace function public.auth_medsec_role()
returns text language sql stable security definer set search_path = public as $$
  select medsec_role from public.profiles where id = auth.uid()
$$;

create or replace function public.is_global_hospital_viewer()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select medsec_role in ('manager','bidding_team','purchasing','accounting')
     from public.profiles where id = auth.uid()),
    false
  )
$$;

create or replace function public.can_see_medsec_hospital(h_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select
    public.is_global_hospital_viewer()
    or exists (                                           -- 業祕主分區
      select 1 from public.medsec_secretary_assignments
      where hospital_id = h_id
        and (primary_secretary_id = auth.uid() or co_secretary_id = auth.uid())
    )
    or exists (                                           -- 業務分區（含共管）
      select 1 from public.medsec_salesperson_assignments
      where hospital_id = h_id and salesperson_id = auth.uid()
    )
$$;

-- ============================================================
-- 2. RLS · hospital_systems · 全員工可讀，只 manager 可寫
-- ============================================================
alter table public.hospital_systems enable row level security;

drop policy if exists hosp_sys_select on public.hospital_systems;
create policy hosp_sys_select on public.hospital_systems
  for select to authenticated using (true);

drop policy if exists hosp_sys_write on public.hospital_systems;
create policy hosp_sys_write on public.hospital_systems
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- ============================================================
-- 3. RLS · product_base_prices · 只 manager（最高權限）
-- ============================================================
alter table public.product_base_prices enable row level security;

drop policy if exists pbp_select on public.product_base_prices;
create policy pbp_select on public.product_base_prices
  for select to authenticated
  using (public.auth_medsec_role() = 'manager');

drop policy if exists pbp_write on public.product_base_prices;
create policy pbp_write on public.product_base_prices
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- ============================================================
-- 4. RLS · medsec_salesperson_assignments
--    自己看自己 + manager 全看 / 全寫
-- ============================================================
alter table public.medsec_salesperson_assignments enable row level security;

drop policy if exists msa_select on public.medsec_salesperson_assignments;
create policy msa_select on public.medsec_salesperson_assignments
  for select to authenticated
  using (
    salesperson_id = auth.uid()
    or public.auth_medsec_role() = 'manager'
  );

drop policy if exists msa_write on public.medsec_salesperson_assignments;
create policy msa_write on public.medsec_salesperson_assignments
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- ============================================================
-- 5. search_medsec_products RPC · 既有 medsec_products 加 trigram 模糊搜尋
--    （前端唯一查產品入口、不開放直接 SELECT *）
-- ============================================================
-- trigram index（既有 medsec_products 沒這些，要補）
create index if not exists medsec_products_catalog_trgm
  on public.medsec_products using gin (catalog_number gin_trgm_ops);
create index if not exists medsec_products_name_trgm
  on public.medsec_products using gin (name gin_trgm_ops);
create index if not exists medsec_products_spec_trgm
  on public.medsec_products using gin (specification gin_trgm_ops);
create index if not exists medsec_products_manuf_trgm
  on public.medsec_products using gin (manufacturer_name gin_trgm_ops);

create or replace function public.search_medsec_products(
  q           text,
  max_results integer default 10
) returns table (
  id                uuid,
  catalog_number    text,
  name              text,
  specification     text,
  manufacturer_name text,
  list_price        numeric,
  match_score       real
) language sql stable security definer set search_path = public as $$
  select
    p.id,
    p.catalog_number,
    p.name,
    p.specification,
    p.manufacturer_name,
    p.list_price,
    greatest(
      similarity(coalesce(p.catalog_number, ''),    q),
      similarity(coalesce(p.name, ''),              q),
      similarity(coalesce(p.specification, ''),     q),
      similarity(coalesce(p.manufacturer_name, ''), q)
    ) as match_score
  from public.medsec_products p
  where p.status = 'active'                       -- 既有 medsec_products.status 欄位
    and (
         coalesce(p.catalog_number, '')    % q
      or coalesce(p.name, '')              % q
      or coalesce(p.specification, '')     % q
      or coalesce(p.manufacturer_name, '') % q
    )
  order by match_score desc
  limit greatest(1, least(max_results, 50))
$$;

comment on function public.search_medsec_products(text, integer)
  is 'AE Hub · 產品模糊搜尋 (既有 medsec_products)';

grant execute on function public.search_medsec_products(text, integer) to authenticated;
