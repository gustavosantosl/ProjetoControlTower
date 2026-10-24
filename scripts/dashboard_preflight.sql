-- Consultas idênticas às do dashboard, com prefixo Gold apenas nesta conferência.

SELECT 'carteira_kpis' AS dataset, count(*) AS linhas FROM (
SELECT
  count(*) AS projetos_em_andamento,
  sum(valor_contrato) AS carteira,
  try_divide(sum(ev), sum(pv)) AS spi,
  try_divide(sum(ev), sum(ac)) AS cpi,
  sum(estouro_previsto) AS estouro_previsto,
  count_if(situacao IN ('atenção', 'crítico')) AS projetos_em_risco,
  count_if(situacao = 'crítico') AS projetos_criticos,
  count_if(melancia) AS melancias
FROM lakehouse_vertice.gold.projeto_situacao_atual
WHERE status = 'em_andamento'
) AS dados;

SELECT 'projetos' AS dataset, count(*) AS linhas FROM (
SELECT projeto, nome, cliente, segmento, valor_contrato, spi, cpi,
       estouro_previsto, situacao, farol_do_gerente, farol_calculado, melancia
FROM lakehouse_vertice.gold.projeto_situacao_atual
WHERE status = 'em_andamento'
ORDER BY estouro_previsto DESC, projeto
) AS dados;

SELECT 'estouros' AS dataset, count(*) AS linhas FROM (
SELECT projeto, nome, situacao, estouro_previsto
FROM lakehouse_vertice.gold.projeto_situacao_atual
WHERE status = 'em_andamento' AND estouro_previsto > 0
ORDER BY estouro_previsto DESC, projeto
) AS dados;

SELECT 'evolucao_semanal' AS dataset, count(*) AS linhas FROM (
SELECT semana,
       try_divide(sum(ev), sum(pv)) AS spi,
       try_divide(sum(ev), sum(ac)) AS cpi
FROM lakehouse_vertice.gold.fato_projeto_semana
WHERE semana BETWEEN DATE'2025-03-07' AND DATE'2026-10-16'
GROUP BY semana
ORDER BY semana
) AS dados;

SELECT 'pessoas_custo_ocioso' AS dataset, count(*) AS linhas FROM (
SELECT colaborador_id, nome, papel,
       sum(custo_ocioso) AS custo_ocioso,
       sum(horas_ociosas) AS horas_ociosas
FROM lakehouse_vertice.gold.utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24' AND semana <= DATE'2026-10-16'
GROUP BY colaborador_id, nome, papel
ORDER BY custo_ocioso DESC, colaborador_id
LIMIT 15
) AS dados;

SELECT 'pessoas_utilizacao' AS dataset, count(*) AS linhas FROM (
SELECT colaborador_id, nome, papel, projeto_id,
       sum(horas_disponiveis) AS horas_disponiveis,
       sum(horas_apontadas) AS horas_apontadas,
       sum(horas_ociosas) AS horas_ociosas,
       try_divide(sum(horas_apontadas), sum(horas_disponiveis)) AS utilizacao,
       sum(custo_ocioso) AS custo_ocioso
FROM lakehouse_vertice.gold.utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24' AND semana <= DATE'2026-10-16'
GROUP BY colaborador_id, nome, papel, projeto_id
ORDER BY utilizacao ASC, custo_ocioso DESC, colaborador_id, projeto_id
) AS dados;

SELECT 'causas_por_projeto' AS dataset, count(*) AS linhas FROM (
WITH bloqueios AS (
  SELECT projeto_id, causa_bloqueio, count(*) AS ocorrencias
  FROM lakehouse_vertice.gold.status_estruturado
  WHERE data_status BETWEEN DATE'2026-07-18' AND DATE'2026-10-16'
    AND causa_bloqueio IS NOT NULL
    AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
  GROUP BY projeto_id, causa_bloqueio
), projetos_mais_afetados AS (
  SELECT projeto_id
  FROM bloqueios
  GROUP BY projeto_id
  ORDER BY sum(ocorrencias) DESC, projeto_id
  LIMIT 15
)
SELECT b.projeto_id, b.causa_bloqueio, b.ocorrencias
FROM bloqueios b
JOIN projetos_mais_afetados p USING (projeto_id)
ORDER BY b.projeto_id, b.causa_bloqueio
) AS dados;

SELECT 'fornecedores' AS dataset, count(*) AS linhas FROM (
SELECT fornecedor,
       concat_ws(', ', sort_array(collect_set(fornecedor_como_veio))) AS grafias_no_cadastro,
       count(*) AS entregas,
       try_divide(
         sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_real_dias END),
         sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_prometido_dias END)
       ) AS prazo_real_sobre_prometido,
       try_divide(
         count_if(data_entrega IS NOT NULL AND data_entrega <= data_prometida),
         count_if(data_entrega IS NOT NULL)
       ) AS percentual_no_prazo,
       count_if(em_atraso) AS em_atraso_hoje
FROM lakehouse_vertice.silver.entregas_fornecedor
GROUP BY fornecedor
ORDER BY em_atraso_hoje DESC, entregas DESC, fornecedor
) AS dados;

SELECT 'entregas_em_atraso' AS dataset, count(*) AS linhas FROM (
SELECT fornecedor, fornecedor_como_veio, data_pedido, data_prometida,
       data_entrega, prazo_prometido_dias, dias_de_atraso_na_entrega, em_aberto
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE em_atraso = true
ORDER BY dias_de_atraso_na_entrega DESC, data_prometida, fornecedor
) AS dados;

-- Valores dos KPIs da carteira
SELECT
  count(*) AS projetos_em_andamento,
  sum(valor_contrato) AS carteira,
  try_divide(sum(ev), sum(pv)) AS spi,
  try_divide(sum(ev), sum(ac)) AS cpi,
  sum(estouro_previsto) AS estouro_previsto,
  count_if(situacao IN ('atenção', 'crítico')) AS projetos_em_risco,
  count_if(situacao = 'crítico') AS projetos_criticos,
  count_if(melancia) AS melancias
FROM lakehouse_vertice.gold.projeto_situacao_atual
WHERE status = 'em_andamento';

-- CodeForge: prazo, pontualidade e atraso
SELECT * FROM (
SELECT fornecedor,
       concat_ws(', ', sort_array(collect_set(fornecedor_como_veio))) AS grafias_no_cadastro,
       count(*) AS entregas,
       try_divide(
         sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_real_dias END),
         sum(CASE WHEN data_entrega IS NOT NULL THEN prazo_prometido_dias END)
       ) AS prazo_real_sobre_prometido,
       try_divide(
         count_if(data_entrega IS NOT NULL AND data_entrega <= data_prometida),
         count_if(data_entrega IS NOT NULL)
       ) AS percentual_no_prazo,
       count_if(em_atraso) AS em_atraso_hoje
FROM lakehouse_vertice.silver.entregas_fornecedor
GROUP BY fornecedor
ORDER BY em_atraso_hoje DESC, entregas DESC, fornecedor
) AS dados WHERE fornecedor = 'CodeForge Consultoria Ltda';
