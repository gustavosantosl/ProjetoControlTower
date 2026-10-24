CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.fato_projeto_semana (
  CONSTRAINT pv_nao_negativo EXPECT (pv >= 0) ON VIOLATION FAIL UPDATE,
  CONSTRAINT ev_dentro_orcamento EXPECT (ev <= orcamento) ON VIOLATION FAIL UPDATE
)
COMMENT 'Histórico semanal de valor planejado, valor agregado, custo e utilização por projeto.'
AS WITH calendario AS (
  SELECT
    p.projeto_id,
    CAST(p.orcamento_custo AS DECIMAL(18,2)) AS orcamento,
    explode(sequence(
      date_add(CAST(date_trunc('WEEK', p.data_inicio) AS DATE), 4),
      DATE'2026-10-16',
      INTERVAL 1 WEEK
    )) AS semana
  FROM projetos p
  WHERE p.data_inicio <= DATE'2026-10-16'
), horas_projeto AS (
  SELECT projeto_id, sum(horas) AS horas_totais
  FROM tarefas
  GROUP BY projeto_id
), pv_por_semana AS (
  SELECT
    c.projeto_id,
    c.semana,
    c.orcamento,
    try_divide(
      c.orcamento * sum(t.horas * greatest(0D, least(1D,
        coalesce(try_divide(
          datediff(c.semana, t.inicio_baseline),
          datediff(t.fim_baseline, t.inicio_baseline)
        ), 0D)
      ))),
      hp.horas_totais
    ) AS pv
  FROM calendario c
  JOIN tarefas t ON t.projeto_id = c.projeto_id
  JOIN horas_projeto hp ON hp.projeto_id = c.projeto_id
  GROUP BY c.projeto_id, c.semana, c.orcamento, hp.horas_totais
), status_na_semana AS (
  SELECT
    c.projeto_id,
    c.semana,
    s.pct_concluido,
    s.farol
  FROM calendario c
  LEFT JOIN status_semanal s
    ON s.projeto_id = c.projeto_id AND s.data_status = c.semana
), status_preenchido AS (
  SELECT
    projeto_id,
    semana,
    coalesce(last_value(pct_concluido, true) OVER (
      PARTITION BY projeto_id ORDER BY semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ), 0) AS pct_concluido,
    last_value(farol, true) OVER (
      PARTITION BY projeto_id ORDER BY semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS farol_do_gerente
  FROM status_na_semana
), custo_semanal AS (
  SELECT projeto_id, semana, sum(valor) AS custo_semana
  FROM custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id, semana
), custo_acumulado AS (
  SELECT
    c.projeto_id,
    c.semana,
    sum(coalesce(cs.custo_semana, 0)) OVER (
      PARTITION BY c.projeto_id ORDER BY c.semana
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS ac
  FROM calendario c
  LEFT JOIN custo_semanal cs
    ON cs.projeto_id = c.projeto_id AND cs.semana = c.semana
), apontamento_semana AS (
  SELECT
    projeto_id,
    semana,
    sum(horas_disponiveis) AS horas_disponiveis,
    sum(horas_apontadas) AS horas_apontadas
  FROM apontamentos
  WHERE semana <= DATE'2026-10-16'
  GROUP BY projeto_id, semana
)
SELECT
  pv.projeto_id,
  pv.semana,
  pv.orcamento,
  pv.pv,
  pv.orcamento * sp.pct_concluido / 100.0 AS ev,
  coalesce(ca.ac, 0) AS ac,
  CAST(try_divide(pv.orcamento * sp.pct_concluido / 100.0, pv.pv) AS DECIMAL(18,4)) AS spi,
  CAST(try_divide(pv.orcamento * sp.pct_concluido / 100.0, coalesce(ca.ac, 0)) AS DECIMAL(18,4)) AS cpi,
  try_divide(pv.orcamento,
    try_divide(pv.orcamento * sp.pct_concluido / 100.0, coalesce(ca.ac, 0))
  ) AS eac,
  sp.farol_do_gerente,
  coalesce(ap.horas_disponiveis, 0) AS horas_disponiveis,
  coalesce(ap.horas_apontadas, 0) AS horas_apontadas,
  greatest(coalesce(ap.horas_disponiveis, 0) - coalesce(ap.horas_apontadas, 0), 0) AS horas_ociosas
FROM pv_por_semana pv
JOIN status_preenchido sp USING (projeto_id, semana)
LEFT JOIN custo_acumulado ca USING (projeto_id, semana)
LEFT JOIN apontamento_semana ap USING (projeto_id, semana)
