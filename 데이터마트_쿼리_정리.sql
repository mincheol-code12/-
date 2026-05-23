-- =====================================================
-- eCommerce 데이터마트 설계 (PostgreSQL)
-- 분석 목적: 퍼널 이탈 분석 / 재구매 코호트 분석
--
-- 테이블 구조
-- raw_events
-- ├── user_summary      (유저 단위 집계)
-- ├── session_summary   (세션 단위 집계 + 퍼널 이탈 단계)
-- ├── cohort_summary    (재방문 코호트 — view 포함)
-- ├── cohort_purchase   (재구매 코호트 — purchase만)
-- ├── category_summary  (카테고리 단위 집계)
-- └── brand_summary     (브랜드 단위 집계)
-- =====================================================


-- =====================================================
-- 0. 원본 테이블 정의
-- =====================================================

CREATE TABLE IF NOT EXISTS raw_events (
    event_time    TIMESTAMP,
    event_type    VARCHAR(10),    -- view / cart / purchase
    product_id    BIGINT,
    category_id   BIGINT,
    category_code VARCHAR(100),
    brand         VARCHAR(100),
    price         FLOAT,
    user_id       BIGINT,
    user_session  VARCHAR(50)
);


-- =====================================================
-- 1. user_summary
-- 유저별 전체 행동 집계
-- 다른 테이블의 FK 기준 테이블
-- =====================================================

CREATE TABLE user_summary AS
SELECT
    user_id,
    MIN(event_time)                                                  AS first_event_time,
    MAX(event_time)                                                  AS last_event_time,
    MIN(CASE WHEN event_type = 'purchase' THEN event_time END)       AS first_purchase_time,
    MAX(CASE WHEN event_type = 'purchase' THEN event_time END)       AS last_purchase_time,
    COUNT(CASE WHEN event_type = 'view'     THEN 1 END)              AS total_views,
    COUNT(CASE WHEN event_type = 'cart'     THEN 1 END)              AS total_carts,
    COUNT(CASE WHEN event_type = 'purchase' THEN 1 END)              AS total_purchases,
    SUM(CASE WHEN event_type = 'purchase'   THEN price ELSE 0 END)   AS total_revenue
FROM raw_events
GROUP BY user_id;

-- PK 설정
ALTER TABLE user_summary
ADD CONSTRAINT pk_user_summary PRIMARY KEY (user_id);

-- 인덱스
CREATE INDEX idx_user_summary_user_id ON user_summary(user_id);


-- =====================================================
-- 2. session_summary
-- 세션별 행동 집계 + 퍼널 이탈 단계(drop_stage) 태깅
-- drop_stage: 가장 깊이 도달한 단계 기록 (purchase > cart > view)
-- → View→Cart→Purchase 퍼널 전환율 분석 기반
-- =====================================================

CREATE TABLE session_summary AS
SELECT
    user_session,
    user_id,
    MIN(event_time)                                                  AS session_start,
    MAX(event_time)                                                  AS session_end,
    EXTRACT(EPOCH FROM (MAX(event_time) - MIN(event_time)))/60       AS session_duration_min,
    COUNT(CASE WHEN event_type = 'view'     THEN 1 END)              AS total_views,
    COUNT(CASE WHEN event_type = 'cart'     THEN 1 END)              AS total_carts,
    COUNT(CASE WHEN event_type = 'purchase' THEN 1 END)              AS total_purchases,
    SUM(CASE WHEN event_type = 'purchase'   THEN price ELSE 0 END)   AS total_revenue,
    CASE
        WHEN COUNT(CASE WHEN event_type = 'purchase' THEN 1 END) > 0 THEN 'purchase'
        WHEN COUNT(CASE WHEN event_type = 'cart'     THEN 1 END) > 0 THEN 'cart'
        ELSE 'view'
    END                                                              AS drop_stage
FROM raw_events
GROUP BY user_session, user_id;

ALTER TABLE session_summary
ALTER COLUMN session_duration_min TYPE NUMERIC(10,2);

-- FK 설정
ALTER TABLE session_summary
ADD CONSTRAINT fk_session_user
FOREIGN KEY (user_id) REFERENCES user_summary(user_id);

