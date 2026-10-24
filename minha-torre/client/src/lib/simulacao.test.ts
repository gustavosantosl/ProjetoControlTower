import { expect, it } from "vitest";
import { calcularSimulacao } from "./simulacao";

it("reproduz o caso COL0017 → PRJ-011 da aula", () => {
  const resultado = calcularSimulacao(
    {
      colaborador_id: "COL0017", nome: "SRE", papel: "SRE", projeto_origem: "PRJ-007",
      horas_ociosas_media_semana: "37.75", custo_ocioso_medio_semana: "7525", custo_hora: "200",
    },
    { projeto: "PRJ-011", nome: "Projeto", situacao: "crítico", dias_falta_sre: "57", dias_rotatividade: "0" },
    40,
  );

  expect(resultado).toEqual({
    horasMes: 151,
    ociosidadeEvitada: 30100,
    diasRecuperados: 19,
    mobilizacao: 8000,
    saldo: 22100,
  });
});
