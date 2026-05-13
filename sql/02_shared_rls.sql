-- ============================================================
-- AE Hub · 共用底層 RLS（Row Level Security）
-- 套用順序：01_shared_schema.sql 之後
--
-- 守門邏輯：
--   - profiles            ：自己只看自己（既有）
--   - hospitals           ：業務/業祕只看分配到的；manager/Candy/Cindie/會計 全看
--   - hospital_systems    ：全員工可讀
--   - products            ：登入即可讀（但前端走 search_products RPC）
--   - hospital_assignments：自己看自己 + 代理人；manager 全看 / 全寫
-- ============================================================

-- ============================================================
-- 1. Helper functions
-- ============================================================

-- 1.1 取得目前使用者 medsec_role
create or replace function public.auth_medsec_role()
returns text language sql stable security definer set search_path = public as $$
  select medsec_role from public.profiles where id = auth.uid()
$$;

-- 1.2 取得目前使用者 medteam_role
create or replace function public.auth_medteam_role()
returns text language sql stable security definer set search_path = public as $$
  select medteam_role from public.profiles where id = auth.uid()
$$;

-- 1.3 是否「全公司可看醫院」角色
--     ⚠️ 如果未來 Candy/Cindie/會計 也要分區，改這支
create or replace function public.is_global_hospital_viewer()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(
    (select medsec_role in ('manager','bidding_team','purchasing','accounting')
     from public.profiles where id = auth.uid()),
    false
  )
$$;

-- 1.4 使用者能否看某家醫院
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
  for select to authenticated using (true);
drop policy if exists hosp_sys_write on public.hospital_systems;
create policy hosp_sys_write on public.hospital_systems
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- 2.2 hospitals · 業務 + 業祕只看分配到的；manager/Candy/Cindie/會計 全看
alter table public.hospitals enable row level security;
drop policy if exists hospitals_select on public.hospitals;
create policy hospitals_select on public.hospitals
  for select to authenticated using (public.can_see_hospital(id));
drop policy if exists hospitals_write on public.hospitals;
create policy hospitals_write on public.hospitals
  for all to authenticated
  using (public.auth_medsec_role() = 'manager')
  with check (public.auth_medsec_role() = 'manager');

-- 2.3 products · 登入即可讀；只 manager + purchasing 可寫
alter table public.products enable row level security;
drop policy if exists products_select on public.products;
create policy products_select on public.products
  for select to authenticated using (true);
drop policy if exists products_write on public.products;
create policy products_write on public.products
  for all to authenticated
  using (public.auth_medsec_role() in ('manager','purchasing'))
  with check (public.auth_medsec_role() in ('manager','purchasing'));

-- 2.4 product_base_prices · 只 manager 可讀可寫（Lynn 拍板：最高權限）
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

-- 2.5 hospital_assignments · 自己 + 代理人 + manager
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
-- 3. search_products RPC（前端唯一查產品入口）
-- ============================================================
create or replace function public.search_products(
  q           text,
  max_results integer default 10
) returns table (
  id            uuid,
  invi02_code   text,
  name          text,
  spec          text,
  supplier_name text,
  moh_license   text,
  std_price     numeric,
  match_score   real
) language sql stable security definer set search_path = public as $$
  select
    p.id,
    p.invi02_code,
    p.name,
    p.spec,
    p.supplier_name,
    p.moh_license,
    p.std_price,
    greatest(
      similarity(p.invi02_code,             q),
      similarity(p.name,                    q),
      similarity(coalesce(p.spec, ''),      q),
      similarity(coalesce(p.supplier_name, ''), q),
      similarity(coalesce(p.moh_license, ''),   q),
      similarity(coalesce(p.description, ''),   q)
    ) as match_score
  from public.products p
  where p.is_active = true
    and (
         p.invi02_code   % q
      or p.name          % q
      or p.spec          % q
      or p.supplier_name % q
      or p.moh_license   % q
      or p.description   % q
    )
  order by match_score desc
  limit greatest(1, least(max_results, 50))
$$;

comment on function public.search_products(text, integer)
  is 'AE Hub 產品模糊搜尋；前端：supa.rpc(''search_products'', { q, max_results })';

grant execute on function public.search_products(text, integer) to authenticated;

-- ============================================================
-- 4. 醫院 join 體系的便利 view（給前端不用每次寫 join）
-- ============================================================
create or replace view public.hospitals_with_system as
  select
    h.*,
    hs.name as system_name,
    hs.code as system_code
  from public.hospitals h
  left join public.hospital_systems hs on hs.id = h.system_id;

grant select on public.hospitals_with_system to authenticated;
