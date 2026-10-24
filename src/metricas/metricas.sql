CREATE OR REPLACE VIEW lakehouse_vertice.gold.mv_projetos WITH METRICS
LANGUAGE YAML AS $$
version: 1.1
source: lakehouse_vertice.gold.projeto_situacao_atual
comment: Indicadores governados da carteira em andamento na fotografia de 16/10/2026
filter: status = 'em_andamento'
dimensions:
  - name: projeto_id
    expr: projeto
    comment: Identificador único do projeto no cadastro do PMO
    synonyms: [codigo do projeto, id do projeto]
  - name: projeto
    expr: projeto
    comment: Código PRJ do projeto
    synonyms: [obra, iniciativa]
  - name: cliente
    expr: cliente
    synonyms: [empresa, conta]
  - name: segmento
    expr: segmento
    synonyms: [setor, mercado]
  - name: ferramenta
    expr: ferramenta
    comment: Plataforma usada no projeto
    synonyms: [tecnologia, sistema]
  - name: situacao
    expr: situacao
    comment: Classificação calculada a partir de SPI e CPI
    synonyms: [risco, estado do projeto]
  - name: farol_do_gerente
    expr: farol_do_gerente
    comment: Semáforo informado pelo gerente no último status
    synonyms: [farol informado, semaforo do gerente]
  - name: farol_calculado
    expr: farol_calculado
    comment: Semáforo derivado do SPI na fotografia de hoje
    synonyms: [farol real, semaforo calculado]
  - name: gerente_projeto
    expr: gerente_projeto
    synonyms: [gerente, responsavel]
measures:
  - name: projetos
    expr: COUNT(1)
    comment: Número de projetos em andamento
    synonyms: [quantidade de projetos, total de projetos]
  - name: carteira
    expr: SUM(valor_contrato)
    comment: Soma do valor contratado dos projetos em andamento em reais
    synonyms: [valor da carteira, contratos]
  - name: spi
    expr: SUM(ev) / NULLIF(SUM(pv), 0)
    comment: Índice de prazo da carteira, valor agregado dividido pelo planejado
    synonyms: [indice de prazo, desempenho de prazo]
  - name: cpi
    expr: SUM(ev) / NULLIF(SUM(ac), 0)
    comment: Índice de custo da carteira, valor agregado dividido pelo custo real
    synonyms: [indice de custo, desempenho de custo]
  - name: eac
    expr: SUM(eac)
    comment: Estimativa de custo total ao concluir os projetos em reais
    synonyms: [custo ao concluir, estimativa ao concluir]
  - name: estouro_previsto
    expr: SUM(estouro_previsto)
    comment: Soma do custo previsto acima do orçamento em reais
    synonyms: [estouro, sobrecusto previsto]
  - name: margem_projetada
    expr: (SUM(valor_contrato) - SUM(eac)) / NULLIF(SUM(valor_contrato), 0)
    comment: Margem da carteira calculada pela razão entre lucro projetado e contratos
    synonyms: [margem, margem prevista]
  - name: atraso_projetado_medio_dias
    expr: AVG(atraso_projetado_dias)
    comment: Média de dias de atraso projetado por projeto
    synonyms: [atraso medio, dias de atraso]
  - name: projetos_em_risco
    expr: COUNT(1) FILTER (WHERE situacao IN ('atenção', 'crítico'))
    comment: Projetos em atenção ou situação crítica
    synonyms: [projetos arriscados, em risco]
  - name: projetos_criticos
    expr: COUNT(1) FILTER (WHERE situacao = 'crítico')
    synonyms: [criticos, projetos vermelhos]
  - name: projetos_melancia
    expr: COUNT(1) FILTER (WHERE melancia)
    comment: Farol verde informado com SPI abaixo de 0,9
    synonyms: [melancias, farol verde enganoso]
$$
