export const SCORE_SQL = `
SELECT projeto_id, prob_estouro_30d, faixa_risco
FROM lakehouse_vertice.gold.score_estouro_30d
WHERE data_referencia <= DATE'2026-10-16'
QUALIFY row_number() OVER (
  PARTITION BY projeto_id ORDER BY data_referencia DESC, ranking ASC
) = 1`;

export type LinhaScore = {
  projeto_id: string;
  prob_estouro_30d: number;
  faixa_risco: string;
};

export type RespostaScore =
  | { disponivel: true; linhas: LinhaScore[] }
  | { disponivel: false; linhas: [] };

export function tabelaScoreAusente(erro: unknown): boolean {
  const texto = (erro instanceof Error ? erro.message : JSON.stringify(erro)).toUpperCase();
  return texto.includes("TABLE_OR_VIEW_NOT_FOUND") ||
    texto.includes("RESOURCE_DOES_NOT_EXIST") ||
    texto.includes("TABLE DOES NOT EXIST");
}

export async function obterScore(
  executar: (sql: string) => Promise<Array<{
    projeto_id: string;
    prob_estouro_30d: number | string;
    faixa_risco: string;
  }>>,
): Promise<RespostaScore> {
  try {
    const linhas = await executar(SCORE_SQL);
    return {
      disponivel: true,
      linhas: linhas.map((linha) => ({
        projeto_id: linha.projeto_id,
        prob_estouro_30d: Number(linha.prob_estouro_30d),
        faixa_risco: linha.faixa_risco,
      })),
    };
  } catch (erro) {
    if (tabelaScoreAusente(erro)) return { disponivel: false, linhas: [] };
    throw erro;
  }
}
