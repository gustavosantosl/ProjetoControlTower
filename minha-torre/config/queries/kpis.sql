-- Todas as fórmulas de KPI residem na metric view governada.
SELECT
  MEASURE(projetos) AS projetos_em_andamento,
  MEASURE(projetos_em_risco) AS projetos_em_risco,
  MEASURE(projetos_criticos) AS projetos_criticos,
  MEASURE(projetos_melancia) AS melancias,
  MEASURE(estouro_previsto) AS estouro_previsto,
  MEASURE(carteira) AS carteira
FROM lakehouse_vertice.gold.mv_projetos
GROUP BY ALL
