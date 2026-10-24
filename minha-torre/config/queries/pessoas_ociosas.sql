SELECT u.colaborador_id, max(u.nome) AS nome, max(u.papel) AS papel,
       max_by(u.projeto_id, u.semana) AS projeto_origem,
       count(DISTINCT u.semana) AS semanas_observadas,
       try_divide(sum(u.horas_apontadas), sum(u.horas_disponiveis)) AS utilizacao,
       try_divide(sum(u.horas_ociosas), count(DISTINCT u.semana)) AS horas_ociosas_media_semana,
       try_divide(sum(u.custo_ocioso), count(DISTINCT u.semana)) AS custo_ocioso_medio_semana,
       max(c.custo_hora) AS custo_hora
FROM lakehouse_vertice.gold.utilizacao_pessoa_semana u
JOIN lakehouse_vertice.silver.colaboradores c USING (colaborador_id)
WHERE u.semana > DATE'2026-07-24' AND u.semana <= DATE'2026-10-16'
GROUP BY u.colaborador_id
HAVING try_divide(sum(u.horas_apontadas), sum(u.horas_disponiveis)) < 0.2
ORDER BY custo_ocioso_medio_semana DESC, u.colaborador_id
