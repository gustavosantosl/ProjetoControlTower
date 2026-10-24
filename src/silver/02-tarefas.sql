-- Cada origem entrega as mesmas 13 colunas para a união final.
CREATE TEMPORARY VIEW tarefas_excel AS
SELECT
  coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), '')) AS projeto_id,
  'excel' AS ferramenta,
  cast(e.id AS STRING) AS id_na_ferramenta,
  e.fase,
  e.tarefa,
  e.responsavel,
  CASE WHEN e.inicio_previsto LIKE '%/%' THEN try_to_date(e.inicio_previsto, 'dd/MM/yyyy')
       WHEN nullif(trim(e.inicio_previsto), '') IS NOT NULL
         THEN date_add(DATE'1899-12-30', CAST(e.inicio_previsto AS INT)) END AS inicio_baseline,
  CASE WHEN e.termino_previsto LIKE '%/%' THEN try_to_date(e.termino_previsto, 'dd/MM/yyyy')
       WHEN nullif(trim(e.termino_previsto), '') IS NOT NULL
         THEN date_add(DATE'1899-12-30', CAST(e.termino_previsto AS INT)) END AS fim_baseline,
  CASE WHEN e.inicio_real LIKE '%/%' THEN try_to_date(e.inicio_real, 'dd/MM/yyyy')
       WHEN nullif(trim(e.inicio_real), '') IS NOT NULL
         THEN date_add(DATE'1899-12-30', CAST(e.inicio_real AS INT)) END AS inicio_real,
  CASE WHEN e.termino_real LIKE '%/%' THEN try_to_date(e.termino_real, 'dd/MM/yyyy')
       WHEN nullif(trim(e.termino_real), '') IS NOT NULL
         THEN date_add(DATE'1899-12-30', CAST(e.termino_real AS INT)) END AS fim_real,
  CASE WHEN instr(e.pct_concluido, '%') > 0 THEN CAST(replace(replace(e.pct_concluido, '%', ''), ',', '.') AS DOUBLE)
       ELSE CAST(replace(e.pct_concluido, ',', '.') AS DOUBLE) * 100 END AS pct_como_veio,
  CAST(replace(lower(e.horas_previstas), 'h', '') AS DECIMAL(12,2)) AS horas,
  cast(NULL AS STRING) AS status_na_ferramenta
FROM lakehouse_vertice.bronze.excel_tarefas e
LEFT JOIN projetos p
  ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
WHERE upper(trim(e.tarefa)) <> 'TOTAL';

CREATE TEMPORARY VIEW tarefas_clickup AS
SELECT
  coalesce(p_codigo.projeto_id, p_nome.projeto_id) AS projeto_id,
  'clickup' AS ferramenta,
  cast(c.id AS STRING) AS id_na_ferramenta,
  cast(filter(c.custom_fields, f -> f.name = 'Fase')[0].value AS STRING) AS fase,
  c.name AS tarefa,
  get_json_object(to_json(c.assignees), '$[0].username') AS responsavel,
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Início baseline')[0].value AS BIGINT))) AS inicio_baseline,
  to_date(timestamp_millis(CAST(filter(c.custom_fields, f -> f.name = 'Fim baseline')[0].value AS BIGINT))) AS fim_baseline,
  to_date(timestamp_millis(CAST(c.start_date AS BIGINT))) AS inicio_real,
  to_date(timestamp_millis(CAST(c.date_done AS BIGINT))) AS fim_real,
  CAST(filter(c.custom_fields, f -> f.name = 'Progresso (%)')[0].value AS DOUBLE) AS pct_como_veio,
  CAST(c.time_estimate / 3600000.0 AS DECIMAL(12,2)) AS horas,
  CASE
    WHEN lower(trim(c.status.status)) RLIKE 'complete|done|conclu|fechad|finaliz|entreg' THEN 'concluida'
    WHEN lower(trim(c.status.status)) RLIKE 'open|to do|backlog|penden|a fazer|não iniciad' THEN 'a_fazer'
    ELSE 'em_andamento'
  END AS status_na_ferramenta
FROM lakehouse_vertice.bronze.clickup_tarefas c
LEFT JOIN projetos p_codigo
  ON p_codigo.ferramenta = 'clickup' AND p_codigo.codigo_ferramenta = cast(c.list_id AS STRING)
LEFT JOIN projetos p_nome
  ON p_nome.ferramenta = 'clickup'
 AND p_nome.codigo_ferramenta IS NULL
 AND lower(trim(p_nome.nome_projeto)) = lower(trim(c.list_name));

CREATE TEMPORARY VIEW tarefas_msproject AS
WITH fase_por_linha AS (
  SELECT
    m.*,
    last_value(CASE WHEN CAST(m.OutlineLevel AS INT) = 1 THEN m.Name END, true)
      OVER (PARTITION BY m.arquivo ORDER BY CAST(m.UID AS INT)
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS fase_atual
  FROM lakehouse_vertice.bronze.msproject_tarefas m
)
SELECT
  p.projeto_id,
  'msproject' AS ferramenta,
  cast(m.UID AS STRING) AS id_na_ferramenta,
  m.fase_atual AS fase,
  m.Name AS tarefa,
  cast(NULL AS STRING) AS responsavel,
  to_date(m.Baseline.Start) AS inicio_baseline,
  to_date(m.Baseline.Finish) AS fim_baseline,
  to_date(m.ActualStart) AS inicio_real,
  to_date(m.ActualFinish) AS fim_real,
  CAST(m.PercentComplete AS DOUBLE) AS pct_como_veio,
  CAST(regexp_extract(m.Work, 'PT([0-9]+)H', 1) AS DECIMAL(12,2)) AS horas,
  CASE WHEN CAST(m.PercentComplete AS DOUBLE) >= 100 THEN 'concluida'
       WHEN CAST(m.PercentComplete AS DOUBLE) = 0 THEN 'a_fazer'
       ELSE 'em_andamento' END AS status_na_ferramenta
FROM fase_por_linha m
LEFT JOIN projetos p
  ON p.ferramenta = 'msproject' AND p.codigo_ferramenta = m.arquivo
WHERE CAST(m.Summary AS INT) = 0;

CREATE OR REFRESH MATERIALIZED VIEW tarefas (
  CONSTRAINT achou_o_projeto EXPECT (projeto_id IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT percentual_valido EXPECT (pct_concluido BETWEEN 0 AND 100) ON VIOLATION FAIL UPDATE,
  CONSTRAINT horas_positivas EXPECT (horas > 0) ON VIOLATION FAIL UPDATE
)
COMMENT 'Tarefas de Excel, ClickUp e MS Project no mesmo formato, sem totais ou tarefas-resumo.'
AS WITH unificadas AS (
  SELECT * FROM tarefas_excel
  UNION ALL SELECT * FROM tarefas_clickup
  UNION ALL SELECT * FROM tarefas_msproject
)
SELECT
  concat_ws('-', projeto_id, ferramenta, id_na_ferramenta) AS tarefa_id,
  projeto_id, ferramenta, id_na_ferramenta, fase, tarefa, responsavel,
  inicio_baseline, fim_baseline, inicio_real, fim_real,
  pct_como_veio,
  least(pct_como_veio, 100.0) AS pct_concluido,
  pct_como_veio > 100 AS pct_veio_acima_de_100,
  horas, status_na_ferramenta
FROM unificadas
