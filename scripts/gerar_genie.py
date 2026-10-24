#!/usr/bin/env python3
"""Gera a definição versionada do Genie Farol · Diretoria."""

import argparse
import json
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "resources" / "farol.geniespace.json"
PREFIX = "lakehouse_vertice"
QUESTIONS = [
    "Por que o projeto PRJ-011 atrasou e quem pode ajudar?",
    "Tenho gente parada enquanto outro projeto precisa de ajuda?",
    "Quais fornecedores ameaçam as próximas entregas?",
    "O que vai dar errado no próximo mês, e o que eu faço agora?",
]


def identifier(kind: str, text: str) -> str:
    return uuid.uuid5(uuid.NAMESPACE_URL, f"vertice/farol/{kind}/{text}").hex


def item(kind: str, text: str, **fields: object) -> dict[str, object]:
    return {"id": identifier(kind, text), **fields}


def sorted_ids(items: list[dict[str, object]]) -> list[dict[str, object]]:
    return sorted(items, key=lambda entry: str(entry["id"]))


def table(name: str, configs: list[dict[str, object]] | None = None) -> dict[str, object]:
    result: dict[str, object] = {"identifier": f"{PREFIX}.{name}"}
    if configs:
        result["column_configs"] = sorted(configs, key=lambda entry: str(entry["column_name"]))
    return result


def example(question: str, sql: str) -> dict[str, object]:
    return item("example", question, question=[question], sql=[sql.strip()])


