import { describe, expect, it } from "vitest";
import { obterScore } from "./score-estouro";

describe("score opcional", () => {
  it("devolve indisponível quando o modelo ainda não criou a tabela", async () => {
    const resultado = await obterScore(() => Promise.reject(new Error("[TABLE_OR_VIEW_NOT_FOUND] gold.score_estouro_30d")));
    expect(resultado).toEqual({ disponivel: false, linhas: [] });
  });

  it("converte a probabilidade numérica retornada como texto", async () => {
    const resultado = await obterScore(() => Promise.resolve([
      { projeto_id: "PRJ-011", prob_estouro_30d: "0.64", faixa_risco: "alto" },
    ]));
    expect(resultado).toEqual({
      disponivel: true,
      linhas: [{ projeto_id: "PRJ-011", prob_estouro_30d: 0.64, faixa_risco: "alto" }],
    });
  });

  it("preserva falhas diferentes de tabela ausente", async () => {
    await expect(obterScore(() => Promise.reject(new Error("PERMISSION_DENIED")))).rejects.toThrow("PERMISSION_DENIED");
  });
});