-- 인덱스
CREATE INDEX idx_session_summary_user_id ON session_summary(user_id);


-- =====================================================
-- 3. cohort_summary
-- 첫 방문 주차 기준 재방문 코호트 (view 포함)
-- cohort_purchase와 구분:
--   cohort_summary  → 재방문 (모든 이벤트 포함)
--   cohort_purchase → 재구매 (purchase만)
-- =====================================================

CREATE TABLE cohort_summary AS
WITH user_cohort AS (
    SELECT
        user_id,
        DATE_TRUNC('week', first_event_time) AS cohort_week
    FROM user_summary
),
user_activity AS (
    SELECT
        user_id,
        DATE_TRUNC('week', event_time) AS activity_week
    FROM raw_events
    GROUP BY user_id, DATE_TRUNC('week', event_time)
)
SELECT
    uc.user_id,
    uc.cohort_week,
    ua.activity_week,
    EXTRACT(DAY FROM (ua.activity_week - uc.cohort_week))::INT / 7 AS period_number
FROM user_cohort uc
JOIN user_activity ua
    ON  uc.user_id       = ua.user_id
    AND ua.activity_week >= uc.cohort_week;

-- 날짜 타입 변환
ALTER TABLE cohort_summary
ALTER COLUMN cohort_week  TYPE DATE USING cohort_week::DATE;
ALTER TABLE cohort_summary
ALTER COLUMN activity_week TYPE DATE USING activity_week::DATE;

-- FK 설정
ALTER TABLE cohort_summary
ADD CONSTRAINT fk_cohort_user
FOREIGN KEY (user_id) REFERENCES user_summary(user_id);

-- 인덱스
CREATE INDEX idx_cohort_week    ON cohort_summary(cohort_week);
CREATE INDEX idx_cohort_period  ON cohort_summary(period_number);
CREATE INDEX idx_cohort_user_id ON cohort_summary(user_id);


-- =====================================================
-- 4. cohort_purchase
-- 첫 구매 주차 기준 재구매 코호트 (purchase만)
-- Purchase→Repurchase 3단계 세그먼트 CRM 분석 근거
-- =====================================================

CREATE TABLE cohort_purchase AS
WITH user_cohort AS (
    SELECT
        user_id,
        DATE_TRUNC('week', first_purchase_time) AS cohort_week
    FROM user_summary
    WHERE first_purchase_time IS NOT NULL
),
user_purchase AS (
    SELECT
        user_id,
        DATE_TRUNC('week', event_time) AS purchase_week
    FROM raw_events
    WHERE event_type = 'purchase'
    GROUP BY user_id, DATE_TRUNC('week', event_time)
)
SELECT
    uc.user_id,
    uc.cohort_week,
    up.purchase_week                                               AS activity_week,
    EXTRACT(DAY FROM (up.purchase_week - uc.cohort_week))::INT / 7 AS period_number
FROM user_cohort uc
JOIN user_purchase up
    ON  uc.user_id       = up.user_id
    AND up.purchase_week >= uc.cohort_week;

-- 날짜 타입 변환
ALTER TABLE cohort_purchase
ALTER COLUMN cohort_week   TYPE DATE USING cohort_week::DATE;
ALTER TABLE cohort_purchase
ALTER COLUMN activity_week TYPE DATE USING activity_week::DATE;

-- FK 설정
ALTER TABLE cohort_purchase
ADD CONSTRAINT fk_purchase_user
FOREIGN KEY (user_id) REFERENCES user_summary(user_id);

-- 인덱스
CREATE INDEX idx_purchase_cohort_week ON cohort_purchase(cohort_week);
CREATE INDEX idx_purchase_period      ON cohort_purchase(period_number);
CREATE INDEX idx_purchase_user_id     ON cohort_purchase(user_id);


-- =====================================================
-- 5. category_summary
-- 카테고리별 View→Purchase 전환율 집계
-- =====================================================

