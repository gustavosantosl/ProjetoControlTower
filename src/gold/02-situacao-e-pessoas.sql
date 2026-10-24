CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.projeto_situacao_atual
COMMENT 'Fotografia de cada projeto em 16/10/2026, com os KPIs calculados a partir das tarefas e dos custos.'
AS WITH horas AS (
  SELECT projeto_id, sum(horas) AS horas_totais
  FROM tarefas
  GROUP BY projeto_id
), tarefas_projeto AS (
  SELECT
    t.projeto_id,
    try_divide(sum(t.horas * greatest(0D, least(1D,
      coalesce(try_divide(
        datediff(DATE'2026-10-16', t.inicio_baseline),
        datediff(t.fim_baseline, t.inicio_baseline)
      ), 0D)
    ))), h.horas_totais) AS fracao_pv,
    try_divide(sum(t.horas * t.pct_concluido / 100.0), h.horas_totais) AS fracao_ev
  FROM tarefas t
  JOIN horas h USING (projeto_id)
  GROUP BY t.projeto_id, h.horas_totais
), custos_ate_hoje AS (
  SELECT projeto_id, sum(valor) AS ac
  FROM custos
  WHERE data <= DATE'2026-10-16'
  GROUP BY projeto_id
), farol_hoje AS (
  SELECT projeto_id, farol
  FROM (
    SELECT projeto_id, farol,
      row_number() OVER (PARTITION BY projeto_id ORDER BY data_status DESC) AS ordem
    FROM status_semanal
    WHERE data_status <= DATE'2026-10-16'
  )
  WHERE ordem = 1
), medidas AS (
  SELECT
    p.projeto_id AS projeto,
    p.nome_projeto AS nome,
    p.cliente,
    p.segmento,
    p.tipo_projeto,
    p.ferramenta,
    p.gerente_projeto,
    CAST(p.valor_contrato AS DECIMAL(18,2)) AS valor_contrato,
    CAST(p.orcamento_custo AS DECIMAL(18,2)) AS orcamento,
    p.data_inicio,
    coalesce(
      try_to_date(p.data_fim_baseline, 'yyyy-MM-dd'),
      try_to_date(p.data_fim_baseline, 'dd/MM/yyyy')
    ) AS data_fim_baseline,
    datediff(
      coalesce(
        try_to_date(p.data_fim_baseline, 'yyyy-MM-dd'),
        try_to_date(p.data_fim_baseline, 'dd/MM/yyyy')
      ), p.data_inicio
    ) AS duracao_baseline_dias,
    p.status,
    CAST(p.orcamento_custo AS DECIMAL(18,2)) * tp.fracao_pv AS pv,
    CAST(p.orcamento_custo AS DECIMAL(18,2)) * tp.fracao_ev AS ev,
    coalesce(c.ac, 0) AS ac,
    fh.farol AS farol_do_gerente
  FROM projetos p
  LEFT JOIN tarefas_projeto tp USING (projeto_id)
  LEFT JOIN custos_ate_hoje c USING (projeto_id)
  LEFT JOIN farol_hoje fh USING (projeto_id)
), kpis AS (
  SELECT
    *,
    try_divide(ev, pv) AS spi,
    try_divide(ev, ac) AS cpi
  FROM medidas
), previsoes AS (
  SELECT
    *,
    try_divide(orcamento, cpi) AS eac,
    try_divide(valor_contrato - try_divide(orcamento, cpi), valor_contrato) AS margem_projetada,
    CAST(ceil(try_divide(duracao_baseline_dias, spi)) AS INT) AS duracao_projetada_dias
  FROM kpis
)
SELECT
  projeto, nome, cliente, segmento, tipo_projeto, ferramenta, gerente_projeto,
  valor_contrato, orcamento, data_inicio, data_fim_baseline,
  duracao_baseline_dias, status, pv, ev, ac, spi, cpi, eac,
  greatest(eac - orcamento, 0) AS estouro_previsto,
  margem_projetada,
  duracao_projetada_dias - duracao_baseline_dias AS atraso_projetado_dias,
  date_add(data_inicio, duracao_projetada_dias) AS termino_projetado,
  CASE
    WHEN lower(trim(status)) <> 'em_andamento' THEN 'concluído'
    WHEN spi < 0.8 OR cpi < 0.8 THEN 'crítico'
    WHEN spi < 0.9 OR cpi < 0.9 THEN 'atenção'
    ELSE 'ok'
  END AS situacao,
  farol_do_gerente,
  CASE WHEN spi >= 0.95 THEN 'verde'
       WHEN spi >= 0.90 THEN 'amarelo'
       ELSE 'vermelho' END AS farol_calculado,
  lower(trim(status)) = 'em_andamento'
    AND lower(trim(farol_do_gerente)) = 'verde'
    AND spi < 0.9 AS melancia
FROM previsoes;

CREATE OR REFRESH MATERIALIZED VIEW lakehouse_vertice.gold.utilizacao_pessoa_semana
COMMENT 'Horas disponíveis, apontadas e ociosas por colaborador, projeto e semana, com o SPI do projeto.'
AS SELECT
  a.colaborador_id,
  c.nome,
  c.papel,
  c.senioridade,
  a.projeto_id,
  a.semana,
  a.horas_disponiveis,
  a.horas_apontadas,
  greatest(a.horas_disponiveis - a.horas_apontadas, 0) AS horas_ociosas,
  try_divide(a.horas_apontadas, a.horas_disponiveis) AS utilizacao,
  greatest(a.horas_disponiveis - a.horas_apontadas, 0) * CAST(c.custo_hora AS DECIMAL(18,2)) AS custo_ocioso,
  f.spi AS spi_do_projeto
FROM apontamentos a
JOIN colaboradores c USING (colaborador_id)
LEFT JOIN lakehouse_vertice.gold.fato_projeto_semana f
  ON f.projeto_id = a.projeto_id AND f.semana = a.semana
