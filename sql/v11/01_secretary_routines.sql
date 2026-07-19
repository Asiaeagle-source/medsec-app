-- ============================================================
-- 01_secretary_routines.sql · 待辦 v1.1 · 業祕個人例行清單模板
-- ------------------------------------------------------------
-- 用途:
--   每位業祕維護一份「每日例行事項」模板。前端(secretary-todo.js)
--   每日首開會讀本表,把 is_active 的項目帶入今日 schedule_items
--   (當日只帶一次,localStorage 防重)。換裝置不丟 → 用表不用 localStorage。
--
-- 對齊既有慣例:
--   * secretary_id uuid → FK profiles.id(對齊 medsec_secretary_assignments)
--   * RLS 用 auth.uid();本人只能看/改自己的例行
--   * category 存中文字串,對齊 schedule_items.activities[0].type 的 6 選
--
-- ⚠️ 請 Lynn 審核後再套用。前端在本表不存在時會自動隱藏例行功能(不報錯)。
--    idempotent:可重複執行。
-- ============================================================

create table if not exists public.medsec_secretary_routines (
    id           uuid primary key default gen_random_uuid(),
    secretary_id uuid not null references public.profiles(id) on delete cascade,
    category     text not null default '其他',
    content      text not null,
    sort_order   int  not null default 0,
    is_active    bool not null default true,
    created_at   timestamptz not null default now()
);

create index if not exists idx_secretary_routines_owner
    on public.medsec_secretary_routines (secretary_id, is_active, sort_order);

comment on table public.medsec_secretary_routines is
  '業祕個人例行清單模板;每日首開帶入 schedule_items(待辦 v1.1).';

-- ============================================================
-- RLS:本人 only(對齊 has_medsec_access + 自己資料自己管)
-- ============================================================
alter table public.medsec_secretary_routines enable row level security;

drop policy if exists secretary_routines_own on public.medsec_secretary_routines;
create policy secretary_routines_own on public.medsec_secretary_routines
    for all
    to authenticated
    using (
        secretary_id = auth.uid()
        and exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.has_medsec_access = true
        )
    )
    with check (
        secretary_id = auth.uid()
        and exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.has_medsec_access = true
        )
    );

-- ============================================================
-- 驗證:
--   -- 本人 session
--   insert into medsec_secretary_routines (secretary_id, category, content)
--     values (auth.uid(), '文件行政', '每日填溫溼度紀錄表');
--   select * from medsec_secretary_routines;      -- 只看到自己的
--   delete from medsec_secretary_routines where content = '每日填溫溼度紀錄表';
-- ============================================================
