import { analytics, createApp, genie, getExecutionContext, server } from "@databricks/appkit";
import { obterScore } from "./score-estouro";

const warehouseId = process.env.DATABRICKS_WAREHOUSE_ID;

await createApp({
  plugins: [server(), analytics(), genie()],
  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      app.get("/api/whoami", (req, res) => {
        res.json({
          email: req.header("x-forwarded-email") ?? null,
          user: req.header("x-forwarded-user") ?? null,
        });
      });
      app.get("/api/score-estouro", async (_req, res) => {
        if (!warehouseId) {
          res.status(503).json({ error: "SQL warehouse não configurado" });
          return;
        }

        try {
          const { client } = getExecutionContext();
          const resposta = await obterScore(async (sql) => {
            let consulta = await client.statementExecution.executeStatement({
              warehouse_id: warehouseId,
              statement: sql,
              wait_timeout: "50s",
              on_wait_timeout: "CONTINUE",
            });
            while (consulta.status?.state === "PENDING" || consulta.status?.state === "RUNNING") {
              if (!consulta.statement_id) throw new Error("Consulta sem statement_id");
              await new Promise((resolve) => setTimeout(resolve, 1500));
              consulta = await client.statementExecution.getStatement({ statement_id: consulta.statement_id });
            }
            if (consulta.status?.state !== "SUCCEEDED") {
              throw new Error(consulta.status?.error?.message ?? `Consulta falhou: ${consulta.status?.state}`);
            }
            if (consulta.manifest?.truncated || consulta.result?.next_chunk_index != null) {
              throw new Error("Resultado do score foi truncado");
            }
            return (consulta.result?.data_array ?? []).map((linha) => ({
              projeto_id: String(linha[0] ?? ""),
              prob_estouro_30d: Number(linha[1]),
              faixa_risco: String(linha[2] ?? ""),
            }));
          });
          res.json(resposta);
        } catch (erro) {
          console.error("Falha ao consultar score_estouro_30d", erro);
          res.status(500).json({ error: "Não foi possível consultar o score" });
        }
      });
    });
  },
});