EXAMPLES = [
    example(QUESTIONS[0], """
WITH causas AS (
  SELECT s.projeto_id, s.causa_bloqueio, COUNT(*) AS semanas,
         SUM(COALESCE(s.dias_impacto, 0)) AS dias_impacto
  FROM lakehouse_vertice.gold.status_estruturado AS s
  WHERE s.projeto_id = 'PRJ-011'
    AND s.data_status BETWEEN DATE'2026-07-18' AND DATE'2026-10-16'
    AND s.causa_bloqueio NOT IN ('sem_bloqueio', 'nao_reportado')
  GROUP BY s.projeto_id, s.causa_bloqueio
), sres AS (
  SELECT u.colaborador_id, MAX(u.nome) AS nome,
         TRY_DIVIDE(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) AS utilizacao
  FROM lakehouse_vertice.gold.utilizacao_pessoa_semana AS u
  WHERE u.semana > DATE'2026-07-24' AND u.semana <= DATE'2026-10-16'
    AND LOWER(u.papel) LIKE '%sre%'
  GROUP BY u.colaborador_id
  HAVING TRY_DIVIDE(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) < 0.2
)
SELECT p.projeto, p.nome, p.spi, p.cpi, p.atraso_projetado_dias,
       c.causa_bloqueio, c.semanas, c.dias_impacto,
       CASE WHEN c.causa_bloqueio = 'falta_sre'
         THEN (SELECT CONCAT_WS(', ', SORT_ARRAY(COLLECT_SET(CONCAT(s.colaborador_id, ' ', s.nome)))) FROM sres AS s)
       END AS sres_ociosos
FROM lakehouse_vertice.gold.projeto_situacao_atual AS p
JOIN causas AS c ON c.projeto_id = p.projeto
WHERE p.projeto = 'PRJ-011' AND p.status = 'em_andamento'
ORDER BY c.semanas DESC, c.dias_impacto DESC
"""),
    example(QUESTIONS[1], """
WITH pessoas AS (
  SELECT u.colaborador_id, MAX(u.nome) AS nome, MAX(u.papel) AS papel,
         TRY_DIVIDE(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) AS utilizacao,
         TRY_DIVIDE(SUM(u.horas_ociosas), COUNT(DISTINCT u.semana)) AS horas_ociosas_media_semana,
         TRY_DIVIDE(SUM(u.custo_ocioso), COUNT(DISTINCT u.semana)) AS custo_ocioso_medio_semana
  FROM lakehouse_vertice.gold.utilizacao_pessoa_semana AS u
  WHERE u.semana > DATE'2026-07-24' AND u.semana <= DATE'2026-10-16'
  GROUP BY u.colaborador_id
  HAVING TRY_DIVIDE(SUM(u.horas_apontadas), SUM(u.horas_disponiveis)) < 0.2
)
SELECT p.colaborador_id, p.nome, p.papel, p.utilizacao,
       p.horas_ociosas_media_semana, p.custo_ocioso_medio_semana,
       d.projeto, d.nome AS projeto_destino, d.situacao, d.spi
FROM pessoas AS p
CROSS JOIN lakehouse_vertice.gold.projeto_situacao_atual AS d
WHERE d.status = 'em_andamento' AND d.situacao IN ('atenção', 'crítico')
ORDER BY CASE WHEN LOWER(p.papel) LIKE '%sre%' THEN d.atraso_projetado_dias END DESC,
         p.custo_ocioso_medio_semana DESC, d.spi ASC
LIMIT 20
"""),
    example(QUESTIONS[2], """
SELECT e.fornecedor,
       COUNT(*) AS entregas,
       TRY_DIVIDE(SUM(CASE WHEN e.data_entrega IS NOT NULL THEN e.prazo_real_dias END),
                  SUM(CASE WHEN e.data_entrega IS NOT NULL THEN e.prazo_prometido_dias END)) AS prazo_real_sobre_prometido,
       COUNT_IF(e.em_atraso) AS entregas_em_atraso,
       MAX(e.dias_de_atraso_na_entrega) AS maior_atraso_dias
FROM lakehouse_vertice.silver.entregas_fornecedor AS e
GROUP BY e.fornecedor
ORDER BY entregas_em_atraso DESC, prazo_real_sobre_prometido DESC
"""),
    example(QUESTIONS[3], """
WITH entregas AS (
  SELECT 'consultoria em atraso' AS risco, e.fornecedor AS entidade,
         CONCAT('Entrega prometida em ', CAST(e.data_prometida AS STRING),
                ', ', CAST(e.dias_de_atraso_na_entrega AS STRING), ' dias em atraso') AS evidencia,
         'Cobrar plano e nova data do fornecedor' AS acao
  FROM lakehouse_vertice.silver.entregas_fornecedor AS e
  WHERE e.em_atraso AND e.data_prometida <= DATE'2026-11-15'
), freeze AS (
  SELECT 'change freeze de varejo' AS risco, p.projeto AS entidade,
         CONCAT(p.cliente, ': e-commerce, SPI ', CAST(ROUND(p.spi, 2) AS STRING),
                ', término projetado ', CAST(p.termino_projetado AS STRING)) AS evidencia,
         'Antecipar homologação e deploy antes de 01/11/2026' AS acao
  FROM lakehouse_vertice.gold.projeto_situacao_atual AS p
  WHERE p.status = 'em_andamento'
    AND LOWER(p.segmento) LIKE '%varejo%'
    AND LOWER(p.tipo_projeto) LIKE '%commerce%'
    AND p.termino_projetado >= DATE'2026-11-01'
    AND p.termino_projetado <= DATE'2027-01-10'
)
SELECT * FROM entregas UNION ALL SELECT * FROM freeze
ORDER BY risco, entidade
"""),
]