CREATE TABLE category_summary AS
SELECT
    category_code,
    COUNT(CASE WHEN event_type = 'view'     THEN 1 END)            AS total_views,
    COUNT(CASE WHEN event_type = 'cart'     THEN 1 END)            AS total_carts,
    COUNT(CASE WHEN event_type = 'purchase' THEN 1 END)            AS total_purchases,
    SUM(CASE WHEN event_type = 'purchase'
        THEN price ELSE 0 END)                                     AS total_revenue,
    ROUND(AVG(CASE WHEN event_type = 'purchase'
        THEN price END)::NUMERIC, 2)                               AS avg_price,
    ROUND(
        COUNT(CASE WHEN event_type = 'purchase' THEN 1 END) * 100.0 /
        NULLIF(COUNT(CASE WHEN event_type = 'view' THEN 1 END), 0)
    , 2)                                                           AS view_to_purchase_rate
FROM raw_events
GROUP BY category_code;

-- 인덱스
CREATE INDEX idx_category_summary_code ON category_summary(category_code);


-- =====================================================
-- 6. brand_summary
-- 브랜드·카테고리별 집계
-- =====================================================

CREATE TABLE brand_summary AS
SELECT
    COALESCE(brand, 'Unknown')                                     AS brand,
    category_code,
    COUNT(CASE WHEN event_type = 'view'     THEN 1 END)            AS total_views,
    COUNT(CASE WHEN event_type = 'cart'     THEN 1 END)            AS total_carts,
    COUNT(CASE WHEN event_type = 'purchase' THEN 1 END)            AS total_purchases,
    SUM(CASE WHEN event_type = 'purchase'
        THEN price ELSE 0 END)                                     AS total_revenue,
    ROUND(AVG(CASE WHEN event_type = 'purchase'
        THEN price END)::NUMERIC, 2)                               AS avg_price
FROM raw_events
GROUP BY COALESCE(brand, 'Unknown'), category_code;

-- 인덱스
CREATE INDEX idx_brand_summary_brand ON brand_summary(brand);


-- =====================================================
-- 7. created_at 컬럼 추가 (데이터 적재 시간 기록)
-- =====================================================

ALTER TABLE user_summary    ADD COLUMN created_at TIMESTAMP DEFAULT NOW();
ALTER TABLE session_summary ADD COLUMN created_at TIMESTAMP DEFAULT NOW();
ALTER TABLE cohort_summary  ADD COLUMN created_at TIMESTAMP DEFAULT NOW();
ALTER TABLE cohort_purchase ADD COLUMN created_at TIMESTAMP DEFAULT NOW();
ALTER TABLE category_summary ADD COLUMN created_at TIMESTAMP DEFAULT NOW();
ALTER TABLE brand_summary   ADD COLUMN created_at TIMESTAMP DEFAULT NOW();


-- =====================================================
-- 8. 데이터 클리닝 뷰
-- =====================================================

-- clean_events
-- 이상 가격(상위 0.1% 초과) 및 중복 purchase 제거
-- 5분 이내 동일 세션·상품 중복 purchase는 오류로 판단해 제외
CREATE VIEW clean_events AS
SELECT
    event_time,
    event_type,
    product_id,
    category_id,
    category_code,
    brand,
    price,
    user_id,
    user_session
FROM raw_events
WHERE price <= 1659.94
AND (
    event_type <> 'purchase'
    OR (
        event_type = 'purchase'
        AND NOT (user_session, product_id, event_time) IN (
            SELECT r2.user_session, r2.product_id, r2.event_time
            FROM raw_events r1
            JOIN raw_events r2
                ON  r1.user_session = r2.user_session
                AND r1.product_id   = r2.product_id
                AND r1.event_type   = 'purchase'
                AND r2.event_type   = 'purchase'
                AND r2.event_time   > r1.event_time
                AND EXTRACT(EPOCH FROM r2.event_time - r1.event_time) / 60 <= 5
        )
    )
);

-- clean_sessions
-- 봇성 세션 제거: duration=0 & view=1인 단순 노출 세션 제외
CREATE VIEW clean_sessions AS
SELECT
    user_session,
    user_id,
    session_start,
    session_end,
    session_duration_min,
    total_views,
    total_carts,
    total_purchases,
    total_revenue,
    drop_stage,
    created_at
FROM session_summary
WHERE total_views <= 100
AND NOT (
    session_duration_min = 0
    AND total_views = 1
    AND drop_stage = 'view'
);
