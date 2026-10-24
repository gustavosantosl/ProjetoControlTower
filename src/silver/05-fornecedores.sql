CREATE OR REFRESH MATERIALIZED VIEW entregas_fornecedor
COMMENT 'Entregas de consultorias com fornecedor normalizado e prazos comparáveis na data fixa de 16/10/2026.'
AS WITH datas AS (
  SELECT
    * EXCEPT (data_pedido, data_prometida, data_entrega, fornecedor),
    fornecedor AS fornecedor_como_veio,
    CASE
      WHEN replace(lower(fornecedor), ' ', '') LIKE '%codeforge%'
        THEN 'CodeForge Consultoria Ltda'
      ELSE fornecedor
    END AS fornecedor,
    to_date(data_pedido) AS data_pedido,
    to_date(data_prometida) AS data_prometida,
    try_to_date(nullif(trim(data_entrega), ''), 'yyyy-MM-dd') AS data_entrega
  FROM lakehouse_vertice.bronze.entregas_fornecedor
)
SELECT
  *,
  datediff(data_prometida, data_pedido) AS prazo_prometido_dias,
  CASE WHEN data_entrega IS NOT NULL THEN datediff(data_entrega, data_pedido) END AS prazo_real_dias,
  greatest(datediff(coalesce(data_entrega, DATE'2026-10-16'), data_prometida), 0) AS dias_de_atraso_na_entrega,
  data_entrega IS NULL AS em_aberto,
  data_entrega IS NULL AND data_prometida < DATE'2026-10-16' AS em_atraso
FROM datas
