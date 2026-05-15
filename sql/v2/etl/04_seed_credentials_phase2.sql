-- 04_seed_credentials_phase2.sql — V2 Sprint 1 ETL Phase-2
-- §A approved mapping (12 舊代號 → 8 新代號)
-- 無 UNIQUE → 不 ON CONFLICT,所有 row 都 INSERT
-- 重跑會插重複,Lynn 只跑一次

-- (no rows to emit — §A 在 V2 zip 對應 INSERT 內沒找到)
SELECT 1 WHERE FALSE;
