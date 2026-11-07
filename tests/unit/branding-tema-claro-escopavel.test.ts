import fs from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { razaoDeContraste } from "@/lib/branding/contraste";

const RAIZ = process.cwd();
const CSS = fs.readFileSync(path.join(RAIZ, "app/globals.css"), "utf8");

/**
 * Lê o bloco cujo seletor está SOZINHO na linha (`[data-theme="dark"] {`).
 *
 * Casar por `includes` pegaria `[data-theme="dark"] ::selection` e
 * `[data-theme="dark"] *` junto, e o teste compararia um bloco que não existe.
 */
function blocoDe(seletor: string): Map<string, string> {
  const linhas = CSS.split("\n");
  const inicio = linhas.findIndex((l) => l.trim() === `${seletor} {`);
  if (inicio === -1) throw new Error(`não achei o bloco \`${seletor} {\` no globals.css`);
  const decls = new Map<string, string>();
  for (let i = inicio + 1; i < linhas.length; i += 1) {
    const linha = (linhas[i] ?? "").trim();
    if (linha === "}") return decls;
    if (!linha.startsWith("--")) continue;
    const corte = linha.indexOf(":");
    decls.set(
      linha.slice(0, corte).trim(),
      linha
        .slice(corte + 1)
        .replace(/;$/, "")
        .trim(),
    );
  }
  throw new Error(`o bloco \`${seletor}\` não fecha`);
}

describe("tema claro escopável em subárvore", () => {
  // Lido DENTRO de cada caso, não no corpo do describe: `blocoDe` lança quando o
  // bloco some, e um throw na coleta derruba o arquivo inteiro — a contagem cai
  // e nenhuma asserção diz o que quebrou.
  it("existe — `:root` casa só o <html>", () => {
    const claro = blocoDe('[data-theme="light"]');
    // Medido antes de escrever o bloco: `grep -c 'data-theme="light"'` = 0. Sem
    // ele, um `<div data-theme="light">` dentro de uma página escura herda os
    // tokens ESCUROS e renderiza uma tela que mente — que é exatamente o que o
    // preview lado a lado da marca faz.
    expect(claro.size).toBeGreaterThan(0);
  });

  it("espelha todos os tokens escuros, incluindo a rampa que difere entre os temas", () => {
    const claro = blocoDe('[data-theme="light"]');
    const escuro = blocoDe('[data-theme="dark"]');
    // A amostra clara precisa restaurar também os tons Sage: o escuro é Dracula.
    expect([...claro.keys()].sort()).toEqual([...escuro.keys()].sort());
    expect(claro.get("--color-accent-400")).not.toBe(escuro.get("--color-accent-400"));
  });

  it("cada valor espelhado é o mesmo do `:root`", () => {
    const raiz = blocoDe(":root");
    const claro = blocoDe('[data-theme="light"]');
    // Guarda de vacuidade: um espelho VAZIO passaria no laço abaixo sem nenhuma
    // asserção, e este caso viraria verde justamente quando o bloco sumisse.
    expect(claro.size).toBeGreaterThan(0);
    // A catraca da cópia: sem ela, mexer numa cor clara no `:root` deixa o
    // espelho com o valor de ontem, e o preview mostra uma paleta que não
    // existe em lugar nenhum.
    for (const [prop, valor] of claro) {
      expect(raiz.get(prop), `${prop} divergiu entre :root e [data-theme="light"]`).toBe(valor);
    }
  });

  it("o seletor do `:root` continua sozinho, sem lista", () => {
    // POR QUE ESTE TESTE EXISTE: a forma óbvia seria `:root, [data-theme="light"]`
    // num bloco só. Ela quebra `extrairRegua` (lib/branding/contraste.ts), que
    // acha o bloco claro por IGUALDADE EXATA de seletor — e com ele vão a régua
    // inteira e os testes de contraste. Quem "simplificar" o espelho para uma
    // lista precisa esbarrar aqui, não descobrir depois.
    expect(CSS).toMatch(/\n:root \{/);
    expect(CSS).not.toMatch(/\n:root\s*,/);
  });

  it("o `color-scheme` acompanha o escopo", () => {
    // Sem isto a subárvore recebe os tokens claros mas o navegador continua
    // pintando scrollbar, `<input>` e menu nativo em escuro dentro dela.
    expect(CSS).toMatch(/\[data-theme="light"\]\s*\{\s*color-scheme:\s*light;/);
  });
});

describe("indicador de foco no modo de alto contraste", () => {
  it("existe um rider de forced-colors que devolve o outline", () => {
    // WCAG 2.4.7, nível A. Medido: 0 ocorrências de `forced-colors` no repo, e
    // 14 arquivos que matam `outline` desenhando o foco com `ring-*` — que é
    // `box-shadow`, e o modo de alto contraste do Windows APAGA box-shadow.
    // Nesses 14, o foco simplesmente sumia.
    const bloco = /@media \(forced-colors: active\) \{[\s\S]*?\n {2}\}/.exec(CSS)?.[0] ?? "";
    expect(bloco).toContain(":focus-visible");
    expect(bloco).toMatch(/outline:\s*2px solid Highlight\s*!important/);
    expect(bloco).toMatch(/outline-offset:\s*2px\s*!important/);
  });

  it("usa cor de sistema, não cor da paleta", () => {
    // No forced-colors o navegador SUBSTITUI as cores do autor; só as cores de
    // sistema (`Highlight`) sobrevivem. Um `var(--color-accent-500)` aqui seria
    // um rider que não pinta nada.
    const bloco = /@media \(forced-colors: active\) \{[\s\S]*?\n {2}\}/.exec(CSS)?.[0] ?? "";
    expect(bloco).not.toContain("var(--");
  });
});


describe("legibilidade do tema Dracula", () => {
  it("mantém texto, destaques e estados acima de 4,5:1 nas três superfícies", () => {
    const escuro = blocoDe('[data-theme="dark"]');
    const textos = ["text", "text-muted", "text-subtle", "accent-400", "accent-300", "success-fg", "warning-fg", "error-fg", "info-fg"];
    for (const superficie of ["bg", "surface", "surface-elevated"]) {
      const fundo = escuro.get(`--color-${superficie}`);
      expect(fundo).toMatch(/^#[0-9a-f]{6}$/);
      for (const texto of textos) {
        const frente = escuro.get(`--color-${texto}`);
        expect(frente).toMatch(/^#[0-9a-f]{6}$/);
        expect(razaoDeContraste(frente!, fundo!), `${texto} sobre ${superficie}`).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
});
