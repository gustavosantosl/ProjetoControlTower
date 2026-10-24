-- Cadastro do PMO e de-para entre o projeto e a ferramenta de origem.
CREATE OR REFRESH MATERIALIZED VIEW projetos (
  CONSTRAINT data_inicio_valida EXPECT (data_inicio IS NOT NULL) ON VIOLATION FAIL UPDATE,
  CONSTRAINT ferramenta_valida EXPECT (ferramenta IN ('excel', 'clickup', 'msproject')) ON VIOLATION FAIL UPDATE
)
COMMENT 'Cadastro de projetos do PMO, com datas e ferramentas normalizadas para integrar as tarefas.'
AS SELECT
  * EXCEPT (data_inicio, ferramenta, codigo_ferramenta),
  coalesce(
    try_to_date(trim(data_inicio), 'yyyy-MM-dd'),
    try_to_date(trim(data_inicio), 'dd/MM/yyyy')
  ) AS data_inicio,
  ferramenta AS ferramenta_como_veio,
  CASE
    WHEN lower(trim(ferramenta)) LIKE '%excel%'
      OR lower(trim(ferramenta)) LIKE '%planilha%' THEN 'excel'
    WHEN lower(trim(ferramenta)) LIKE '%clickup%'
      OR lower(trim(ferramenta)) LIKE '%click up%' THEN 'clickup'
    WHEN lower(trim(ferramenta)) LIKE '%project%' THEN 'msproject'
  END AS ferramenta,
  nullif(trim(codigo_ferramenta), '') AS codigo_ferramenta
FROM lakehouse_vertice.bronze.projetos
