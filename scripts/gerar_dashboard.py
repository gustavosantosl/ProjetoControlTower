#!/usr/bin/env python3
"""Gera o dashboard AI/BI e as consultas de conferência, sem acessar a rede."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "resources" / "dashboard-portfolio.lvdash.json"
PREFLIGHT = ROOT / "scripts" / "dashboard_preflight.sql"
GOLD_TABLES = (
    "projeto_situacao_atual",
    "fato_projeto_semana",
    "utilizacao_pessoa_semana",
    "status_estruturado",
)

SQL = {
    "carteira_kpis": """SELECT
  count(*) AS projetos_em_andamento,
  sum(valor_contrato) AS carteira,
  try_divide(sum(ev), sum(pv)) AS spi,
  try_divide(sum(ev), sum(ac)) AS cpi,
  sum(estouro_previsto) AS estouro_previsto,
  count_if(situacao IN ('atenção', 'crítico')) AS projetos_em_risco,
  count_if(situacao = 'crítico') AS projetos_criticos,
  count_if(melancia) AS melancias
FROM projeto_situacao_atual
WHERE status = 'em_andamento'""",
    "projetos": """SELECT projeto, nome, cliente, segmento, valor_contrato, spi, cpi,
       estouro_previsto, situacao, farol_do_gerente, farol_calculado, melancia
FROM projeto_situacao_atual
WHERE status = 'em_andamento'
ORDER BY estouro_previsto DESC, projeto""",
    "estouros": """SELECT projeto, nome, situacao, estouro_previsto
FROM projeto_situacao_atual
WHERE status = 'em_andamento' AND estouro_previsto > 0
ORDER BY estouro_previsto DESC, projeto""",
    "evolucao_semanal": """SELECT semana,
       try_divide(sum(ev), sum(pv)) AS spi,
       try_divide(sum(ev), sum(ac)) AS cpi
FROM fato_projeto_semana
WHERE semana BETWEEN DATE'2025-03-07' AND DATE'2026-10-16'
GROUP BY semana
ORDER BY semana""",
    "pessoas_custo_ocioso": """SELECT colaborador_id, nome, papel,
       sum(custo_ocioso) AS custo_ocioso,
       sum(horas_ociosas) AS horas_ociosas
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24' AND semana <= DATE'2026-10-16'
GROUP BY colaborador_id, nome, papel
ORDER BY custo_ocioso DESC, colaborador_id
LIMIT 15""",
    "pessoas_utilizacao": """SELECT colaborador_id, nome, papel, projeto_id,
       sum(horas_disponiveis) AS horas_disponiveis,
       sum(horas_apontadas) AS horas_apontadas,
       sum(horas_ociosas) AS horas_ociosas,
       try_divide(sum(horas_apontadas), sum(horas_disponiveis)) AS utilizacao,
       sum(custo_ocioso) AS custo_ocioso
