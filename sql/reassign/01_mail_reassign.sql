-- ============================================================
-- 01_mail_reassign.sql · 信件轉派(加欄 + RPC)
-- ------------------------------------------------------------
-- 目的:hospital_id 對映缺口(gmail 寄件者、name_short 對不到)導致
--       錯派/漏派的人工修正閥。治本(補對映)列 V2.2,本檔是治標。
-- 行為:轉派 = 直接 UPDATE mail_digest.assigned_to(不需對方再認領),
--       留痕 reassigned_by / reassigned_at。
-- 權限(RPC 內把關,SECURITY DEFINER):
--   manager   → 可轉派任何信
--   secretary → 只能轉派 effective secretary = 自己 的信
--               (assigned_to = 自己,或 assigned_to 為空且自己是該院主/副祕)
-- ⚠️ 請 Lynn 審核後套用;idempotent 可重跑。
-- ⚠️ 跑完必須重建 v_mail_digest_assigned(見檔尾),否則前端拿不到新欄
--    (view 的 m.* 欄位集凍結在建立當下 —— body_text 事件同款雷)。
-- ============================================================

-- 1) 留痕欄
alter table public.mail_digest add column if not exists reassigned_by uuid references public.profiles(id);
alter table public.mail_digest add column if not exists reassigned_at timestamptz;

comment on column public.mail_digest.reassigned_by is '轉派:最後一次轉派的操作人(profiles.id)';
comment on column public.mail_digest.reassigned_at is '轉派:最後一次轉派時間';

-- 2) RPC:medsec_reassign_mail(p_mail_id, p_to)
create or replace function public.medsec_reassign_mail(p_mail_id uuid, p_to uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me   uuid := auth.uid();
  v_role text;
  v_ok   boolean := false;
begin
  -- 呼叫者必須是 medsec 使用者
  select medsec_role into v_role
    from profiles
   where id = v_me and has_medsec_access = true;
  if v_role is null then
    raise exception '無 MedSec 權限';
  end if;

  -- 轉派對象必須是有 medsec 存取權的使用者
  if p_to is null or not exists (
    select 1 from profiles where id = p_to and has_medsec_access = true
  ) then
    raise exception '轉派對象無效';
  end if;

  -- 權限:manager 任何信;secretary 限 effective secretary = 自己
  if v_role = 'manager' then
    v_ok := true;
  else
    select exists (
      select 1
        from mail_digest m
        left join medsec_secretary_assignments sa on sa.hospital_id = m.hospital_id
       where m.id = p_mail_id
         and (
              m.assigned_to = v_me
           or (m.assigned_to is null
               and (sa.primary_secretary_id = v_me or sa.co_secretary_id = v_me))
         )
    ) into v_ok;
  end if;

  if not v_ok then
    raise exception '只能轉派自己承辦的信';
  end if;

  update mail_digest
     set assigned_to   = p_to,
         reassigned_by = v_me,
         reassigned_at = now()
   where id = p_mail_id;

  if not found then
    raise exception '找不到這封信';
  end if;
end;
$$;

revoke all on function public.medsec_reassign_mail(uuid, uuid) from public;
grant execute on function public.medsec_reassign_mail(uuid, uuid) to authenticated;

comment on function public.medsec_reassign_mail(uuid, uuid) is
  '信件轉派:manager 任何信 / 業祕限 effective secretary=自己;直接改 assigned_to + 留痕.';

-- ============================================================
-- 3) ⚠️ 重建 view(Lynn 的 production 版定義為準)
--    m.* 會自動帶到 reassigned_by / reassigned_at 兩個新欄,
--    另請在 select 清單加一行轉派人暱稱(對齊 claimed_by_name 做法):
--
--      p_re.nickname as reassigned_by_name
--
--    並在 join 區加:
--
--      left join public.profiles p_re on p_re.id = m.reassigned_by
--
--    用你現行的 create or replace view public.v_mail_digest_assigned 全文
--    加上以上兩行重跑即可。
-- ============================================================

-- 驗證:
-- 1) 欄位在:應回 2 列
-- select column_name from information_schema.columns
--  where table_name='mail_digest' and column_name in ('reassigned_by','reassigned_at');
-- 2) view 帶到新欄:應回 3 列(含 reassigned_by_name)
-- select column_name from information_schema.columns
--  where table_name='v_mail_digest_assigned'
--    and column_name in ('reassigned_by','reassigned_at','reassigned_by_name');
-- 3) RPC 在:應回 1 列
-- select proname from pg_proc where proname='medsec_reassign_mail';

-- ============================================================
-- 4) ⚠️ RLS 旁路修正(與 view 重建同一次做,必做)
--    Postgres view 預設以 owner(postgres,bypassrls)權限執行 →
--    任何 authenticated 查 view 都繞過 mail_digest RLS(全量裸奔)。
--    掛 security_invoker 後改以「查詢者」身分評估 RLS:
--      manager   → mail_digest_manager_all,全看,不變
--      secretary → mail_digest_secretary_own,只看自己承辦/分區
--      非 medsec 的登入者 → 0 列(修掉真實外洩面)
--    建議把選項寫進 view 定義本體,之後任何重建都不會遺失:
--      create or replace view public.v_mail_digest_assigned
--        with (security_invoker = true) as select ...(現行全文);
--    先行補救(立即生效,單句):
alter view public.v_mail_digest_assigned set (security_invoker = true);

--    影響面確認(已逐項核):
--    * cron(service role)讀寫都直打 mail_digest / mail_attachments「表」,
--      不經 view,service_role 本就繞過 RLS → 完全不受影響。
--    * 本檔 RPC(SECURITY DEFINER)直打表,不經 view → 不受影響。
--    * view 內 join 的 profiles / medsec_secretary_assignments /
--      medsec_hospitals 也會改以查詢者身分讀 —— 前端本來就以使用者
--      token 直讀這三張表(選單/分區/院名都正常),可讀性已被實證;
--      保險確認:以 0007 登入 preview 看卡片的承辦暱稱/院名是否照常顯示。
--    * mail_attachments 的 select policy 引用 mail_digest(視野繼承)
--      不經 view → 不受影響。
--    驗證:
--      select relname, reloptions from pg_class where relname='v_mail_digest_assigned';
--      -- reloptions 應含 security_invoker=true
--      -- 再用 0007(業祕)登入:清單應只剩自己承辦/分區的信;manager 不變。
