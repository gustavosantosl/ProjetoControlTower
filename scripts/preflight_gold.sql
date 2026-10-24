WITH projeto_base AS (
  SELECT
    projeto_id,
    ferramenta,
    codigo_ferramenta,
    try_cast(orcamento_custo AS DECIMAL(18,2)) AS orcamento,
    try_cast(valor_contrato AS DECIMAL(18,2)) AS valor_contrato,
    data_inicio,
    coalesce(try_to_date(data_fim_baseline, 'yyyy-MM-dd'), try_to_date(data_fim_baseline, 'dd/MM/yyyy')) AS data_fim_baseline,
    status
  FROM lakehouse_vertice.silver.projetos
), tarefas_projeto AS (
  SELECT
    projeto_id,
    sum(horas) AS horas,
    sum(horas * pct_concluido / 100.0) AS horas_ponderadas,
    sum(horas * greatest(0D, least(1D, coalesce(try_divide(datediff(DATE'2026-10-16', inicio_baseline), datediff(fim_baseline, inicio_baseline)), 0D)))) AS horas_pv
  FROM lakehouse_vertice.silver.tarefas
  GROUP BY projeto_id
), custos_projeto AS (
  SELECT projeto_id, sum(valor) AS ac
  FROM lakehouse_vertice.silver.custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id
), ev_tools AS (
  SELECT p.projeto_id, p.orcamento * try_divide(t.horas_ponderadas, t.horas) AS ev
  FROM projeto_base p JOIN tarefas_projeto t USING (projeto_id)
), status_atual AS (
  SELECT projeto_id, pct_concluido
  FROM (
    SELECT projeto_id, pct_concluido,
      row_number() OVER (PARTITION BY projeto_id ORDER BY data_status DESC) AS ordem
    FROM lakehouse_vertice.silver.status_semanal
    WHERE data_status <= DATE'2026-10-16'
  ) WHERE ordem = 1
), ev_status AS (
  SELECT p.projeto_id, p.orcamento * s.pct_concluido / 100.0 AS ev
  FROM projeto_base p JOIN status_atual s USING (projeto_id)
), horas_excel_esperadas AS (
  SELECT e.arquivo,
    coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), '')) AS projeto_id,
    max(CASE WHEN upper(trim(e.tarefa)) = 'TOTAL' THEN CAST(replace(lower(e.horas_previstas), 'h', '') AS DECIMAL(18,2)) END) AS horas_total
  FROM lakehouse_vertice.bronze.excel_tarefas e
  LEFT JOIN projeto_base p ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
  GROUP BY e.arquivo, coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), ''))
), horas_excel_prontas AS (
  SELECT projeto_id, sum(horas) AS horas_total
  FROM lakehouse_vertice.silver.tarefas WHERE ferramenta = 'excel' GROUP BY projeto_id
), calendario AS (
  SELECT p.projeto_id, p.orcamento,
    explode(sequence(date_add(CAST(date_trunc('WEEK', p.data_inicio) AS DATE), 4), DATE'2026-10-16', INTERVAL 1 WEEK)) AS semana
  FROM projeto_base p WHERE p.data_inicio <= DATE'2026-10-16'
), status_semana AS (
  SELECT c.projeto_id, c.semana, s.pct_concluido, s.farol
  FROM calendario c LEFT JOIN lakehouse_vertice.silver.status_semanal s
    ON s.projeto_id = c.projeto_id AND s.data_status = c.semana
), status_preenchido AS (
  SELECT projeto_id, semana,
    coalesce(last_value(pct_concluido, true) OVER (PARTITION BY projeto_id ORDER BY semana ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 0) AS pct,
    last_value(farol, true) OVER (PARTITION BY projeto_id ORDER BY semana ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS farol
  FROM status_semana
), pv_semana AS (
  SELECT c.projeto_id, c.semana, c.orcamento,
    try_divide(c.orcamento * sum(t.horas * greatest(0D, least(1D, coalesce(try_divide(datediff(c.semana, t.inicio_baseline), datediff(t.fim_baseline, t.inicio_baseline)), 0D)))), sum(t.horas)) AS pv
  FROM calendario c JOIN lakehouse_vertice.silver.tarefas t USING (projeto_id)
  GROUP BY c.projeto_id, c.semana, c.orcamento
), fato AS (
  SELECT p.projeto_id, p.semana, p.orcamento, p.pv, p.orcamento * s.pct / 100.0 AS ev
  FROM pv_semana p JOIN status_preenchido s USING (projeto_id, semana)
), status_repetido AS (
  SELECT count(*) AS n FROM (
    SELECT projeto_id, data_status FROM lakehouse_vertice.silver.status_semanal
    GROUP BY projeto_id, data_status HAVING count(*) > 1
  )
), divergencia_ferramenta AS (
  SELECT count(*) AS n FROM (
    SELECT p.projeto_id
    FROM projeto_base p JOIN lakehouse_vertice.silver.tarefas t USING (projeto_id)
    GROUP BY p.projeto_id, p.ferramenta
    HAVING count(DISTINCT t.ferramenta) <> 1 OR max(t.ferramenta) <> p.ferramenta
  )
), custo_semana AS (
  SELECT projeto_id, semana, sum(valor) AS custo
  FROM lakehouse_vertice.silver.custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id, semana
), ac_fato AS (
  SELECT cal.projeto_id, cal.semana,
    sum(coalesce(c.custo, 0)) OVER (
      PARTITION BY cal.projeto_id ORDER BY cal.semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ac
  FROM calendario cal LEFT JOIN custo_semana c USING (projeto_id, semana)
), ultimo_ac AS (
  SELECT projeto_id, ac FROM (
    SELECT projeto_id, ac,
      row_number() OVER (PARTITION BY projeto_id ORDER BY semana DESC) AS rn
    FROM ac_fato
  ) WHERE rn = 1
), custo_bronze AS (
  SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(18,2))) AS valor
  FROM lakehouse_vertice.bronze.custos
), checks AS (
  SELECT 'projects_are_60_unique' AS check_name,
    CASE WHEN (SELECT count(*) FROM projeto_base) = 60 AND (SELECT count(DISTINCT projeto_id) FROM projeto_base) = 60 THEN 0 ELSE 1 END AS issues,
    concat('rows=', CAST((SELECT count(*) FROM projeto_base) AS STRING), '; unique=', CAST((SELECT count(DISTINCT projeto_id) FROM projeto_base) AS STRING)) AS detail
  UNION ALL
  SELECT 'projects_with_tasks_60' AS check_name,
    CASE WHEN (SELECT count(DISTINCT projeto_id) FROM lakehouse_vertice.silver.tarefas) = 60 THEN 0 ELSE 1 END AS issues,
    CAST((SELECT count(DISTINCT projeto_id) FROM lakehouse_vertice.silver.tarefas) AS STRING) AS detail
  UNION ALL
  SELECT 'tool_matches_pmo', (SELECT n FROM divergencia_ferramenta), 'count_mismatched_projects'
  UNION ALL
  SELECT 'status_unique_per_project_week', (SELECT n FROM status_repetido), 'duplicate_project_dates'
  UNION ALL
  SELECT 'status_pct_between_0_and_100',
    (SELECT count(*) FROM lakehouse_vertice.silver.status_semanal WHERE pct_concluido < 0 OR pct_concluido > 100), 'out_of_range_rows'
  UNION ALL
  SELECT 'fact_expectations_pv_ev',
    (SELECT count(*) FROM fato WHERE pv IS NULL OR pv < 0 OR ev IS NULL OR ev > orcamento), 'violating_week_rows'
  UNION ALL
  SELECT 'excel_hours_reconcile',
    CASE WHEN (SELECT count(*) FROM horas_excel_esperadas) = 20 AND
      (SELECT count(*) FROM horas_excel_esperadas e LEFT JOIN horas_excel_prontas s USING (projeto_id)
       WHERE e.horas_total IS NULL OR abs(e.horas_total - s.horas_total) > 0.01) = 0 THEN 0 ELSE 1 END,
    concat('files=', CAST((SELECT count(*) FROM horas_excel_esperadas) AS STRING), '; mismatches=',
      CAST((SELECT count(*) FROM horas_excel_esperadas e LEFT JOIN horas_excel_prontas s USING (projeto_id)
       WHERE e.horas_total IS NULL OR abs(e.horas_total - s.horas_total) > 0.01) AS STRING))
  UNION ALL
  SELECT 'collaborator_unique',
    (SELECT count(*) - count(DISTINCT colaborador_id) FROM lakehouse_vertice.silver.colaboradores), 'duplicate_ids'
  UNION ALL
  SELECT 'codeforge_one_normalized_name',
    CASE WHEN (SELECT count(DISTINCT fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') = 1
      AND (SELECT max(fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') = 'CodeForge Consultoria Ltda'
      AND (SELECT count(*) FROM lakehouse_vertice.silver.entregas_fornecedor WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') > 0 THEN 0 ELSE 1 END,
    CAST((SELECT count(DISTINCT fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') AS STRING)
  UNION ALL
  SELECT 'cost_total_preserved',
    CASE WHEN (SELECT valor FROM custo_bronze) = (SELECT sum(valor) FROM lakehouse_vertice.silver.custos) THEN 0 ELSE 1 END,
    concat(CAST((SELECT valor FROM custo_bronze) AS STRING), ' / ', CAST((SELECT sum(valor) FROM lakehouse_vertice.silver.custos) AS STRING))
  UNION ALL
  SELECT 'ev_status_vs_tools_under_1pct',
    CASE WHEN (SELECT count(*) FROM ev_status) = 60 AND try_divide(abs((SELECT sum(ev) FROM ev_status) - (SELECT sum(ev) FROM ev_tools)), abs((SELECT sum(ev) FROM ev_tools))) < 0.01 THEN 0 ELSE 1 END,
    concat('status=', CAST((SELECT sum(ev) FROM ev_status) AS STRING), '; tools=', CAST((SELECT sum(ev) FROM ev_tools) AS STRING))
  UNION ALL
  SELECT 'latest_status_by_snapshot_has_60_projects',
    CASE WHEN (SELECT count(*) FROM status_atual) = 60 THEN 0 ELSE 1 END,
    CAST((SELECT count(*) FROM status_atual) AS STRING)
  UNION ALL
  SELECT 'active_projects_have_nonzero_pv_ac',
    (SELECT count(*) FROM projeto_base p LEFT JOIN tarefas_projeto t USING (projeto_id) LEFT JOIN custos_projeto c USING (projeto_id)
     WHERE lower(trim(p.status)) = 'em_andamento' AND
       (p.orcamento IS NULL OR p.orcamento = 0 OR t.horas_ponderadas IS NULL OR t.horas_pv IS NULL OR t.horas_pv = 0 OR c.ac IS NULL OR c.ac = 0)),
    'active_projects_with_null_spi_or_cpi_inputs'
  UNION ALL
  SELECT 'ac_fato_reconciles_costs',
    CASE WHEN (SELECT sum(ac) FROM ultimo_ac) = (SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16') THEN 0 ELSE 1 END,
    concat(CAST((SELECT sum(ac) FROM ultimo_ac) AS STRING), ' / ', CAST((SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16') AS STRING))
  UNION ALL
  SELECT 'project_baseline_parse',
    (SELECT count(*) FROM projeto_base WHERE data_fim_baseline IS NULL OR data_fim_baseline < data_inicio),
    'missing_or_negative_baseline_duration'
  UNION ALL
  SELECT 'project_contract_converts',
    (SELECT count(*) FROM projeto_base WHERE valor_contrato IS NULL), 'invalid_or_null_contract_values'
  UNION ALL
  SELECT 'hourly_cost_converts',
    (SELECT count(*) FROM lakehouse_vertice.silver.colaboradores WHERE try_cast(custo_hora AS DECIMAL(18,2)) IS NULL),
    'invalid_or_null_hourly_costs'
  UNION ALL
  SELECT 'negative_project_budget',
    (SELECT count(*) FROM projeto_base WHERE orcamento < 0 OR orcamento IS NULL), 'negative_or_null_budgets'
)
SELECT check_name, issues, detail FROM checks ORDER BY check_name