FROM utilizacao_pessoa_semana
WHERE semana > DATE'2026-07-24' AND semana <= DATE'2026-10-16'
GROUP BY colaborador_id, nome, papel, projeto_id
ORDER BY utilizacao ASC, custo_ocioso DESC, colaborador_id, projeto_id""",
    "causas_por_projeto": """WITH bloqueios AS (
  SELECT projeto_id, causa_bloqueio, count(*) AS ocorrencias
  FROM status_estruturado
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
ORDER BY b.projeto_id, b.causa_bloqueio""",
    "fornecedores": """SELECT fornecedor,
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
ORDER BY em_atraso_hoje DESC, entregas DESC, fornecedor""",
    "entregas_em_atraso": """SELECT fornecedor, fornecedor_como_veio, data_pedido, data_prometida,
       data_entrega, prazo_prometido_dias, dias_de_atraso_na_entrega, em_aberto
FROM lakehouse_vertice.silver.entregas_fornecedor
WHERE em_atraso = true
ORDER BY dias_de_atraso_na_entrega DESC, data_prometida, fornecedor""",
}

COLUMNS = {
    "carteira_kpis": "projetos_em_andamento carteira spi cpi estouro_previsto projetos_em_risco projetos_criticos melancias",
    "projetos": "projeto nome cliente segmento valor_contrato spi cpi estouro_previsto situacao farol_do_gerente farol_calculado melancia",
    "estouros": "projeto nome situacao estouro_previsto",
    "evolucao_semanal": "semana spi cpi",
    "pessoas_custo_ocioso": "colaborador_id nome papel custo_ocioso horas_ociosas",
    "pessoas_utilizacao": "colaborador_id nome papel projeto_id horas_disponiveis horas_apontadas horas_ociosas utilizacao custo_ocioso",
    "causas_por_projeto": "projeto_id causa_bloqueio ocorrencias",
    "fornecedores": "fornecedor grafias_no_cadastro entregas prazo_real_sobre_prometido percentual_no_prazo em_atraso_hoje",
    "entregas_em_atraso": "fornecedor fornecedor_como_veio data_pedido data_prometida data_entrega prazo_prometido_dias dias_de_atraso_na_entrega em_aberto",
}

BRL = {"type": "number-currency", "currencyCode": "BRL", "abbreviation": "compact", "decimalPlaces": {"type": "max", "places": 2}}
PERCENT = {"type": "number-percent", "decimalPlaces": {"type": "max", "places": 1}}
DECIMAL = {"type": "number", "decimalPlaces": {"type": "max", "places": 2}}


def dataset(name: str) -> dict:
    return {
        "name": name,
        "displayName": name.replace("_", " ").title(),
        "queryLines": [line + "\n" for line in SQL[name].splitlines()],
    }


def field(name: str) -> dict:
    return {"name": name, "expression": f"`{name}`"}


def entry(widget: dict, x: int, y: int, width: int, height: int) -> dict:
    return {"widget": widget, "position": {"x": x, "y": y, "width": width, "height": height}}


def header(name: str, question: str, subtitle: str) -> dict:
    return {
        "name": name,
        "multilineTextboxSpec": {"lines": [f"## {question}\n", "\n", subtitle]},
    }


def widget(name: str, title: str, source: str, columns: list[str], kind: str, encodings: dict) -> dict:
    unknown = set(columns) - set(COLUMNS[source].split())
    if unknown:
        raise ValueError(f"{name}: colunas inexistentes em {source}: {sorted(unknown)}")
    return {
        "name": name,
        "queries": [{
            "name": "main_query",
            "query": {"datasetName": source, "fields": [field(c) for c in columns], "disaggregated": True},
        }],
        "spec": {
            "version": 2 if kind in {"counter", "table"} else 3,
            "widgetType": kind,
            "encodings": encodings,
            "frame": {"showTitle": True, "title": title},
        },
    }


def counter(name: str, title: str, column: str, x: int, y: int, fmt: dict | None = None,
            width: int = 4) -> dict:
    value = {"fieldName": column, "displayName": title}
    if fmt:
        value["format"] = fmt
    return entry(widget(name, title, "carteira_kpis", [column], "counter", {"value": value}), x, y, width, 3)


def table(name: str, title: str, source: str, columns: list[tuple[str, str, dict | None]], y: int, height: int) -> dict:
    rendered = []
    for column, display, fmt in columns:
        item = {"fieldName": column, "displayName": display}
        if fmt:
            item["format"] = fmt
        rendered.append(item)
    return entry(widget(name, title, source, [c[0] for c in columns], "table", {"columns": rendered}), 0, y, 12, height)


def bar(name: str, title: str, source: str, value: str, category: str, x: int, y: int,
        width: int, height: int, color: str | None = None, color_map: list[dict] | None = None,
        fmt: dict | None = None) -> dict:
    value_encoding = {"fieldName": value, "scale": {"type": "quantitative"}}
    if fmt:
        value_encoding["format"] = fmt
    encodings = {
        "x": {"scale": {"type": "quantitative"}, "fields": [value_encoding]},
        "y": {"fieldName": category, "scale": {"type": "categorical"}},
    }
    columns = [value, category]
    if color:
        columns.append(color)
        encodings["color"] = {"fieldName": color, "scale": {"type": "categorical"}}
        if color_map:
            encodings["color"]["scale"]["mappings"] = color_map
    return entry(widget(name, title, source, columns, "bar", encodings), x, y, width, height)


def page(name: str, title: str, layout: list[dict]) -> dict:
    return {"name": name, "displayName": title, "pageType": "PAGE_TYPE_CANVAS", "layoutVersion": "GRID_V1", "layout": layout}


def dashboard() -> dict:
    portfolio = [
        entry(header("pergunta_portfolio", "Quais projetos estão atrasados e quanto isso vai custar?", "Carteira em andamento · fotografia de 16/10/2026"), 0, 0, 12, 2),
        counter("kpi_carteira", "Carteira", "carteira", 0, 2, BRL),
        counter("kpi_spi", "SPI", "spi", 4, 2, DECIMAL),
        counter("kpi_cpi", "CPI", "cpi", 8, 2, DECIMAL),
        counter("kpi_estouro", "Estouro previsto", "estouro_previsto", 0, 5, BRL),
        counter("kpi_risco", "Projetos em risco", "projetos_em_risco", 4, 5),
        counter("kpi_criticos", "Críticos", "projetos_criticos", 8, 5),
        counter("kpi_melancias", "Melancias", "melancias", 0, 8, width=6),
        counter("kpi_andamento", "Em andamento", "projetos_em_andamento", 6, 8, width=6),
        bar("estouro_por_projeto", "Estouro previsto por projeto", "estouros", "estouro_previsto", "projeto", 0, 11, 6, 7,
            "situacao", [{"value": "crítico", "color": "#FF5F46"}, {"value": "atenção", "color": "#F6C344"}, {"value": "ok", "color": "#22C2F4"}], BRL),
        entry(widget("spi_cpi_projetos", "SPI × CPI por projeto", "projetos", ["spi", "cpi", "situacao", "projeto"], "scatter", {
            "x": {"fieldName": "spi", "scale": {"type": "quantitative"}},
            "y": {"fieldName": "cpi", "scale": {"type": "quantitative"}},
            "color": {"fieldName": "situacao", "scale": {"type": "categorical", "mappings": [
                {"value": "crítico", "color": "#FF5F46"}, {"value": "atenção", "color": "#F6C344"}, {"value": "ok", "color": "#22C2F4"},
            ]}},
            "extra": [{"fieldName": "projeto", "displayName": "Projeto"}],
        }), 6, 11, 6, 7),
        entry(widget("spi_cpi_semanais", "SPI e CPI semanais da carteira", "evolucao_semanal", ["semana", "spi", "cpi"], "line", {
            "x": {"fieldName": "semana", "scale": {"type": "temporal"}},
            "y": {"scale": {"type": "quantitative"}, "fields": [
                {"fieldName": "spi", "displayName": "SPI"}, {"fieldName": "cpi", "displayName": "CPI"},
            ]},
        }), 0, 18, 12, 6),
        table("projetos_em_andamento", "Projetos em andamento", "projetos", [
            ("projeto", "Projeto", None), ("nome", "Nome", None), ("cliente", "Cliente", None),
            ("situacao", "Situação", None), ("spi", "SPI", DECIMAL), ("cpi", "CPI", DECIMAL),
            ("farol_do_gerente", "Farol do gerente", None), ("farol_calculado", "Farol calculado", None),
            ("melancia", "Melancia", None), ("estouro_previsto", "Estouro previsto", BRL),
        ], 24, 8),
    ]

    pessoas = [
        entry(header("pergunta_pessoas", "Tenho gente parada enquanto outro projeto precisa de ajuda?", "Utilização e custo da hora parada · últimas 12 semanas até 16/10/2026"), 0, 0, 12, 2),
        bar("top_custo_ocioso", "Top 15 por custo da hora parada", "pessoas_custo_ocioso", "custo_ocioso", "nome", 0, 2, 6, 7, fmt=BRL),
        bar("causas_por_projeto", "Causas de bloqueio por projeto", "causas_por_projeto", "ocorrencias", "projeto_id", 6, 2, 6, 7, color="causa_bloqueio"),
        table("utilizacao_pessoa_projeto", "Utilização por pessoa e projeto", "pessoas_utilizacao", [
            ("colaborador_id", "Colaborador", None), ("nome", "Nome", None), ("papel", "Papel", None),
            ("projeto_id", "Projeto", None), ("horas_disponiveis", "Horas disponíveis", DECIMAL),
            ("horas_apontadas", "Horas apontadas", DECIMAL), ("utilizacao", "Utilização", PERCENT),
            ("custo_ocioso", "Custo ocioso", BRL),
        ], 9, 8),
    ]

    fornecedores = [
        entry(header("pergunta_fornecedores", "Quais fornecedores ameaçam as próximas entregas?", "Prazos prometidos e realizados · referência de 16/10/2026"), 0, 0, 12, 2),
        table("resumo_fornecedores", "Desempenho por fornecedor", "fornecedores", [
            ("fornecedor", "Fornecedor", None), ("grafias_no_cadastro", "Grafias no cadastro", None),
            ("entregas", "Entregas", None), ("prazo_real_sobre_prometido", "Prazo real ÷ prometido", DECIMAL),
            ("percentual_no_prazo", "% no prazo", PERCENT), ("em_atraso_hoje", "Em atraso hoje", None),
        ], 2, 7),
        table("entregas_atrasadas", "Entregas em atraso hoje", "entregas_em_atraso", [
            ("fornecedor", "Fornecedor", None), ("fornecedor_como_veio", "Grafia original", None),
            ("data_pedido", "Pedido", None), ("data_prometida", "Prometida", None),
            ("data_entrega", "Entregue", None), ("dias_de_atraso_na_entrega", "Dias em atraso", None),
            ("em_aberto", "Em aberto", None),
        ], 9, 7),
    ]

    return {
        "datasets": [dataset(name) for name in SQL],
        "pages": [page("portfolio", "Portfólio", portfolio), page("pessoas", "Pessoas", pessoas), page("fornecedores", "Fornecedores", fornecedores)],
        "uiSettings": {"theme": {
            "canvasBackgroundColor": {"light": "#F7F9FC", "dark": "#14141A"},
            "widgetBackgroundColor": {"light": "#FFFFFF", "dark": "#1E1E26"},
            "fontColor": {"light": "#14141A", "dark": "#F4F7FC"},
            "selectionColor": {"light": "#0059DB", "dark": "#22C2F4"},
            "visualizationColors": ["#0059DB", "#22C2F4", "#F6C344", "#FF5F46", "#22A878", "#8B71D8", "#E27DA5", "#66788A"],
            "widgetHeaderAlignment": "LEFT",
        }},
    }


def qualified(sql: str) -> str:
    tables = "|".join(GOLD_TABLES)
    return re.sub(rf"\b(FROM|JOIN)\s+({tables})\b", r"\1 lakehouse_vertice.gold.\2", sql, flags=re.IGNORECASE)


def preflight() -> str:
    parts = ["-- Consultas idênticas às do dashboard, com prefixo Gold apenas nesta conferência."]
    for name, sql in SQL.items():
        parts.append(f"SELECT '{name}' AS dataset, count(*) AS linhas FROM (\n{qualified(sql)}\n) AS dados;")
    parts.append(f"-- Valores dos KPIs da carteira\n{qualified(SQL['carteira_kpis'])};")
    parts.append(f"-- CodeForge: prazo, pontualidade e atraso\nSELECT * FROM (\n{qualified(SQL['fornecedores'])}\n) AS dados WHERE fornecedor = 'CodeForge Consultoria Ltda';")
    return "\n\n".join(parts) + "\n"


def validate(result: dict) -> None:
    dataset_names = {item["name"] for item in result["datasets"]}
    if len(dataset_names) != len(SQL) or len(result["pages"]) != 3:
        raise ValueError("Datasets ou páginas incompletos")
    for page_item in result["pages"]:
        if page_item["layoutVersion"] != "GRID_V1":
            raise ValueError(f"Layout inválido: {page_item['name']}")
        occupied = set()
        for layout_item in page_item["layout"]:
            position = layout_item["position"]
            if not 0 <= position["x"] < 12 or position["x"] + position["width"] > 12:
                raise ValueError(f"Widget fora do grid: {layout_item['widget']['name']}")
            cells = {
                (x, y)
                for x in range(position["x"], position["x"] + position["width"])
                for y in range(position["y"], position["y"] + position["height"])
            }
            if occupied & cells:
                raise ValueError(f"Widgets sobrepostos na página {page_item['name']}")
            occupied |= cells
            widget_item = layout_item["widget"]
            if "spec" not in widget_item:
                continue
            query = widget_item["queries"][0]["query"]
            if query["datasetName"] not in dataset_names:
                raise ValueError(f"Dataset desconhecido: {query['datasetName']}")
            selected = {item["name"] for item in query["fields"]}
            bindings = set(re.findall(r'"fieldName": "([^"]+)"', json.dumps(widget_item["spec"]["encodings"])))
            if not bindings <= selected:
                raise ValueError(f"Bindings sem campo em {widget_item['name']}: {bindings - selected}")


def main() -> None:
    result = dashboard()
    validate(result)
    DASHBOARD.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    PREFLIGHT.write_text(preflight(), encoding="utf-8")
    print(f"Dashboard: {DASHBOARD} ({len(result['pages'])} páginas, {len(result['datasets'])} datasets)")
    print(f"Conferência SQL: {PREFLIGHT} ({len(SQL)} contagens + KPIs + CodeForge)")


if __name__ == "__main__":
    main()
