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
