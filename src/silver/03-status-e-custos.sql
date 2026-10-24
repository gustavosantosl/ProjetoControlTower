CREATE OR REFRESH MATERIALIZED VIEW status_semanal (
  CONSTRAINT farol_valido EXPECT (farol IN ('verde', 'amarelo', 'vermelho')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Histórico semanal do PMO com farol padronizado e status vazio identificado sem perder linhas.'
AS SELECT
  * EXCEPT (data_status, farol, pct_concluido),
  to_date(data_status) AS data_status,
  lower(trim(farol)) AS farol,
  CAST(pct_concluido AS INT) AS pct_concluido,
  lower(trim(coalesce(texto_status, ''))) IN ('', 'n/a', 'ver ata da reunião') AS status_vazio
FROM lakehouse_vertice.bronze.status_semanal;

CREATE OR REFRESH MATERIALIZED VIEW custos
COMMENT 'Lançamentos de custo líquido, com vírgula decimal recuperada e estornos preservados.'
AS SELECT
  * EXCEPT (data, valor),
  to_date(data) AS data,
  CAST(replace(valor, ',', '.') AS DECIMAL(18,2)) AS valor,
  instr(valor, ',') > 0 AS valor_veio_com_virgula,
  CAST(replace(valor, ',', '.') AS DECIMAL(18,2)) < 0 AS estorno,
  date_add(CAST(date_trunc('WEEK', to_date(data)) AS DATE), 4) AS semana
FROM lakehouse_vertice.bronze.custos
