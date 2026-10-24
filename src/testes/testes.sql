WITH horas_excel_esperadas AS (
  SELECT
    e.arquivo,
    coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), '')) AS projeto_id,
    max(CASE WHEN upper(trim(e.tarefa)) = 'TOTAL'
      THEN CAST(replace(lower(e.horas_previstas), 'h', '') AS DECIMAL(18,2)) END) AS horas_total
  FROM lakehouse_vertice.bronze.excel_tarefas e
  LEFT JOIN lakehouse_vertice.silver.projetos p
    ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
  GROUP BY e.arquivo, coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), ''))
), horas_excel_prontas AS (
  SELECT projeto_id, sum(horas) AS horas_total
  FROM lakehouse_vertice.silver.tarefas
  WHERE ferramenta = 'excel'
  GROUP BY projeto_id
), custo_bronze AS (
  SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(18,2))) AS valor
  FROM lakehouse_vertice.bronze.custos
), ev_ferramentas AS (
  SELECT p.projeto_id, CAST(p.orcamento_custo AS DECIMAL(18,2)) * try_divide(sum(t.horas * t.pct_concluido / 100.0), sum(t.horas)) AS ev
  FROM lakehouse_vertice.silver.projetos p
  JOIN lakehouse_vertice.silver.tarefas t USING (projeto_id)
  GROUP BY p.projeto_id, p.orcamento_custo
), status_atual AS (
  SELECT projeto_id, pct_concluido
  FROM (
    SELECT projeto_id, pct_concluido,
      row_number() OVER (PARTITION BY projeto_id ORDER BY data_status DESC) AS ordem
    FROM lakehouse_vertice.silver.status_semanal
    WHERE data_status <= DATE'2026-10-16'
  )
  WHERE ordem = 1
), ev_status AS (
  SELECT p.projeto_id, CAST(p.orcamento_custo AS DECIMAL(18,2)) * s.pct_concluido / 100.0 AS ev
  FROM lakehouse_vertice.silver.projetos p JOIN status_atual s USING (projeto_id)
), ultimo_ac AS (
  SELECT projeto_id, ac
  FROM (
    SELECT projeto_id, semana, ac,
      row_number() OVER (PARTITION BY projeto_id ORDER BY semana DESC) AS ordem
    FROM lakehouse_vertice.gold.fato_projeto_semana
    WHERE semana <= DATE'2026-10-16'
  )
  WHERE ordem = 1
), verificacoes AS (
  SELECT
    '01_projetos_com_tarefas' AS teste,
    (SELECT count(DISTINCT projeto_id) FROM lakehouse_vertice.silver.tarefas) = 60 AS passou,
    CAST((SELECT count(DISTINCT projeto_id) FROM lakehouse_vertice.silver.tarefas) AS STRING) AS obtido
  UNION ALL
  SELECT
    '02_ferramenta_compativel_com_pmo',
    (SELECT count(*) FROM (
       SELECT p.projeto_id
       FROM lakehouse_vertice.silver.projetos p JOIN lakehouse_vertice.silver.tarefas t USING (projeto_id)
       GROUP BY p.projeto_id, p.ferramenta
       HAVING count(DISTINCT t.ferramenta) <> 1 OR max(t.ferramenta) <> p.ferramenta
     )) = 0,
    CAST((SELECT count(*) FROM (
       SELECT p.projeto_id
       FROM lakehouse_vertice.silver.projetos p JOIN lakehouse_vertice.silver.tarefas t USING (projeto_id)
       GROUP BY p.projeto_id, p.ferramenta
       HAVING count(DISTINCT t.ferramenta) <> 1 OR max(t.ferramenta) <> p.ferramenta
     )) AS STRING)
  UNION ALL
  SELECT
    '03_horas_excel_batem_com_total',
    (SELECT count(*) FROM horas_excel_esperadas) = 20
      AND (SELECT count(*) FROM horas_excel_esperadas e
           LEFT JOIN horas_excel_prontas s USING (projeto_id)
           WHERE e.horas_total IS NULL OR abs(e.horas_total - s.horas_total) > 0.01) = 0,
    CAST((SELECT count(*) FROM horas_excel_esperadas e
          LEFT JOIN horas_excel_prontas s USING (projeto_id)
          WHERE e.horas_total IS NULL OR abs(e.horas_total - s.horas_total) > 0.01) AS STRING)
  UNION ALL
  SELECT
    '04_colaborador_unico',
    (SELECT count(*) = count(DISTINCT colaborador_id) FROM lakehouse_vertice.silver.colaboradores),
    CAST((SELECT count(*) - count(DISTINCT colaborador_id) FROM lakehouse_vertice.silver.colaboradores) AS STRING)
  UNION ALL
  SELECT
    '05_codeforge_normalizada',
    (SELECT count(DISTINCT fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor
      WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') = 1
      AND (SELECT max(fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor
        WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') = 'CodeForge Consultoria Ltda'
      AND (SELECT count(*) FROM lakehouse_vertice.silver.entregas_fornecedor
        WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') > 0,
    CAST((SELECT count(DISTINCT fornecedor) FROM lakehouse_vertice.silver.entregas_fornecedor
      WHERE replace(lower(fornecedor), ' ', '') LIKE '%codeforge%') AS STRING)
  UNION ALL
  SELECT
    '06_custo_preservado',
    b.valor = (SELECT sum(valor) FROM lakehouse_vertice.silver.custos),
    concat(CAST(b.valor AS STRING), ' / ', CAST((SELECT sum(valor) FROM lakehouse_vertice.silver.custos) AS STRING))
  FROM custo_bronze b
  UNION ALL
  SELECT
    '07_fotografia_com_60_projetos',
    (SELECT count(*) = 60 AND count(DISTINCT projeto) = 60
       FROM lakehouse_vertice.gold.projeto_situacao_atual),
    CAST((SELECT count(*) FROM lakehouse_vertice.gold.projeto_situacao_atual) AS STRING)
  UNION ALL
  SELECT
    '08_kpis_presentes_em_projetos_ativos',
    (SELECT count(*) FROM lakehouse_vertice.gold.projeto_situacao_atual
      WHERE lower(trim(status)) = 'em_andamento' AND (spi IS NULL OR cpi IS NULL)) = 0,
    CAST((SELECT count(*) FROM lakehouse_vertice.gold.projeto_situacao_atual
      WHERE lower(trim(status)) = 'em_andamento' AND (spi IS NULL OR cpi IS NULL)) AS STRING)
  UNION ALL
  SELECT
    '09_ev_status_vs_ferramentas_menos_de_1pct',
    (SELECT count(*) FROM ev_status) = 60
      AND try_divide(abs((SELECT sum(ev) FROM ev_status) - (SELECT sum(ev) FROM ev_ferramentas)),
                     abs((SELECT sum(ev) FROM ev_ferramentas))) < 0.01,
    concat(CAST((SELECT sum(ev) FROM ev_status) AS STRING), ' / ',
           CAST((SELECT sum(ev) FROM ev_ferramentas) AS STRING))
  UNION ALL
  SELECT
    '10_ac_fato_reconcilia_custos',
    (SELECT sum(ac) FROM ultimo_ac) = (SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16'),
    concat(CAST((SELECT sum(ac) FROM ultimo_ac) AS STRING), ' / ',
           CAST((SELECT sum(valor) FROM lakehouse_vertice.silver.custos WHERE data <= DATE'2026-10-16') AS STRING))
)
SELECT
  teste,
  CASE WHEN passou THEN 'ok'
       ELSE raise_error(concat('Teste de qualidade falhou: ', teste, ' · obtido: ', obtido))
  END AS resultado,
  obtido
FROM verificacoes
ORDER BY teste
