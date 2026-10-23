SET TIME ZONE 'America/Belize';
SET query_dop = 1;

/* 1. 创建目标表 */

DROP TABLE IF EXISTS wangchuanliang.user_behavior_track_record;

CREATE TABLE wangchuanliang.user_behavior_track_record
(
    user_id                 bigint NOT NULL,     -- 业务用户ID
    sequence_id             text NOT NULL,       -- 原始用户关联键
    app_name                text,                -- App名称
    app_version             text,                -- App版本
    sdk_version             text,                -- SDK版本
    device_key              text,                -- 非空设备标识的MD5

    event_type              text NOT NULL,       -- 原始事件类型
    event_time              timestamp NOT NULL,  -- Belize实际事件时间
    event_unix              bigint NOT NULL,     -- 原始事件毫秒时间戳
    event_date              date NOT NULL,       -- 业务日期，分区键
    page_id                 text,                -- 页面编码
    launch_time             bigint,              -- 原始App启动时间戳

    page_title              text,                -- 页面显示标题
    page_type               text,                -- page_view_in/page_view_out
    page_view_in_time       bigint,              -- 页面访问起点，毫秒

    element_id              text,                -- 完整控件编码
    element_type            text,                -- 输入阶段等原始标记
    element_start_time      bigint,              -- 本轮输入起点，毫秒
    input_text_present      smallint,            -- 输入文本是否非空
    input_text_length       integer,             -- 输入文本字符数
    element_value           text,                -- 仅保留开关状态值

    launch_type             text,                -- 启动类型原始编码
    touch_type              text,                -- 触摸类型原始编码
    touch_count             integer              -- SDK触摸数量字段
)
WITH
(
    orientation = column,
    compression = middle,
    colversion = 3.0,
    enable_delta = false
)
DISTRIBUTE BY HASH (user_id)
PARTITION BY RANGE (event_date)
(
    PARTITION p_init VALUES LESS THAN ('2026-09-21')
);

/* 2. 创建2026-09-21至2027-12-31的日分区 */

DO
$$
DECLARE
    d date;
BEGIN
    FOR d IN
        SELECT generate_series(
            DATE '2026-09-21',
            DATE '2027-12-31',
            INTERVAL '1 day'
        )::date
    LOOP
        EXECUTE format(
            'ALTER TABLE wangchuanliang.user_behavior_track_record
             ADD PARTITION p_%s VALUES LESS THAN (%L)',
            to_char(d, 'YYYYMMDD'),
            to_char(d + 1, 'YYYY-MM-DD')
        );
    END LOOP;

    ALTER TABLE wangchuanliang.user_behavior_track_record
        ADD PARTITION p_default VALUES LESS THAN (MAXVALUE);
END
$$;


/* 解析失败时返回空，避免一条坏 JSON 让整周 INSERT 失败 */

CREATE OR REPLACE FUNCTION wangchuanliang.safe_behavior_json(raw text)
RETURNS json
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN NULLIF(TRIM(raw), '')::json;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

/*
3. 按周独立导入

日期口径：America/Belize。
每批采用左闭右开区间。
通过sequence_id关联用户表，排除空白sequence_id。
event_type 为空或空白的行跳过，避免非空约束让整周失败。
behavior_data 无法解析时该行仍导入，页面和控件字段为空。
不保存point、输入原文或具体金额。
*/

/* 第1批：2026-09-21至2026-09-27 */

