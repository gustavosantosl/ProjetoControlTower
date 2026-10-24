export type PessoaOciosa = {
  colaborador_id: string;
  nome: string;
  papel: string;
  projeto_origem: string;
  horas_ociosas_media_semana: number | string;
  custo_ocioso_medio_semana: number | string;
  custo_hora: number | string;
};

export type ProjetoDestino = {
  projeto: string;
  nome: string;
  situacao: string;
  dias_falta_sre: number | string;
  dias_rotatividade: number | string;
};

export function calcularSimulacao(
  pessoa: PessoaOciosa,
  projeto: ProjetoDestino,
  horasOnboarding: number,
) {
  const horasMes = Number(pessoa.horas_ociosas_media_semana) * 4;
  const ociosidadeEvitada = Number(pessoa.custo_ocioso_medio_semana) * 4;
  const diasImpacto = Number(
    pessoa.papel.toLowerCase().includes("sre")
      ? projeto.dias_falta_sre
      : projeto.dias_rotatividade,
  );
  const diasRecuperados = (diasImpacto / 90) * 30;
  const mobilizacao = Math.max(0, horasOnboarding) * Number(pessoa.custo_hora);

  return {
    horasMes,
    ociosidadeEvitada,
    diasRecuperados,
    mobilizacao,
    saldo: ociosidadeEvitada - mobilizacao,
  };
}

export const reais = (valor: number | string) =>
  new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(valor));

export const indice = (valor: number | string) => Number(valor).toFixed(2).replace(".", ",");
