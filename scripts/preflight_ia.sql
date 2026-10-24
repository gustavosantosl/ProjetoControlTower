WITH status_roteados AS (
  SELECT
    projeto_id,
    data_status,
    status_vazio,
    CASE
      WHEN status_vazio THEN 'regra'
      WHEN lower(coalesce(texto_status, '')) RLIKE 'bloqueios: nenhum|sem bloqueios|nada relevante' THEN 'regra'
      WHEN data_status >= DATE'2026-07-18' THEN 'ia'
      ELSE 'palavra_chave'
    END AS metodo
  FROM lakehouse_vertice.silver.status_semanal
), chaves_repetidas AS (
  SELECT count(*) AS total
  FROM (
    SELECT projeto_id, data_status
    FROM status_roteados
    GROUP BY projeto_id, data_status
    HAVING count(*) > 1
  )
)
SELECT 'total_status' AS verificacao, count(*) AS quantidade FROM status_roteados
UNION ALL
SELECT concat('metodo_', metodo), count(*) FROM status_roteados GROUP BY metodo
UNION ALL
SELECT 'chaves_repetidas', total FROM chaves_repetidas
UNION ALL
SELECT 'chaves_nulas', count(*) FROM status_roteados WHERE projeto_id IS NULL OR data_status IS NULL
ORDER BY verificacao;

WITH amostra AS (
  SELECT projeto_id, data_status, texto_status
  FROM lakehouse_vertice.silver.status_semanal
  WHERE data_status >= DATE'2026-07-18'
    AND NOT status_vazio
    AND NOT (lower(coalesce(texto_status, '')) RLIKE 'bloqueios: nenhum|sem bloqueios|nada relevante')
  ORDER BY projeto_id, data_status
  LIMIT 1
), respostas AS (
  SELECT
    projeto_id,
    data_status,
    ai_classify(
      texto_status,
      '["change_freeze","falta_sre","dependencia_fornecedor","rotatividade","mudanca_escopo","bug_retrabalho","aprovacao_cliente","sem_bloqueio"]',
      map('version', '2.0')
    ) AS classificacao,
    ai_extract(
      texto_status,
      '{"bloqueio":{"type":"string"},"quem_destrava":{"type":"string"},"dias_impacto":{"type":"number","description":"Impacto estimado em dias. Converta 1 semana em 7 dias."}}',
      map('version', '2.0')
    ) AS extracao
  FROM amostra
)
SELECT
  projeto_id,
  data_status,
  classificacao:response[0]::STRING AS causa_bloqueio,
  classificacao:error_message::STRING AS erro_classificacao,
  extracao:response:dias_impacto::DOUBLE AS dias_impacto,
  extracao:error_message::STRING AS erro_extracao
FROM respostas
