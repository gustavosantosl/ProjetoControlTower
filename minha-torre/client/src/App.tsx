import { useEffect, useMemo, useState } from "react";
import { Badge, Card, CardContent, CardHeader, CardTitle, GenieChat, Skeleton, useAnalyticsQuery } from "@databricks/appkit-ui/react";
import { z } from "zod";
import { calcularSimulacao, indice, reais } from "./lib/simulacao";
import type { PessoaOciosa } from "./lib/simulacao";
import "./App.css";

const kpiSchema = z.object({
  projetos_em_andamento: z.coerce.number(),
  projetos_em_risco: z.coerce.number(),
  projetos_criticos: z.coerce.number(),
  melancias: z.coerce.number(),
  estouro_previsto: z.coerce.number(),
  carteira: z.coerce.number(),
});

const projetoSchema = z.object({
  projeto: z.string(), nome: z.string(), cliente: z.string(), situacao: z.string(),
  spi: z.coerce.number().nullable(), cpi: z.coerce.number().nullable(),
  estouro_previsto: z.coerce.number(), atraso_projetado_dias: z.coerce.number().nullable(),
  farol_do_gerente: z.string().nullable(), farol_calculado: z.string().nullable(),
  melancia: z.union([z.boolean(), z.string()]), causa_mais_frequente: z.string().nullable(),
  dias_falta_sre: z.coerce.number(), dias_rotatividade: z.coerce.number(),
});

const pessoaSchema = z.object({
  colaborador_id: z.string(), nome: z.string(), papel: z.string(), projeto_origem: z.string(),
  horas_ociosas_media_semana: z.coerce.number(),
  custo_ocioso_medio_semana: z.coerce.number(), custo_hora: z.coerce.number(),
});

type Kpis = z.infer<typeof kpiSchema>;
type Projeto = z.infer<typeof projetoSchema>;

type Score = {
  disponivel: boolean;
  linhas: Array<{ projeto_id: string; prob_estouro_30d: number | string; faixa_risco: string }>;
};

const ehMelancia = (valor: boolean | string) => String(valor).toLowerCase() === "true";
const percentual = (valor: number | string | null) =>
  valor == null ? "—" : `${indice(Number(valor) * 100)}%`;

function CartaoKpi({ titulo, valor, detalhe }: { titulo: string; valor: string; detalhe: string }) {
  return (
    <Card>
      <CardHeader><CardTitle>{titulo}</CardTitle></CardHeader>
      <CardContent>
        <strong className="kpi-valor">{valor}</strong>
        <p className="metadado">{detalhe}</p>
      </CardContent>
    </Card>
  );
}

function EstadoDados({ loading, error, vazio }: { loading: boolean; error: unknown; vazio: boolean }) {
  if (loading) return <Skeleton className="h-24 w-full" />;
  if (error) return <p role="alert" className="erro">Falha ao consultar o warehouse: {error instanceof Error ? error.message : "Erro desconhecido"}</p>;
  if (vazio) return <p className="vazio">Nenhum dado encontrado para a fotografia de 16/10/2026.</p>;
  return null;
}

function useScore() {
  const [score, setScore] = useState<Score | null>(null);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/score-estouro", { signal: controller.signal })
      .then(async (resposta) => {
        if (!resposta.ok) throw new Error(`HTTP ${resposta.status}`);
        return resposta.json() as Promise<Score>;
      })
      .then(setScore)
      .catch((falha: unknown) => {
        if (!controller.signal.aborted) setErro(falha instanceof Error ? falha.message : "Erro desconhecido");
      });
    return () => controller.abort();
  }, []);

  return { score, erro };
}