BASE_RULES = [
    "Público: dono da Vértice Tecnologia e diretoria. Responda em português, com evidência, projeto/cliente e ação concreta.",
    "HOJE é 16/10/2026, a fotografia fixa do dataset. Últimos 90 dias = 18/07/2026 a 16/10/2026. Últimas 12 semanas = semana > 24/07/2026 e <= 16/10/2026. Próximo mês = 17/10/2026 a 16/11/2026. Nunca use current_date().",
    "Para totais de hoje use gold.mv_projetos com MEASURE() e GROUP BY ALL. Para ranking e detalhes por projeto use gold.projeto_situacao_atual com status = 'em_andamento'. Cada cliente deve aparecer uma única vez em perguntas 'quais clientes', com DISTINCT ou GROUP BY cliente.",
    "Para toda pergunta 'quantos projetos' ou 'qual total da carteira', inclusive em risco, críticos e melancias, escolha exclusivamente gold.mv_projetos e a medida governada projetos, projetos_em_risco, projetos_criticos ou projetos_melancia. Não recalcule esses totais com COUNT na tabela projeto_situacao_atual.",
    "SPI da carteira = SUM(EV)/SUM(PV), CPI = SUM(EV)/SUM(AC). Margem projetada = (SUM(valor_contrato)-SUM(EAC))/SUM(valor_contrato). Projeto em risco: situacao atenção ou crítico. Crítico: SPI < 0,8 ou CPI < 0,8. Atenção: SPI < 0,9 ou CPI < 0,9. Melancia: farol_do_gerente verde e SPI < 0,9. Exponha ambos os faróis quando diferirem.",
    "gold.fato_projeto_semana contém PV, EV e AC ACUMULADOS em cada semana. Para valor de um projeto no período escolha a semana mais recente até o corte. Nunca some valores acumulados de semanas distintas.",
    "Para 'por que o projeto X atrasou', consulte gold.status_estruturado em 18/07/2026 a 16/10/2026. Exclua sem_bloqueio e nao_reportado, conte ocorrências e some dias_impacto por causa. Junte SPI e atraso projetado da fotografia. Se a causa for falta_sre, identifique SREs com utilização < 20% nas últimas 12 semanas. Não afirme causalidade além do status registrado.",
    "Gente parada: em gold.utilizacao_pessoa_semana, agregue as últimas 12 semanas por colaborador e calcule SUM(horas_apontadas)/SUM(horas_disponiveis) < 0,20. Horas e custo ocioso médios por semana dividem pelo número de semanas observadas. Não confunda média semanal com total do período.",
    "Fornecedor: silver.entregas_fornecedor traz o nome normalizado. Prazo real sobre prometido = SUM(prazo_real_dias)/SUM(prazo_prometido_dias) apenas para entregas concluídas. em_atraso marca entregas abertas vencidas na fotografia de 16/10/2026.",
    "Para 'o que vai dar errado no próximo mês', junte entregas de consultoria em atraso e projetos de e-commerce de varejo afetados pelo change freeze de 01/11/2026 a 10/01/2027. Relacione risco, evidência e ação recomendada. Não trate risco como certeza.",
]


