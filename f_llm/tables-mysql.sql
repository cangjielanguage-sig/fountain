-- =============================================================================
-- f_llm 全部表结构（MySQL 版，MariaDB 兼容子集）
--
-- 配套文件：tables-pg.sql（列定义保持一致，只允许类型/自增/索引语法不同）
-- 版本要求：
--   * 普通表：MySQL 8.0+ / MariaDB 10.6+
--   * VECTOR 列：MySQL **9.2+**（9.0/9.1 只有类型，没有可用的 ANN 索引）
--   * HNSW 向量索引：MySQL 9.2+ `CREATE VECTOR INDEX ... USING HNSW`
--     - 旧版本/不支持时：删掉文件末尾三条 VECTOR INDEX 语句，
--       MySqlMemoryStore 会自动降级为「取候选 + 应用层暴力算」，结果不变只是慢
--   * MariaDB 无 VECTOR 类型：同样删掉向量列/索引，降级方案同上
--
-- 维护约定：与 tables-pg.sql 必须同步改；列名、默认值、唯一键语义完全一致。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 模型配置（既有表）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_conf (
  id               BIGINT       NOT NULL AUTO_INCREMENT,
  provider         VARCHAR(64)  NOT NULL DEFAULT '',
  llm_name         VARCHAR(128) NOT NULL DEFAULT '',
  actual_llm_name  VARCHAR(128) NOT NULL DEFAULT '',
  llm_url          VARCHAR(512) NOT NULL DEFAULT '',
  auth             VARCHAR(512) NOT NULL DEFAULT '',
  temperature      DOUBLE       NOT NULL DEFAULT -1,
  always_thinking  TINYINT(1)   NOT NULL DEFAULT 0,
  conf             LONGTEXT     NULL,
  enabled          TINYINT(1)   NOT NULL DEFAULT 1,
  weight           BIGINT       NOT NULL DEFAULT 1,
  PRIMARY KEY (id),
  KEY idx_llm_conf_name (llm_name, enabled)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 2. 智能体、技能、记忆摘要、待办、token 用量（既有表）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS agents (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  agent_name  VARCHAR(128) NOT NULL DEFAULT '',
  agent       LONGTEXT     NULL,
  acceptable  LONGTEXT     NULL,
  producings  LONGTEXT     NULL,
  category    VARCHAR(64)  NOT NULL DEFAULT '',
  tag         VARCHAR(64)  NOT NULL DEFAULT '',
  llm_type    VARCHAR(32)  NOT NULL DEFAULT '',
  llm_name    VARCHAR(128) NOT NULL DEFAULT '',
  pruner      VARCHAR(256) NOT NULL DEFAULT '',
  PRIMARY KEY (id),
  KEY idx_agents_name (agent_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS skills (
  id             BIGINT       NOT NULL AUTO_INCREMENT,
  agent_id       BIGINT       NOT NULL DEFAULT 0,
  accepted_event VARCHAR(64)  NOT NULL DEFAULT '',
  returned_event VARCHAR(64)  NOT NULL DEFAULT '',
  title          VARCHAR(256) NOT NULL DEFAULT '',
  metadata       LONGTEXT     NULL,
  details        LONGTEXT     NULL,
  functions      LONGTEXT     NULL,
  version        INT          NOT NULL DEFAULT 1,   -- 技能自演进版本（§10.4）
  skill_type     VARCHAR(32)  NOT NULL DEFAULT '',
  PRIMARY KEY (id),
  KEY idx_skills_agent (agent_id, accepted_event)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS skill_references (
  skill_title VARCHAR(256) NOT NULL DEFAULT '',
  title       VARCHAR(256) NOT NULL DEFAULT '',
  content     LONGTEXT     NULL,
  KEY idx_skill_ref_title (skill_title)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS memory_summaries (
  id      BIGINT      NOT NULL AUTO_INCREMENT,
  kind    VARCHAR(32) NOT NULL DEFAULT '',
  content LONGTEXT    NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS agent_todo (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  title       VARCHAR(256) NOT NULL DEFAULT '',
  content     LONGTEXT     NULL,
  status      VARCHAR(32)  NOT NULL DEFAULT 'pending',
  predecessor LONGTEXT     NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS llm_token_usage (
  id                BIGINT       NOT NULL AUTO_INCREMENT,
  llm_id            BIGINT       NOT NULL DEFAULT 0,
  agent_id          BIGINT       NOT NULL DEFAULT 0,
  session           VARCHAR(128) NOT NULL DEFAULT '',
  prompt_tokens     BIGINT       NOT NULL DEFAULT 0,
  completion_tokens BIGINT       NOT NULL DEFAULT 0,
  total_tokens      BIGINT       NOT NULL DEFAULT 0,
  cached_tokens     BIGINT       NOT NULL DEFAULT 0,
  usage_time        BIGINT       NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_usage_agent (agent_id, usage_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 3. 记忆（新增）
--    namespace = 'global' 或 'ws-{workspaceId}'
--    唯一键 (user_id, namespace, title)：同空间同标题幂等覆盖
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_memory (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  user_id     BIGINT       NOT NULL DEFAULT 0,
  namespace   VARCHAR(32)  NOT NULL,
  title       VARCHAR(128) NOT NULL,
  content     LONGTEXT     NULL,
  kind        VARCHAR(32)  NOT NULL DEFAULT 'note',   -- note|fact|preference|task|doc|knowledge|session，运行期可扩展
  save_time   DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
  update_time DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  UNIQUE KEY uk_memory_user_ns_title (user_id, namespace, title),
  KEY idx_memory_ns_time (user_id, namespace, save_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 记忆种类：预定义 7 值（user_id=0 全局），自定义 kind 归属用户；预定义行不允许删除（API 层拒绝）
CREATE TABLE IF NOT EXISTS llm_memory_kind (
  user_id     BIGINT      NOT NULL DEFAULT 0,
  kind        VARCHAR(32) NOT NULL,
  predefined  TINYINT(1)  NOT NULL DEFAULT 0,
  weight      DOUBLE      NOT NULL DEFAULT 0.8,   -- 检索打分权重 0~1，自动记忆更低
  create_time DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (user_id, kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT IGNORE INTO llm_memory_kind (user_id, kind, predefined, weight) VALUES
  (0, 'note', 1, 0.9), (0, 'fact', 1, 1.0), (0, 'preference', 1, 1.0),
  (0, 'task', 1, 0.6), (0, 'doc', 1, 0.8), (0, 'knowledge', 1, 0.8), (0, 'session', 1, 0.3);

-- 记忆事件（§5.5 事件溯源）：先落事件再异步消费，processed=0 的会被重试
CREATE TABLE IF NOT EXISTS llm_memory_event (
  id          BIGINT      NOT NULL AUTO_INCREMENT,
  user_id     BIGINT      NOT NULL,
  session     VARCHAR(64) NOT NULL,
  task_name   VARCHAR(64) NOT NULL DEFAULT '',
  event_type  VARCHAR(32) NOT NULL,
  step_id     VARCHAR(64) NOT NULL DEFAULT '',
  payload     LONGTEXT    NOT NULL,
  processed   TINYINT(1)  NOT NULL DEFAULT 0,
  retry_count INT         NOT NULL DEFAULT 0,
  event_time  DATETIME    NOT NULL,
  PRIMARY KEY (id),
  KEY idx_event_pending (processed, event_time),
  KEY idx_event_session (user_id, session, event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- VECTOR(1024)：MySQL 9.2+；旧版本用 BLOB 存 f32 小端字节，应用层同样能算
CREATE TABLE IF NOT EXISTS llm_memory_vector (
  memory_id       BIGINT      NOT NULL,
  model           VARCHAR(64) NOT NULL,
  title_dense     VECTOR(1024) NULL,
  content_dense   VECTOR(1024) NULL,
  -- colbert：二进制 f32[]（count(Int32 LE) + count*dim*Float32 LE），不存 JSON
  title_colbert   LONGBLOB    NULL,
  content_colbert LONGBLOB    NULL,
  has_sparse      TINYINT(1)  NOT NULL DEFAULT 0,
  has_colbert     TINYINT(1)  NOT NULL DEFAULT 0,
  update_time     DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (memory_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS llm_memory_token (
  memory_id BIGINT       NOT NULL,
  user_id   BIGINT       NOT NULL,
  namespace VARCHAR(32)  NOT NULL,
  field     CHAR(1)      NOT NULL,           -- 't' 标题 / 'c' 正文
  token     BIGINT       NOT NULL,           -- bge-m3 token id
  weight    DOUBLE       NOT NULL,
  PRIMARY KEY (memory_id, field, token),
  KEY idx_memory_token_lookup (user_id, namespace, field, token)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 4. 人设（新增）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_character (
  id            BIGINT      NOT NULL AUTO_INCREMENT,
  user_id       BIGINT      NOT NULL DEFAULT 0,
  character_key VARCHAR(32) NOT NULL DEFAULT 'default',
  prompts       LONGTEXT    NULL,
  update_time   DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (id),
  UNIQUE KEY uk_character_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 4.1 人格绑定（工作空间/任务/流程），只存 key 不存提示词正文
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_character_binding (
  user_id       BIGINT      NOT NULL,
  scope_type    VARCHAR(16) NOT NULL,   -- workspace | task | flow
  scope_id      VARCHAR(64) NOT NULL,
  character_key VARCHAR(32) NOT NULL,
  update_time   DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (user_id, scope_type, scope_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 4.2 通道绑定（微信/企微/飞书/钉钉/QQ/邮件）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_channel_binding (
  user_id      BIGINT       NOT NULL,
  channel      VARCHAR(16)  NOT NULL,
  external_id  VARCHAR(128) NOT NULL,
  display_name VARCHAR(128) NOT NULL DEFAULT '',
  auto_send    TINYINT(1)   NOT NULL DEFAULT 0,
  enabled      TINYINT(1)   NOT NULL DEFAULT 1,
  update_time  DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (user_id, channel, external_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 4.3 技能版本（升级前存旧版本，支持回滚）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_skill_version (
  skill_id     BIGINT       NOT NULL,
  version      INT          NOT NULL,
  details      LONGTEXT     NOT NULL,
  functions    LONGTEXT     NOT NULL,
  change_note  VARCHAR(256) NOT NULL DEFAULT '',
  created_time DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (skill_id, version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
-- 5. 向量索引（MySQL 9.2+）
--    距离度量与 pg 保持一致：余弦（COSINE）
--    实施阶段用 EXPLAIN 确认命中；不命中时检查列维度与索引参数
-- -----------------------------------------------------------------------------
CREATE VECTOR INDEX idx_memory_title_dense
  ON llm_memory_vector (title_dense) USING HNSW;
CREATE VECTOR INDEX idx_memory_content_dense
  ON llm_memory_vector (content_dense) USING HNSW;

-- -----------------------------------------------------------------------------
-- 6. loom 流程定义（新增）
--    JitFunction 不可序列化：这里存计划与源码，启动时重新编译
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS llm_loom_flow (
  name         VARCHAR(64) NOT NULL,
  description  LONGTEXT    NULL,
  plan_json    LONGTEXT    NOT NULL,
  flow_source  LONGTEXT    NOT NULL,
  step_sources LONGTEXT    NOT NULL,
  status       VARCHAR(16) NOT NULL DEFAULT 'pending',   -- pending | compiled | failed
  tools        TEXT        NULL,
  mcps         TEXT        NULL,
  created_time DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  update_time  DATETIME    NOT NULL DEFAULT (UTC_TIMESTAMP()),
  PRIMARY KEY (name),
  KEY idx_loom_status (status, update_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