function ProjetosEmRisco({ kpis, projetos, score, scoreErro }: {
  kpis: Kpis | undefined;
  projetos: Projeto[];
  score: Score | null;
  scoreErro: string | null;
}) {
  const probabilidades = useMemo(
    () => new Map(score?.linhas.map((linha) => [linha.projeto_id, Number(linha.prob_estouro_30d)]) ?? []),
    [score],
  );
  const altoRisco = score?.disponivel
    ? score.linhas.filter((linha) => linha.faixa_risco === "alto").length.toString()
    : "—";

  return (
    <section aria-labelledby="titulo-risco">
      <h2 id="titulo-risco">Quais projetos exigem atenção agora?</h2>
      <p className="metadado">Projetos em andamento · fotografia de 16/10/2026 · fonte: gold</p>
      <div className="kpis">
        <CartaoKpi titulo="Em risco" valor={kpis ? String(Number(kpis.projetos_em_risco)) : "—"} detalhe="Atenção + crítico" />
        <CartaoKpi titulo="Estouro previsto" valor={kpis ? reais(kpis.estouro_previsto) : "—"} detalhe="Carteira em andamento" />
        <CartaoKpi titulo="Carteira" valor={kpis ? reais(kpis.carteira) : "—"} detalhe="Valor dos contratos" />
        <CartaoKpi titulo="Alto risco em 30 dias" valor={altoRisco} detalhe={score?.disponivel ? "Modelo · faixa alto" : "Score indisponível"} />
      </div>
      {scoreErro && <p className="metadado">Score temporariamente indisponível: {scoreErro}</p>}
      <Card>
        <CardHeader><CardTitle>Projetos em andamento, do pior para o melhor</CardTitle></CardHeader>
        <CardContent>
          <div className="tabela-rolagem">
            <table>
              <thead><tr>
                <th>Projeto</th><th>Cliente</th><th>Situação</th><th>SPI</th><th>CPI</th>
                <th>Estouro</th><th>Atraso</th><th>Farol gerente / cálculo</th><th>Causa</th><th>P(estouro)</th>
              </tr></thead>
              <tbody>{projetos.map((projeto) => (
                <tr key={projeto.projeto}>
                  <td><strong>{projeto.projeto}</strong><small>{projeto.nome}</small></td>
                  <td>{projeto.cliente}</td>
                  <td><span className={`situacao situacao-${projeto.situacao === "crítico" ? "critico" : projeto.situacao === "atenção" ? "atencao" : "ok"}`}>{projeto.situacao}</span></td>
                  <td>{projeto.spi == null ? "—" : indice(projeto.spi)}</td>
                  <td>{projeto.cpi == null ? "—" : indice(projeto.cpi)}</td>
                  <td>{reais(projeto.estouro_previsto)}</td>
                  <td>{projeto.atraso_projetado_dias == null ? "—" : `${Number(projeto.atraso_projetado_dias)} dias`}</td>
                  <td>{projeto.farol_do_gerente ?? "—"}{ehMelancia(projeto.melancia) ? " 🍉" : ""} / {projeto.farol_calculado ?? "—"}</td>
                  <td>{projeto.causa_mais_frequente?.replaceAll("_", " ") ?? "—"}</td>
                  <td>{score?.disponivel ? percentual(probabilidades.get(projeto.projeto) ?? null) : "—"}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </section>
  );
}

function Simulador({ pessoas, projetos }: { pessoas: PessoaOciosa[]; projetos: Projeto[] }) {
  const [pessoaId, setPessoaId] = useState("");
  const [projetoId, setProjetoId] = useState("");
  const [horasOnboarding, setHorasOnboarding] = useState(40);
  const pessoa = pessoas.find((item) => item.colaborador_id === pessoaId) ?? pessoas[0];
  const destinos = useMemo(() => {
    const candidatos = projetos.filter((item) => item.situacao === "atenção" || item.situacao === "crítico");
    if (pessoa?.papel.toLowerCase().includes("sre")) {
      return [...candidatos].sort((a, b) => Number(b.dias_falta_sre) - Number(a.dias_falta_sre));
    }
    return candidatos;
  }, [pessoa, projetos]);
  const projeto = destinos.find((item) => item.projeto === projetoId) ?? destinos[0];
  const resultado = pessoa && projeto ? calcularSimulacao(pessoa, projeto, horasOnboarding) : null;

  return (
    <section aria-labelledby="titulo-simulador">
      <h2 id="titulo-simulador">E se realocarmos alguém com horas disponíveis?</h2>
      <p className="metadado">Simulação de um mês com base nas últimas 12 semanas · não altera os dados</p>
      {(!pessoa || !projeto) ? <p className="vazio">São necessárias pessoas ociosas e projetos em risco para simular.</p> : <>
        <Card>
          <CardHeader><CardTitle>Escolha a realocação</CardTitle></CardHeader>
          <CardContent className="controles">
            <label>Pessoa ociosa
              <select value={pessoa.colaborador_id} onChange={(evento) => { setPessoaId(evento.target.value); setProjetoId(""); }}>
                {pessoas.map((item) => <option key={item.colaborador_id} value={item.colaborador_id}>{item.colaborador_id} · {item.nome} · {item.papel} ({item.projeto_origem})</option>)}
              </select>
            </label>
            <label>Projeto de destino
              <select value={projeto.projeto} onChange={(evento) => setProjetoId(evento.target.value)}>
                {destinos.map((item) => <option key={item.projeto} value={item.projeto}>{item.projeto} · {item.nome} · {item.situacao}</option>)}
              </select>
            </label>
            <label>Horas de onboarding
              <input type="number" min="0" step="1" value={horasOnboarding} onChange={(evento) => setHorasOnboarding(Number(evento.target.value))} />
            </label>
          </CardContent>
        </Card>
        {resultado && <>
          <div className="kpis simulacao">
            <CartaoKpi titulo="Horas no mês" valor={`${indice(resultado.horasMes)} h`} detalhe="Horas ociosas médias × 4" />
            <CartaoKpi titulo="Ociosidade evitada" valor={reais(resultado.ociosidadeEvitada)} detalhe="Custo ocioso médio × 4" />
            <CartaoKpi titulo="Dias recuperados" valor={`${indice(resultado.diasRecuperados)} dias`} detalhe="Impacto da causa nos últimos 90 dias" />
            <CartaoKpi titulo="Mobilização" valor={reais(resultado.mobilizacao)} detalhe="Onboarding × custo da hora" />
            <CartaoKpi titulo="Saldo" valor={reais(resultado.saldo)} detalhe="Ociosidade evitada − mobilização" />
          </div>
          <details>
            <summary>Como a conta foi feita</summary>
            <p>Horas no mês = média semanal de horas ociosas × 4. Ociosidade evitada = média semanal do custo ocioso × 4. Para SRE, usamos os dias de impacto por falta de SRE; para outras pessoas, por rotatividade. Dias recuperados = dias de impacto registrados nos últimos 90 dias ÷ 90 × 30. Mobilização = horas de onboarding × custo da hora. Saldo = ociosidade evitada − mobilização.</p>
          </details>
        </>}
      </>}
    </section>
  );
}

function Perguntar() {
  const [email, setEmail] = useState<string | null>(null);
  useEffect(() => {
    const controller = new AbortController();
    fetch("/api/whoami", { signal: controller.signal })
      .then((response) => response.ok ? response.json() as Promise<{ email: string | null }> : null)
      .then((identity) => setEmail(identity?.email ?? null))
      .catch(() => {});
    return () => controller.abort();
  }, []);

  return <section aria-labelledby="titulo-perguntar">
    <h2 id="titulo-perguntar">Pergunte à carteira</h2>
    <p className="metadado">Genie Farol · Diretoria · fotografia de 16/10/2026</p>
    <div className="genie-identidade">
      <Badge variant="secondary">{email ?? "Usuário conectado"}</Badge>
      <span className="metadado">A consulta usa suas permissões do Databricks.</span>
    </div>
    <p className="metadado">Respostas geradas por IA podem conter erros. Confira o SQL exibido em cada resposta antes de decidir.</p>
    <div className="genie-chat"><GenieChat alias="default" placeholder="Pergunte sobre projetos, pessoas ou fornecedores…" /></div>
  </section>;
}

export default function App() {
  const [tela, setTela] = useState<"risco" | "simulador" | "perguntar">("risco");
  const kpis = useAnalyticsQuery("kpis", {});
  const projetos = useAnalyticsQuery("projetos_risco", {});
  const pessoas = useAnalyticsQuery("pessoas_ociosas", {});
  const { score, erro: scoreErro } = useScore();
  const linhasKpi = z.array(kpiSchema).safeParse(kpis.data).data ?? [];
  const linhasProjetos = z.array(projetoSchema).safeParse(projetos.data).data ?? [];
  const linhasPessoas = z.array(pessoaSchema).safeParse(pessoas.data).data ?? [];
  const carregando = kpis.loading || projetos.loading || pessoas.loading;
  const erro = kpis.error || projetos.error || pessoas.error;
  const vazio = !linhasKpi.length || !linhasProjetos.length;

  return (
    <div className="app-shell">
      <header className="topo">
        <div><p className="marca">VÉRTICE · TORRE DE CONTROLE</p><h1>Projeto Farol</h1></div>
        <nav aria-label="Telas do app">
          <button type="button" aria-current={tela === "risco" ? "page" : undefined} onClick={() => setTela("risco")}>Projetos em risco</button>
          <button type="button" aria-current={tela === "simulador" ? "page" : undefined} onClick={() => setTela("simulador")}>Simulador</button>
          <button type="button" aria-current={tela === "perguntar" ? "page" : undefined} onClick={() => setTela("perguntar")}>Perguntar</button>
        </nav>
      </header>
      <main>
        {tela === "perguntar" ? <Perguntar /> : <>
        <EstadoDados loading={carregando} error={erro} vazio={vazio} />
        {!carregando && !erro && !vazio && (tela === "risco"
          ? <ProjetosEmRisco kpis={linhasKpi[0]} projetos={linhasProjetos} score={score} scoreErro={scoreErro} />
          : <Simulador pessoas={linhasPessoas} projetos={linhasProjetos} />)}
        </>}
      </main>
    </div>
  );
}
