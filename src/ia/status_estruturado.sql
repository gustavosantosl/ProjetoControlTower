-- Tabela acumulativa: cada status e classificado uma unica vez por projeto e data.
CREATE TABLE IF NOT EXISTS lakehouse_vertice.gold.status_estruturado (
  projeto_id STRING COMMENT 'Codigo do projeto no cadastro do PMO.',
  data_status DATE COMMENT 'Sexta-feira a que o status do gerente se refere.',
  farol STRING COMMENT 'Farol informado pelo gerente, padronizado na silver.',
  causa_bloqueio STRING COMMENT 'Causa identificada pela regra, palavra-chave ou IA.',
  bloqueio STRING COMMENT 'Descricao do bloqueio extraida do texto pela IA.',
  quem_destrava STRING COMMENT 'Pessoa ou equipe que pode remover o bloqueio, extraida pela IA.',
  dias_impacto DOUBLE COMMENT 'Impacto declarado em dias; uma semana equivale a sete dias.',
  metodo STRING COMMENT 'Metodo utilizado: regra, ia ou palavra_chave.',
  texto_status STRING COMMENT 'Texto original do status semanal para auditoria.',
  _classificado_em TIMESTAMP COMMENT 'Momento em que o status foi inserido nesta tabela.'
)
USING DELTA
COMMENT 'Status semanais do PMO enriquecidos por regras, palavras-chave e funcoes de IA.';

MERGE INTO lakehouse_vertice.gold.status_estruturado AS destino
USING (
  WITH novos AS (
    SELECT
      s.projeto_id,
      s.data_status,
      s.farol,
      s.texto_status,
      s.status_vazio,
      lower(coalesce(s.texto_status, '')) AS texto_minusculo
    FROM lakehouse_vertice.silver.status_semanal AS s
    LEFT ANTI JOIN lakehouse_vertice.gold.status_estruturado AS existente
      ON s.projeto_id = existente.projeto_id
     AND s.data_status = existente.data_status
  ), roteados AS (
    SELECT *,
      CASE
        WHEN status_vazio THEN 'regra'
        WHEN texto_minusculo RLIKE 'bloqueios: nenhum|sem bloqueios|nada relevante' THEN 'regra'
        WHEN data_status >= DATE'2026-07-18' THEN 'ia'
        ELSE 'palavra_chave'
      END AS metodo
    FROM novos
  ), impactos AS (
    SELECT *,
      coalesce(
        try_cast(nullif(regexp_extract(texto_minusculo, 'impacto estimado de ([0-9]+) dias', 1), '') AS DOUBLE),
        CASE WHEN texto_minusculo RLIKE 'impacto estimado: *1 semana' THEN 7D END
      ) AS dias_por_regra
    FROM roteados
  ), sem_ia AS (
    SELECT
      projeto_id, data_status, farol,
      CASE
        WHEN status_vazio THEN 'nao_reportado'
        WHEN metodo = 'regra' THEN 'sem_bloqueio'
        WHEN texto_minusculo RLIKE 'freeze|congelamento|janela de deploy' THEN 'change_freeze'
        WHEN texto_minusculo RLIKE 'sre|infraestrutura|ambiente de homologação' THEN 'falta_sre'
        WHEN texto_minusculo RLIKE 'forge|consultoria|fornecedor' THEN 'dependencia_fornecedor'
        WHEN texto_minusculo RLIKE 'saída de|rotatividade|onboarding' THEN 'rotatividade'
        WHEN texto_minusculo RLIKE 'escopo|change request|regra de negócio' THEN 'mudanca_escopo'
        WHEN texto_minusculo RLIKE 'bugs|regressão|refazendo' THEN 'bug_retrabalho'
        WHEN texto_minusculo RLIKE 'aprovação do cliente|homologação do cliente' THEN 'aprovacao_cliente'
      END AS causa_bloqueio,
      CAST(NULL AS STRING) AS bloqueio,
      CAST(NULL AS STRING) AS quem_destrava,
      dias_por_regra AS dias_impacto,
      metodo,
      texto_status
    FROM impactos
    WHERE metodo <> 'ia'
  ), chamadas_ia AS (
    SELECT
      projeto_id, data_status, farol, texto_status, metodo,
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
    FROM impactos
    WHERE metodo = 'ia'
  ), com_ia AS (
    SELECT
      projeto_id, data_status, farol,
      CASE
        WHEN classificacao:error_message::STRING IS NOT NULL
          THEN CAST(raise_error(concat('ai_classify falhou em ', projeto_id, ' / ', CAST(data_status AS STRING), ': ', classificacao:error_message::STRING)) AS STRING)
        WHEN classificacao:response[0]::STRING IS NULL
          THEN CAST(raise_error(concat('ai_classify sem resposta em ', projeto_id, ' / ', CAST(data_status AS STRING))) AS STRING)
        ELSE classificacao:response[0]::STRING
      END AS causa_bloqueio,
      CASE
        WHEN extracao:error_message::STRING IS NOT NULL
          THEN CAST(raise_error(concat('ai_extract falhou em ', projeto_id, ' / ', CAST(data_status AS STRING), ': ', extracao:error_message::STRING)) AS STRING)
        ELSE extracao:response:bloqueio::STRING
      END AS bloqueio,
      extracao:response:quem_destrava::STRING AS quem_destrava,
      extracao:response:dias_impacto::DOUBLE AS dias_impacto,
      metodo,
      texto_status
    FROM chamadas_ia
  ), classificados AS (
    SELECT * FROM sem_ia
    UNION ALL
    SELECT * FROM com_ia
  )
  SELECT
    projeto_id, data_status, farol, causa_bloqueio, bloqueio,
    quem_destrava, dias_impacto, metodo, texto_status,
    current_timestamp() AS _classificado_em
  FROM classificados
) AS origem
ON destino.projeto_id = origem.projeto_id
AND destino.data_status = origem.data_status
WHEN NOT MATCHED THEN INSERT (
  projeto_id, data_status, farol, causa_bloqueio, bloqueio,
  quem_destrava, dias_impacto, metodo, texto_status, _classificado_em
) VALUES (
  origem.projeto_id, origem.data_status, origem.farol, origem.causa_bloqueio,
  origem.bloqueio, origem.quem_destrava, origem.dias_impacto, origem.metodo,
  origem.texto_status, origem._classificado_em
);

SELECT metodo, causa_bloqueio, count(*) AS status_classificados
FROM lakehouse_vertice.gold.status_estruturado
GROUP BY metodo, causa_bloqueio
ORDER BY metodo, causa_bloqueio
