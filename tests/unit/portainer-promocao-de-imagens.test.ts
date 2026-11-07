import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const workflow = readFileSync(".github/workflows/imagens-3f-custom.yml", "utf8");
function job(nome: string) {
  const inicio = workflow.indexOf(`\n  ${nome}:\n`);
  expect(inicio, `job ausente: ${nome}`).toBeGreaterThan(-1);
  const trecho = workflow.slice(inicio + 1);
  return trecho.split(/\n(?= {2}[a-z][a-z-]*:\n)/)[0] ?? "";
}

describe("promoção de imagens do Portainer", () => {
  it("o build publica somente a versão por SHA, sem mover a tag de produção", () => {
    const publicar = job("publicar");
    const tags = publicar.split("tags:")[1]?.split("build-args:")[0] ?? "";
    expect(tags).toContain(":sha-${{ steps.ver.outputs.curta }}");
    expect(tags).not.toContain(":3f-custom");
    expect(tags).not.toContain("format(");
  });

  it("a promoção depende da prova aprovada e o deploy depende da promoção", () => {
    expect(job("provar")).toMatch(/needs:\s*publicar/);
    expect(job("promover")).toMatch(/needs:\s*provar/);
    expect(job("implantar")).toMatch(/needs:\s*promover/);
    expect(job("promover")).not.toMatch(/if:\s*always\(/);
  });

  it("promove todas as imagens construídas a partir do SHA testado", () => {
    const imagens = [...job("publicar").matchAll(/- name: (deskcomm[\w-]+)\n\s+dockerfile:/g)].map(
      (m) => m[1],
    );
    expect(imagens).toHaveLength(6);
    const promover = job("promover");
    for (const imagem of imagens) expect(promover).toContain(imagem);
    expect(promover).toContain('versao="sha-${GITHUB_SHA::7}"');
    expect(promover).toContain('--tag "$imagem:3f-custom" "$imagem:$versao"');
    expect(promover).toContain("set -euo pipefail");
  });
  it("uma candidata de PR não promove a tag de produção", () => {
    expect(job("promover")).toContain(
      "if: github.event_name == 'push' && github.ref_name == '3f-custom'",
    );
    expect(job("publicar")).toContain(
      "github.event.pull_request.head.repo.full_name == github.repository",
    );
  });
});