def build(score_exists: bool) -> dict[str, object]:
    tables = [
        table("gold.fato_projeto_semana"),
        table("gold.projeto_situacao_atual", [
            {"column_name": "cliente", "synonyms": ["conta", "empresa"], "enable_entity_matching": True},
            {"column_name": "projeto", "synonyms": ["código do projeto"], "enable_entity_matching": True},
            {"column_name": "situacao", "synonyms": ["risco", "estado"], "enable_format_assistance": True},
        ]),
        table("gold.status_estruturado", [
            {"column_name": "causa_bloqueio", "synonyms": ["motivo do atraso", "causa"], "enable_format_assistance": True},
            {"column_name": "_classificado_em", "exclude": True},
        ]),
        table("gold.utilizacao_pessoa_semana"),
        table("silver.entregas_fornecedor", [
            {"column_name": "fornecedor", "synonyms": ["consultoria", "parceiro"], "enable_entity_matching": True},
        ]),
    ]
    rules = list(BASE_RULES)
    examples = list(EXAMPLES)
    if score_exists:
        tables.append(table("gold.score_estouro_30d"))
        rules.append(
            "O score está disponível em gold.score_estouro_30d. Use a data_referencia mais recente por projeto, junto de gold.projeto_situacao_atual. "
            "Faixas: alto >= 0,5, medio >= 0,2, baixo abaixo de 0,2. Em 'próximo mês', acrescente projetos hoje com situacao = 'ok' "
            "e faixa alto ou medio, citando prob_estouro_30d e principais_fatores."
        )
        examples[-1] = example(QUESTIONS[3], """
WITH entregas AS (
  SELECT 'consultoria em atraso' AS risco, e.fornecedor AS entidade,
         CONCAT('Entrega ', CAST(e.data_prometida AS STRING), ', atraso de ',
                CAST(e.dias_de_atraso_na_entrega AS STRING), ' dias') AS evidencia,
         'Cobrar plano de recuperação do fornecedor' AS acao
  FROM lakehouse_vertice.silver.entregas_fornecedor AS e
  WHERE e.em_atraso AND e.data_prometida <= DATE'2026-11-15'
), freeze AS (
  SELECT 'change freeze de varejo' AS risco, p.projeto AS entidade,
         CONCAT(p.cliente, ', término projetado ', CAST(p.termino_projetado AS STRING)) AS evidencia,
         'Antecipar homologação e deploy antes de 01/11/2026' AS acao
  FROM lakehouse_vertice.gold.projeto_situacao_atual AS p
  WHERE p.status = 'em_andamento'
    AND LOWER(p.segmento) LIKE '%varejo%'
    AND LOWER(p.tipo_projeto) LIKE '%commerce%'
    AND p.termino_projetado BETWEEN DATE'2026-11-01' AND DATE'2027-01-10'
), score_recente AS (
  SELECT s.projeto_id, s.prob_estouro_30d, s.faixa_risco, s.principais_fatores,
         ROW_NUMBER() OVER (PARTITION BY s.projeto_id ORDER BY s.data_referencia DESC, s.ranking ASC) AS ordem
  FROM lakehouse_vertice.gold.score_estouro_30d AS s
  WHERE s.data_referencia <= DATE'2026-10-16'
), riscos_ocultos AS (
  SELECT 'risco oculto do modelo' AS risco, p.projeto AS entidade,
         CONCAT('Probabilidade ', CAST(ROUND(s.prob_estouro_30d * 100, 1) AS STRING),
                '%, fatores: ', s.principais_fatores) AS evidencia,
         'Revisar plano e farol com o gerente' AS acao
  FROM score_recente AS s
  JOIN lakehouse_vertice.gold.projeto_situacao_atual AS p ON p.projeto = s.projeto_id
  WHERE s.ordem = 1 AND p.status = 'em_andamento' AND p.situacao = 'ok'
    AND s.faixa_risco IN ('alto', 'medio')
)
SELECT * FROM entregas UNION ALL SELECT * FROM freeze UNION ALL SELECT * FROM riscos_ocultos
ORDER BY risco, entidade
""")
        examples.append(example("Qual a chance de o PRJ-024 estourar?", """
WITH score_atual AS (
  SELECT s.projeto_id, s.prob_estouro_30d, s.faixa_risco, s.principais_fatores,
         ROW_NUMBER() OVER (PARTITION BY s.projeto_id ORDER BY s.data_referencia DESC, s.ranking ASC) AS ordem
  FROM lakehouse_vertice.gold.score_estouro_30d AS s
  WHERE s.projeto_id = 'PRJ-024' AND s.data_referencia <= DATE'2026-10-16'
)
SELECT p.projeto, p.nome, p.situacao, p.spi, s.prob_estouro_30d,
       s.faixa_risco, s.principais_fatores
FROM lakehouse_vertice.gold.projeto_situacao_atual AS p
JOIN score_atual AS s ON s.projeto_id = p.projeto AND s.ordem = 1
WHERE p.projeto = 'PRJ-024'
"""))
    return {
        "version": 2,
        "config": {"sample_questions": sorted_ids([
            item("sample", question, question=[question]) for question in QUESTIONS
        ])},
        "data_sources": {
            "tables": sorted(tables, key=lambda entry: str(entry["identifier"])),
            "metric_views": [table("gold.mv_projetos")],
        },
        "instructions": {
            "text_instructions": [item("instruction", "rules", content=rules)],
            "example_question_sqls": sorted_ids(examples),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--score-exists", action="store_true", help="usar somente após tables exists = true")
    args = parser.parse_args()
    payload = build(args.score_exists)
    OUTPUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{OUTPUT.relative_to(ROOT)}: {len(payload['data_sources']['tables'])} tabelas, "
          f"1 metric view, {len(payload['instructions']['example_question_sqls'])} exemplos, "
          f"score={'sim' if args.score_exists else 'não'}")


if __name__ == "__main__":
    main()