WITH parsed AS
(
    SELECT
        b.*,
        wangchuanliang.safe_behavior_json(b.behavior_data) AS props
    FROM wangchuanliang.user_behavior_data_record b
    WHERE b.event_time >= FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-09-21 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND b.event_time < FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-09-28 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
)
INSERT INTO wangchuanliang.user_behavior_track_record
(
    user_id, sequence_id, app_name, app_version,
    sdk_version, device_key, event_type, event_time,
    event_unix, event_date, page_id, launch_time,
    page_title, page_type, page_view_in_time, element_id,
    element_type, element_start_time,
    input_text_present, input_text_length,
    element_value, launch_type, touch_type, touch_count
)
SELECT
    u.user_id::bigint,
    b.sequence_id,
    b.app_name,
    b.app_version,
    b.sdk_version,
    CASE WHEN NULLIF(TRIM(b.device_id), '') IS NOT NULL
         THEN MD5(b.device_id) END,
    b.event_type,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::timestamp(3),
    b.event_time,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::date,
    b.page_id,
    b.launch_time,
    b.props ->> 'page_title',
    b.props ->> 'page_type',
    CASE WHEN (b.props ->> 'page_view_in_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'page_view_in_time')::bigint END,
    b.props ->> 'element_id',
    b.props ->> 'element_type',
    CASE WHEN (b.props ->> 'element_start_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'element_start_time')::bigint END,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CASE
                 WHEN CHAR_LENGTH(b.props ->> 'element_text') > 0
                 THEN 1 ELSE 0
             END
    END::smallint,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CHAR_LENGTH(b.props ->> 'element_text')
    END,
    CASE WHEN b.event_type = 'switch_change'
         THEN b.props ->> 'element_value' END,
    CASE WHEN b.event_type = 'app_start'
         THEN b.props ->> 'launch_type' END,
    CASE WHEN b.event_type = 'touch_change'
         THEN b.props ->> 'touch_type' END,
    CASE
        WHEN b.event_type = 'touch_change'
         AND (b.props ->> 'touch_count') ~ '^[0-9]{1,9}$'
        THEN (b.props ->> 'touch_count')::integer
    END
FROM parsed b
JOIN wangchuanliang."user" u
  ON b.sequence_id = u.sequence_id
WHERE NULLIF(TRIM(b.sequence_id), '') IS NOT NULL
  AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
  AND u.user_id IS NOT NULL;

/* 第2批：2026-09-28至2026-10-04 */

WITH parsed AS
(
    SELECT
        b.*,
        wangchuanliang.safe_behavior_json(b.behavior_data) AS props
    FROM wangchuanliang.user_behavior_data_record b
    WHERE b.event_time >= FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-09-28 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND b.event_time < FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-05 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
)
INSERT INTO wangchuanliang.user_behavior_track_record
(
    user_id, sequence_id, app_name, app_version,
    sdk_version, device_key, event_type, event_time,
    event_unix, event_date, page_id, launch_time,
    page_title, page_type, page_view_in_time, element_id,
    element_type, element_start_time,
    input_text_present, input_text_length,
    element_value, launch_type, touch_type, touch_count
)
SELECT
    u.user_id::bigint,
    b.sequence_id,
    b.app_name,
    b.app_version,
    b.sdk_version,
    CASE WHEN NULLIF(TRIM(b.device_id), '') IS NOT NULL
         THEN MD5(b.device_id) END,
    b.event_type,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::timestamp(3),
    b.event_time,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::date,
    b.page_id,
    b.launch_time,
    b.props ->> 'page_title',
    b.props ->> 'page_type',
    CASE WHEN (b.props ->> 'page_view_in_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'page_view_in_time')::bigint END,
    b.props ->> 'element_id',
    b.props ->> 'element_type',
    CASE WHEN (b.props ->> 'element_start_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'element_start_time')::bigint END,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CASE
                 WHEN CHAR_LENGTH(b.props ->> 'element_text') > 0
                 THEN 1 ELSE 0
             END
    END::smallint,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CHAR_LENGTH(b.props ->> 'element_text')
    END,
    CASE WHEN b.event_type = 'switch_change'
         THEN b.props ->> 'element_value' END,
    CASE WHEN b.event_type = 'app_start'
         THEN b.props ->> 'launch_type' END,
    CASE WHEN b.event_type = 'touch_change'
         THEN b.props ->> 'touch_type' END,
    CASE
        WHEN b.event_type = 'touch_change'
         AND (b.props ->> 'touch_count') ~ '^[0-9]{1,9}$'
        THEN (b.props ->> 'touch_count')::integer
    END
FROM parsed b
JOIN wangchuanliang."user" u
  ON b.sequence_id = u.sequence_id
WHERE NULLIF(TRIM(b.sequence_id), '') IS NOT NULL
  AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
  AND u.user_id IS NOT NULL;

/* 第3批：2026-10-05至2026-10-11 */

WITH parsed AS
(
    SELECT
        b.*,
        wangchuanliang.safe_behavior_json(b.behavior_data) AS props
    FROM wangchuanliang.user_behavior_data_record b
    WHERE b.event_time >= FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-05 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND b.event_time < FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-12 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
)
INSERT INTO wangchuanliang.user_behavior_track_record
(
    user_id, sequence_id, app_name, app_version,
    sdk_version, device_key, event_type, event_time,
    event_unix, event_date, page_id, launch_time,
    page_title, page_type, page_view_in_time, element_id,
    element_type, element_start_time,
    input_text_present, input_text_length,
    element_value, launch_type, touch_type, touch_count
)
SELECT
    u.user_id::bigint,
    b.sequence_id,
    b.app_name,
    b.app_version,
    b.sdk_version,
    CASE WHEN NULLIF(TRIM(b.device_id), '') IS NOT NULL
         THEN MD5(b.device_id) END,
    b.event_type,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::timestamp(3),
    b.event_time,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::date,
    b.page_id,
    b.launch_time,
    b.props ->> 'page_title',
    b.props ->> 'page_type',
    CASE WHEN (b.props ->> 'page_view_in_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'page_view_in_time')::bigint END,
    b.props ->> 'element_id',
    b.props ->> 'element_type',
    CASE WHEN (b.props ->> 'element_start_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'element_start_time')::bigint END,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CASE
                 WHEN CHAR_LENGTH(b.props ->> 'element_text') > 0
                 THEN 1 ELSE 0
             END
    END::smallint,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CHAR_LENGTH(b.props ->> 'element_text')
    END,
    CASE WHEN b.event_type = 'switch_change'
         THEN b.props ->> 'element_value' END,
    CASE WHEN b.event_type = 'app_start'
         THEN b.props ->> 'launch_type' END,
    CASE WHEN b.event_type = 'touch_change'
         THEN b.props ->> 'touch_type' END,
    CASE
        WHEN b.event_type = 'touch_change'
         AND (b.props ->> 'touch_count') ~ '^[0-9]{1,9}$'
        THEN (b.props ->> 'touch_count')::integer
    END
FROM parsed b
JOIN wangchuanliang."user" u
  ON b.sequence_id = u.sequence_id
WHERE NULLIF(TRIM(b.sequence_id), '') IS NOT NULL
  AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
  AND u.user_id IS NOT NULL;

/* 第4批：2026-10-12至2026-10-18 */

WITH parsed AS
(
    SELECT
        b.*,
        wangchuanliang.safe_behavior_json(b.behavior_data) AS props
    FROM wangchuanliang.user_behavior_data_record b
    WHERE b.event_time >= FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-12 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND b.event_time < FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-19 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
)
INSERT INTO wangchuanliang.user_behavior_track_record
(
    user_id, sequence_id, app_name, app_version,
    sdk_version, device_key, event_type, event_time,
    event_unix, event_date, page_id, launch_time,
    page_title, page_type, page_view_in_time, element_id,
    element_type, element_start_time,
    input_text_present, input_text_length,
    element_value, launch_type, touch_type, touch_count
)
SELECT
    u.user_id::bigint,
    b.sequence_id,
    b.app_name,
    b.app_version,
    b.sdk_version,
    CASE WHEN NULLIF(TRIM(b.device_id), '') IS NOT NULL
         THEN MD5(b.device_id) END,
    b.event_type,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::timestamp(3),
    b.event_time,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::date,
    b.page_id,
    b.launch_time,
    b.props ->> 'page_title',
    b.props ->> 'page_type',
    CASE WHEN (b.props ->> 'page_view_in_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'page_view_in_time')::bigint END,
    b.props ->> 'element_id',
    b.props ->> 'element_type',
    CASE WHEN (b.props ->> 'element_start_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'element_start_time')::bigint END,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CASE
                 WHEN CHAR_LENGTH(b.props ->> 'element_text') > 0
                 THEN 1 ELSE 0
             END
    END::smallint,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CHAR_LENGTH(b.props ->> 'element_text')
    END,
    CASE WHEN b.event_type = 'switch_change'
         THEN b.props ->> 'element_value' END,
    CASE WHEN b.event_type = 'app_start'
         THEN b.props ->> 'launch_type' END,
    CASE WHEN b.event_type = 'touch_change'
         THEN b.props ->> 'touch_type' END,
    CASE
        WHEN b.event_type = 'touch_change'
         AND (b.props ->> 'touch_count') ~ '^[0-9]{1,9}$'
        THEN (b.props ->> 'touch_count')::integer
    END
FROM parsed b
JOIN wangchuanliang."user" u
  ON b.sequence_id = u.sequence_id
WHERE NULLIF(TRIM(b.sequence_id), '') IS NOT NULL
  AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
  AND u.user_id IS NOT NULL;

/* 第5批：2026-10-19起，本周只取执行时刻之前的数据 */

WITH parsed AS
(
    SELECT
        b.*,
        wangchuanliang.safe_behavior_json(b.behavior_data) AS props
    FROM wangchuanliang.user_behavior_data_record b
    WHERE b.event_time >= FLOOR(
        EXTRACT(EPOCH FROM (
            TIMESTAMP '2026-10-19 00:00:00'
            AT TIME ZONE 'America/Belize'
        )) * 1000
    )::bigint
      AND b.event_time < LEAST(
        FLOOR(
            EXTRACT(EPOCH FROM (
                TIMESTAMP '2026-10-26 00:00:00'
                AT TIME ZONE 'America/Belize'
            )) * 1000
        )::bigint,
        FLOOR(EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000)::bigint
      )
      AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
)
INSERT INTO wangchuanliang.user_behavior_track_record
(
    user_id, sequence_id, app_name, app_version,
    sdk_version, device_key, event_type, event_time,
    event_unix, event_date, page_id, launch_time,
    page_title, page_type, page_view_in_time, element_id,
    element_type, element_start_time,
    input_text_present, input_text_length,
    element_value, launch_type, touch_type, touch_count
)
SELECT
    u.user_id::bigint,
    b.sequence_id,
    b.app_name,
    b.app_version,
    b.sdk_version,
    CASE WHEN NULLIF(TRIM(b.device_id), '') IS NOT NULL
         THEN MD5(b.device_id) END,
    b.event_type,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::timestamp(3),
    b.event_time,
    (
        TO_TIMESTAMP(b.event_time / 1000.0)
        AT TIME ZONE 'America/Belize'
    )::date,
    b.page_id,
    b.launch_time,
    b.props ->> 'page_title',
    b.props ->> 'page_type',
    CASE WHEN (b.props ->> 'page_view_in_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'page_view_in_time')::bigint END,
    b.props ->> 'element_id',
    b.props ->> 'element_type',
    CASE WHEN (b.props ->> 'element_start_time') ~ '^[0-9]{13}$'
         THEN (b.props ->> 'element_start_time')::bigint END,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CASE
                 WHEN CHAR_LENGTH(b.props ->> 'element_text') > 0
                 THEN 1 ELSE 0
             END
    END::smallint,
    CASE
        WHEN b.event_type = 'text_change'
         AND json_typeof(b.props -> 'element_text') = 'string'
        THEN CHAR_LENGTH(b.props ->> 'element_text')
    END,
    CASE WHEN b.event_type = 'switch_change'
         THEN b.props ->> 'element_value' END,
    CASE WHEN b.event_type = 'app_start'
         THEN b.props ->> 'launch_type' END,
    CASE WHEN b.event_type = 'touch_change'
         THEN b.props ->> 'touch_type' END,
    CASE
        WHEN b.event_type = 'touch_change'
         AND (b.props ->> 'touch_count') ~ '^[0-9]{1,9}$'
        THEN (b.props ->> 'touch_count')::integer
    END
FROM parsed b
JOIN wangchuanliang."user" u
  ON b.sequence_id = u.sequence_id
WHERE NULLIF(TRIM(b.sequence_id), '') IS NOT NULL
  AND NULLIF(TRIM(b.event_type), '') IS NOT NULL
  AND u.user_id IS NOT NULL;

/* 4. 更新统计信息 */

ANALYZE wangchuanliang.user_behavior_track_record;

/* 5. 查看实际导入的每日数据量 */

SELECT
    event_date,
    COUNT(*) AS record_count
FROM wangchuanliang.user_behavior_track_record
GROUP BY event_date
ORDER BY event_date;

RESET query_dop;