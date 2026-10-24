-- Os três cadastros repetidos diferem pelo uso de caixa alta no papel.
CREATE OR REFRESH MATERIALIZED VIEW colaboradores
COMMENT 'Cadastro único de colaboradores, preferindo o registro cujo papel já estava em minúsculas.'
AS WITH classificados AS (
  SELECT
    c.*,
    row_number() OVER (
      PARTITION BY colaborador_id
      ORDER BY CASE WHEN papel = lower(papel) THEN 0 ELSE 1 END
    ) AS posicao
  FROM lakehouse_vertice.bronze.colaboradores c
)
SELECT * EXCEPT (posicao)
FROM classificados
WHERE posicao = 1;

CREATE OR REFRESH MATERIALIZED VIEW apontamentos
COMMENT 'Horas semanais apontadas por colaborador e projeto, com semana referida à sexta-feira.'
AS SELECT
  * EXCEPT (semana_inicio, horas_disponiveis, horas_apontadas),
  to_date(semana_inicio) AS semana_inicio,
  CAST(horas_disponiveis AS DECIMAL(12,2)) AS horas_disponiveis,
  CAST(horas_apontadas AS DECIMAL(12,2)) AS horas_apontadas,
  date_add(to_date(semana_inicio), 4) AS semana
FROM lakehouse_vertice.bronze.apontamentos
