-- Rodar somente depois do pipeline: estes checks não criam tabelas na silver.
WITH custos AS (
  SELECT
    (SELECT sum(CAST(replace(valor, ',', '.') AS DECIMAL(18,2)))
       FROM lakehouse_vertice.bronze.custos) AS bronze,
    (SELECT sum(valor) FROM lakehouse_vertice.silver.custos) AS silver
), totais_excel AS (
  SELECT
    e.arquivo,
    coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), '')) AS projeto_id,
    max(CASE WHEN upper(trim(e.tarefa)) = 'TOTAL'
             THEN CAST(replace(lower(e.horas_previstas), 'h', '') AS DECIMAL(18,2)) END) AS total_planilha
  FROM lakehouse_vertice.bronze.excel_tarefas e
  LEFT JOIN lakehouse_vertice.silver.projetos p
    ON p.ferramenta = 'excel' AND p.codigo_ferramenta = e.arquivo
  GROUP BY e.arquivo, coalesce(p.projeto_id, nullif(regexp_extract(e.arquivo, 'PRJ-[0-9]{3}', 0), ''))
), horas_silver AS (
  SELECT projeto_id, sum(horas) AS total_silver
  FROM lakehouse_vertice.silver.tarefas
  WHERE ferramenta = 'excel'
  GROUP BY projeto_id
)
SELECT 'tarefas_silver' AS verificacao,
       CASE WHEN count(*) = 4917 THEN 'ok' ELSE 'divergente' END AS resultado,
       CAST(count(*) AS STRING) AS obtido
FROM lakehouse_vertice.silver.tarefas
UNION ALL
SELECT 'custo_liquido',
       CASE WHEN bronze = silver THEN 'ok' ELSE 'divergente' END,
       concat(CAST(bronze AS STRING), ' / ', CAST(silver AS STRING))
FROM custos
UNION ALL
SELECT concat('horas_excel_', t.arquivo),
       CASE WHEN t.total_planilha = s.total_silver THEN 'ok' ELSE 'divergente' END,
       concat(CAST(t.total_planilha AS STRING), ' / ', CAST(s.total_silver AS STRING))
FROM totais_excel t
LEFT JOIN horas_silver s USING (projeto_id)
ORDER BY verificacao
