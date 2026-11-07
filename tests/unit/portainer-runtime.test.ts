import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { runtimeConfirmationSchema, runtimeIdentity } from "@/lib/system/runtime-identity";

const observations: Record<string, unknown> = JSON.parse(
  execFileSync("python3", ["tests/fixtures/portainer-runtime-observacoes.py"], {
    encoding: "utf8",
  }),
);

function identity(scenario: string) {
  const snapshot = runtimeConfirmationSchema.parse(observations[scenario]);
  return runtimeIdentity(snapshot, snapshot.collected_at, new Date(snapshot.collected_at));
}

describe("observador do Swarm → contrato real do rodapé", () => {
  it("confirma a versão base e identifica o fork personalizado", () => {
    expect(identity("saudavel")).toMatchObject({
      status: "confirmed",
      base_version: "1.102.0",
      customized: true,
    });
  });
  it("não confirma três serviços com revisões diferentes", () => {
    expect(identity("divergente").status).toBe("divergent");
  });
  it.each([
    "parado",
    "sem_healthcheck",
    "unhealthy",
    "ausente",
    "duas_replicas",
    "origem_indisponivel",
    "sha_curto",
    "outra_origem",
  ])("%s mantém a execução sem confirmação", (scenario) => {
    expect(identity(scenario).status).toBe("partial");
    expect(identity(scenario).base_version).toBeNull();
  });
  it("rejeita a observação trocada durante a coleta", () => {
    const snapshot = runtimeConfirmationSchema.parse(observations.mudou);
    expect(snapshot.issues).toContain("changed_during_collection");
    expect(identity("mudou").status).toBe("partial");
  });
  it("a confirmação expira quando o observador deixa de reportar", () => {
    const snapshot = runtimeConfirmationSchema.parse(observations.saudavel);
    expect(
      runtimeIdentity(
        snapshot,
        snapshot.collected_at,
        new Date(Date.parse(snapshot.collected_at) + 16 * 60_000),
      ).status,
    ).toBe("stale");
  });
  it("valida procedência Git, autenticação e falha de comunicação no coletor", () => {
    expect(() =>
      execFileSync("python3", ["tests/fixtures/test_portainer_runtime.py"], {
        encoding: "utf8",
        stdio: "pipe",
      }),
    ).not.toThrow();
  });
  it("a imagem do setup distribui o observador e suas dependências", () => {
    const dockerfile = readFileSync("deploy/portainer/imagens/setup.Dockerfile", "utf8");
    expect(dockerfile).toContain("python3 git");
    expect(dockerfile).toContain("COPY deploy/portainer/imagens/runtime.py /runtime.py");
  });
  it("o CI identifica os três artefatos com versão semântica e revisão completa", () => {
    const workflow = readFileSync(".github/workflows/imagens-3f-custom.yml", "utf8");
    expect(workflow).toContain("needs: identidade");
    expect(workflow).toContain("APP_VERSION=${{ needs.identidade.outputs.base_version }}");
    expect(workflow).toContain("org.opencontainers.image.revision=${{ github.sha }}");
    expect(workflow).toContain(
      "org.opencontainers.image.source=https://github.com/${{ github.repository }}",
    );
  });
});
