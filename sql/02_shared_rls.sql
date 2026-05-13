-- ============================================================
-- AE Hub · 共用底層 RLS（Row Level Security）
-- 套用順序：01_shared_schema.sql 之後
-- 守門邏輯：
--   1. profiles  — 自己只看自己（既有）
--   2. hospitals — 業務/業祕只看分配到的；manager/Candy/Cindie/會計 全看（⚠️ 待 Lynn 最後確認）
--   3. products  — 不直接 SELECT，只透過 search_products() RPC；RLS 設成「登入即可讀」
--   4. hospital_systems — 全員工可讀
--   5. hospital_assignments — 自己看自己的；manager 全看
-- ============================================================

-- ============================================================
-- 1. Helper functions
--    都用 security definer + stable，避免在 policy 內無限遞迴
-- ============================================================

-- 1.1 取得目前使用者的 medsec_role
create or replace function public.auth_medsec_role()
returns text language sql stable security definer set search_path = public as $$
  select medsec_role from public.profiles where id = auth.uid()
$$;

-- 1.2 取得目前使用者的 medteam_role
create or replace function public.auth_medteam_role()
returns text language sql stable security definer set search_path = public as $$
  select medteam_role from public.profiles where id = auth.uid()
$$;

-- 1.3 是否「全公司可看醫院」的角色
--     ⚠️ Lynn：這 4 個角色目前預設「全看」，若 Candy / Cindie / 會計 之中要分區就改這支
create or replace function public.is_global_hospital_viewer()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select medsec_role in ('manager','bidding_team','purchasing','accounting')
     from public.profiles where id = auth.uid()),
    false
  )
$$;

-- 1.4 使用者能否看某家醫院（核心 helper）
--     邏輯：自己有 assignment OR 是全看角色
create or replace function public.can_see_hospital(h_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select
    public.is_global_hospital_viewer()
    or exists (
      select 1 from public.hospital_assignments
      where hospital_id = h_id and staff_id = auth.uid()
    )
$$;

-- ============================================================
-- 2. RLS policies
-- ============================================================

-- 2.1 hospital_systems · 全員工可讀，只 manager 可寫
alter table public.hospital_systems enable row level security;

drop policy if exists hosp_sys_select on public.hospital_systems;
create policy hosp_sys_select on public.hospital_systems
  for select to authenticated
  using (true);

drop policy if exists hosp_sys_write on public.hospital_systems;
create policy hosp_sys_write on public.hospital_systems
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- 2.2 hospitals · 業務 + 業祕只看分配到的；manager/Candy/Cindie/會計 全看
alter table public.hospitals enable row level security;

drop policy if exists hospitals_select on public.hospitals;
create policy hospitals_select on public.hospitals
  for select to authenticated
  using (public.can_see_hospital(id));

drop policy if exists hospitals_write on public.hospitals;
create policy hospitals_write on public.hospitals
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- 2.3 products · 不開直接 SELECT，但 RLS 還是要設（前端走 search_products RPC）
alter table public.products enable row level security;

drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated
  using (true);                              -- 登入即可讀（無分區）

drop policy if exists products_write on public.products;
create policy products_write on public.products
  for all to authenticated
  using (public.auth_medsec_role() in ('manager','purchasing'))
  with check (public.auth_medsec_role() in ('manager','purchasing'));

-- 2.4 hospital_assignments · 自己看自己；manager 全看 / 全寫
alter table public.hospital_assignments enable row level security;

drop policy if exists ha_select on public.hospital_assignments;
create policy ha_select on public.hospital_assignments
  for select to authenticated
  using (
    staff_id = auth.uid()
    or backup_for = auth.uid()
    or public.auth_medsec_role() = 'manager'
  );

drop policy if exists ha_write on public.hospital_assignments;
create policy ha_write on public.hospital_assignments
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- ============================================================
-- 3. search_products RPC
--    前端唯一查產品的入口；不開放直接 SELECT *
-- ============================================================
create or replace function public.search_products(
  q           text,
  max_results integer default 10
) returns table (
  id           uuid,
  invi02_code  text,
  name         text,
  spec         text,
  vendor       text,
  health_code  text,
  moh_license  text,
  match_score  real
) language sql stable security definer set search_path = public as $$
  select
    p.id,
    p.invi02_code,
    p.name,
    p.spec,
    p.vendor,
    p.health_code,
    p.moh_license,
    greatest(
      similarity(p.invi02_code, q),
      similarity(p.name, q),
      similarity(coalesce(p.spec, ''), q),
      similarity(coalesce(p.vendor, ''), q),
      similarity(coalesce(p.health_code, ''), q),
      similarity(coalesce(p.moh_license, ''), q)
    ) as match_score
  from public.products p
  where p.is_active = true
    and (
      p.invi02_code % q
      or p.name      % q
      or p.spec      % q
      or p.vendor    % q
      or p.health_code % q
      or p.moh_license % q
    )
  order by match_score desc
  limit greatest(1, least(max_results, 50))      -- 最多 50 筆
$$;

comment on function public.search_products(text, integer)
  is 'AE Hub · 產品模糊搜尋；前端 supa.rpc(''search_products'', { q, max_results })';

-- 給所有登入使用者執行權
grant execute on function public.search_products(text, integer) to authenticated;
