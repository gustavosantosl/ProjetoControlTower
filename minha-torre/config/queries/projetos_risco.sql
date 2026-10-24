WITH causas AS (
  SELECT projeto_id, causa_bloqueio, count(*) AS ocorrencias,
         sum(coalesce(dias_impacto, 0)) AS dias_impacto
  FROM lakehouse_vertice.gold.status_estruturado
  WHERE data_status BETWEEN DATE'2026-07-18' AND DATE'2026-10-16'
    AND causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
  GROUP BY projeto_id, causa_bloqueio
), causas_ordenadas AS (
  SELECT *, row_number() OVER (
    PARTITION BY projeto_id ORDER BY ocorrencias DESC, causa_bloqueio
  ) AS posicao
  FROM causas
), resumo AS (
  SELECT projeto_id,
         max(CASE WHEN posicao = 1 THEN causa_bloqueio END) AS causa_mais_frequente,
         sum(CASE WHEN causa_bloqueio = 'falta_sre' THEN dias_impacto ELSE 0 END) AS dias_falta_sre,
         sum(CASE WHEN causa_bloqueio = 'rotatividade' THEN dias_impacto ELSE 0 END) AS dias_rotatividade
  FROM causas_ordenadas
  GROUP BY projeto_id
)
SELECT p.projeto, p.nome, p.cliente, p.situacao, p.spi, p.cpi,
       p.estouro_previsto, p.atraso_projetado_dias,
       p.farol_do_gerente, p.farol_calculado, p.melancia,
       r.causa_mais_frequente,
       coalesce(r.dias_falta_sre, 0) AS dias_falta_sre,
       coalesce(r.dias_rotatividade, 0) AS dias_rotatividade
FROM lakehouse_vertice.gold.projeto_situacao_atual p
LEFT JOIN resumo r ON r.projeto_id = p.projeto
WHERE p.status = 'em_andamento'
ORDER BY CASE p.situacao WHEN 'crítico' THEN 0 WHEN 'atenção' THEN 1 ELSE 2 END,
         p.spi ASC, p.cpi ASC, p.projeto
