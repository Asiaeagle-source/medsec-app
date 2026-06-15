-- ============================================================
-- 20_mail_digest_schema.sql · 信件分流(階段一:建表 + 自動派工 view + RLS)
-- ------------------------------------------------------------
-- 設計原則:
--   * Exchange 仍是信件正本來源;這張表只存「分流結果 + 摘要」
--   * 不存信件全文(敏感),只存 AI 一句話摘要 + 回原信用的 message id
--   * assigned_to / status 階段一先放著不用,階段三(派工 + 看板)直接接
--
-- 與既有 schema 對齊:
--   * 院碼欄改 hospital_id(text)→ FK 對 medsec_hospitals.id(COPI01 院碼)
--     沿用全 repo 命名(quote_history / cases 都叫 hospital_id),非新名 hospital_code
--   * 業祕指派改 uuid → FK 對 profiles.id;對齊 medsec_secretary_assignments
--     的 primary_secretary_id / co_secretary_id 設計(都是 profiles uuid)
--   * RLS 條件用 auth.uid()(即 profile.id),不用 employee_id text 對照
-- ============================================================

create table if not exists public.mail_digest (
    id                uuid primary key default gen_random_uuid(),

    -- 來自 Microsoft Graph 的識別(回原信、去重用)
    graph_message_id  text unique not null,
    received_at       timestamptz not null,

    -- 寄件資訊
    sender_email      text,
    sender_name       text,
    subject           text,

    -- AI 分流結果
    ai_summary        text,                          -- 一句話摘要(AI 出)
    priority          text not null default 'gray'   -- 紅黃灰
                      check (priority in ('red','amber','gray')),
    category          text,                          -- 招標 / 客訴 / 程序委員會 / 報價 / 帳務 / 電子報 ...
    flag_reason       text,                          -- 標紅原因(清單上的標籤文字)
    deadline          timestamptz,                   -- 截止時間(有才填)

    -- 歸屬(透過醫院 → 業祕分區帶出)
    hospital_id       text references public.medsec_hospitals(id),   -- 對醫院主檔
    assigned_to       uuid references public.profiles(id),           -- 手動指派(階段三才寫)
    status            text not null default 'pending'
                      check (status in ('pending','replied','forwarded','done')),

    digest_date       date not null default current_date,
    created_at        timestamptz not null default now()
);

-- 查詢索引:看板 / 清單最常用的幾種切法
create index if not exists idx_mail_digest_date     on public.mail_digest (digest_date desc);
create index if not exists idx_mail_digest_priority on public.mail_digest (priority);
create index if not exists idx_mail_digest_assigned on public.mail_digest (assigned_to);
create index if not exists idx_mail_digest_hospital on public.mail_digest (hospital_id);
create index if not exists idx_mail_digest_status   on public.mail_digest (status);


-- ============================================================
-- 自動派工 View: 信件 → 醫院 → 業祕分區 → 落到負責的業祕
-- ------------------------------------------------------------
-- 真實表名 medsec_secretary_assignments(已存在,sql/06_seed... 灌過 182 家)
-- 真實欄名 hospital_id / primary_secretary_id / co_secretary_id
--   (uuid 對 profiles.id;沒有 role='primary'/'backup' 區分,
--    primary 與 co 是兩個獨立欄)
-- 顯示用名稱 join profiles 帶出 nickname / employee_id;
-- 醫院 join medsec_hospitals 帶出短名 / 全名供前端顯示。
-- ============================================================

create or replace view public.v_mail_digest_assigned as
select
    m.*,
    -- 分區主祕
    sa.primary_secretary_id  as auto_primary_secretary_id,
    -- 副祕(co)
    sa.co_secretary_id       as auto_co_secretary_id,
    -- 實際承辦:手動指派優先,否則用主分區
    coalesce(m.assigned_to, sa.primary_secretary_id) as effective_secretary_id,
    -- 顯示用名稱
    p_pri.nickname           as auto_primary_secretary_name,
    p_co.nickname            as auto_co_secretary_name,
    p_eff.nickname           as effective_secretary_name,
    p_eff.employee_id        as effective_secretary_employee_id,
    -- 醫院顯示
    h.name_short             as hospital_name_short,
    h.name_full              as hospital_name_full
from public.mail_digest m
left join public.medsec_secretary_assignments sa on sa.hospital_id = m.hospital_id
left join public.profiles p_pri on p_pri.id = sa.primary_secretary_id
left join public.profiles p_co  on p_co.id  = sa.co_secretary_id
left join public.profiles p_eff on p_eff.id = coalesce(m.assigned_to, sa.primary_secretary_id)
left join public.medsec_hospitals h on h.id = m.hospital_id;


-- ============================================================
-- RLS(對齊 has_medsec_access / medsec_role 既有機制)
-- ------------------------------------------------------------
--  manager  : 看全部 + 全寫(派工 / 改狀態)
--  secretary: 只看 effective_owner = 自己 的信
--             (手動指派給我 OR 我是這家醫院的主祕/副祕 → 對齊 secretary.html
--              的「我的醫院 = primary OR co」慣例)
-- ============================================================

alter table public.mail_digest enable row level security;

drop policy if exists mail_digest_manager_all on public.mail_digest;
create policy mail_digest_manager_all on public.mail_digest
    for all
    to authenticated
    using (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid()
              and p.has_medsec_access = true
              and p.medsec_role = 'manager'
        )
    )
    with check (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid()
              and p.has_medsec_access = true
              and p.medsec_role = 'manager'
        )
    );

drop policy if exists mail_digest_secretary_own on public.mail_digest;
create policy mail_digest_secretary_own on public.mail_digest
    for select
    to authenticated
    using (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid()
              and p.has_medsec_access = true
        )
        and (
            assigned_to = auth.uid()
            or exists (
                select 1
                from public.medsec_secretary_assignments sa
                where sa.hospital_id = mail_digest.hospital_id
                  and (
                       sa.primary_secretary_id = auth.uid()
                    or sa.co_secretary_id      = auth.uid()
                  )
            )
        )
    );

comment on table public.mail_digest is
  '信件分流結果 + 摘要;Exchange 仍是正本,本表只存 AI 分類 / 摘要 / 派工.';
comment on view  public.v_mail_digest_assigned is
  '信件 → 醫院 → 業祕分區 → 自動帶出承辦業祕;手動指派優先於主祕.';

-- ============================================================
-- 驗證:
--   manager session
--     INSERT INTO mail_digest (graph_message_id, received_at, subject)
--       VALUES ('test-1', now(), '冒煙測試');
--     SELECT * FROM v_mail_digest_assigned WHERE graph_message_id='test-1';
--     DELETE FROM mail_digest WHERE graph_message_id='test-1';
--   secretary session
--     SELECT count(*) FROM v_mail_digest_assigned;
--     -- 應該只看到 assigned_to=self 或自己分區醫院的信
-- ============================================================
