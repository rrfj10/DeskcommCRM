# 02 — Paleta Sage clara e Dracula escura

> **Source of truth do produto:** `app/globals.css`. O showcase em `app/design/lib/tokens.ts` mantém as paletas exploratórias.
> O modo claro usa Sage; o modo escuro usa Dracula. Cores de marca configuradas pela instalação ou organização continuam tendo precedência sobre o destaque padrão.

## Filosofia da paleta

Sage é verde-erva desaturado: o suficiente pra ter personalidade vegetal, longe o suficiente pra não evocar o cliché "wellness/saúde mental". O DeskcommCRM é uma ferramenta de **trabalho operacional**, e Sage projeta:

- **Calma sem fragilidade** — saturação ≤ 30% no accent 500 evita a sensação clínica.
- **Confiança warm** — neutros greige (warm-gray, base bege/oliva) ao invés de slate/zinc, que carregam tom corporativo frio.
- **Anti-genérico** — 80%+ dos CRMs SaaS usam blue/indigo/violet. Sage diverge sem cair em cores de risco (laranja, vermelho, rosa).
- **Funcional em monitores 8h/dia** — luminosidade calibrada pra não cansar; backgrounds nunca puro `#fff` (offwhite warm) nem puro `#000` (very-dark warm).

A paleta tem **dois temas desenhados independentemente**, não invertidos. Light não é dark com inversão de luminosidade; cada um foi calibrado pra contraste e conforto na sua direção.

## Light theme — accent (Sage verde)

| Stop | Hex | Uso prescrito |
|------|-----|---------------|
| 50 | `#f3f6f1` | Background de hover muito sutil, soft chip background |
| 100 | `#e4ebe0` | `--ds-accent-soft` — bg de badge accent, hover de nav-link, focus ring outer |
| 200 | `#c8d6c1` | Borders de elementos accent secundários |
| 300 | `#a4ba9a` | Disabled state do accent, decorative dividers |
| 400 | `#82a077` | Hover de elementos accent claros |
| 500 | `#67885d` | **Brand accent canônico** — botão primary bg, link, focus ring color |
| 600 | `#506d48` | Hover de primary button (escurece) |
| 700 | `#41573b` | Pressed state de primary button |
| 800 | `#374731` | Texto sobre fundos accent claros (a11y AAA) |
| 900 | `#2f3c2b` | — (raramente usado em light) |
| 950 | `#171f15` | — (uso extremo, evite) |

## Light theme — neutral greige

| Stop | Hex | Uso prescrito |
|------|-----|---------------|
| 50 | `#faf9f6` | `--ds-bg` — page background (offwhite warm) |
| 100 | `#f3f1ec` | Background de seções, alt-row de tabela |
| 200 | `#e7e3da` | `--ds-border` — borders default |
| 300 | `#d2cdbf` | Borders mais firmes, divider de tabela |
| 400 | `#a9a395` | Placeholder text, ícone disabled |
| 500 | `#7d786c` | Texto utilitário (timestamp, helper) |
| 600 | `#5d594f` | `--ds-text-muted` — texto secundário, label |
| 700 | `#46433b` | Texto importante mas não primary |
| 800 | `#2e2c26` | Heading secundário |
| 900 | `#1c1a16` | `--ds-text` — texto primary (corpo, headings) |
| 950 | `#0e0d0a` | Texto extremamente alto contraste (raro) |

**Surfaces light:**
- `bg`: `#faf9f6` — página
- `surface`: `#ffffff` — cards e superfícies elevadas (puro branco)
- `surfaceElevated`: `#f5f3ee` — alt-bg, header, dropdown bg
- `text`: `#1c1a16` / `textMuted`: `#5d594f` / `border`: `#e7e3da`

## Dark theme — Dracula

O modo escuro existente usa Dracula, sem uma opção de tema adicional. A preferência claro/escuro/sistema continua no controle de tema atual.

| Token | Hex / valor |
|---|---|
| Fundo | `#282a36` |
| Superfície | `#21222c` |
| Superfície elevada | `#343746` |
| Texto | `#f8f8f2` |
| Texto secundário | `#b8bbd0` |
| Texto sutil | `#9da2bd` |
| Borda | `#44475a` |
| Borda forte | `#6272a4` |
| Destaque (400) | `#bd93f9` |
| Destaque hover (300) | `#d1b2ff` |
| Frente do destaque | `#282a36` |
| Fundo suave | `rgba(189, 147, 249, 0.16)` |

A rampa completa mora no seletor `[data-theme="dark"]` do CSS global. As amostras claras restauram a rampa Sage para não herdarem os tons Dracula. A régua embarcada de branding é gerada desse CSS, inclusive para o build standalone e a cor da barra do navegador.

## Estados (success / warning / error / info)

Estados têm versões light e dark calibradas. Saturação fica ≤ 55% em light, ≤ 65% em dark (mantém calma).

| Estado | Light | Dark | Uso |
|--------|-------|------|-----|
| `success` | `#5a8a5f` | `#50fa7b` | Confirmação positiva, status "ativo", "lido" |
| `warning` | `#b07a2b` | `#f1fa8c` | Atenção sem urgência, SLA próximo de vencer |
| `error` | `#a94a3c` | `#ff5555` | Erro, ação destrutiva, SLA estourado |
| `info` | `#4a7a93` | `#8be9fd` | Mensagem informativa, dica |

**Como aplicar estados (3 padrões):**

```css
/* 1. Como bg de badge: estado a 14% transparência + estado como fg */
.badge-success {
  background: color-mix(in srgb, var(--ds-success) 14%, transparent);
  color: var(--ds-success);
}

/* 2. Como border (foco específico): full opacity */
.input-error { border-color: var(--ds-error); }

/* 3. Como bg de botão destrutivo: full opacity, fg branco */
.btn-destructive { background: var(--ds-error); color: #fff; }
```

## Contraste WCAG

As razões abaixo são referências do tema claro. Para medir o contraste atual, incluindo superfícies Dracula e marca personalizada, execute `pnpm vitest run tests/unit/branding-contraste.test.ts tests/unit/branding-pares-pintados.test.ts`.

| Combinação | Ratio | Nível | OK pra |
|------------|-------|-------|--------|
| `text` (`#1c1a16`) sobre `bg` (`#faf9f6`) | ~14.8:1 | AAA | Prosa longa, body text |
| `text-muted` (`#5d594f`) sobre `bg` | ~6.7:1 | AA+ | Secondary, helper, timestamps |
| `accent-500` (`#67885d`) sobre `bg` | ~4.6:1 | AA | Texto UI 14px+, botão primary |
| `accent-700` (`#41573b`) sobre `accent-soft` | ~7.2:1 | AAA | Link em chip, label sobre badge |
| `error` light (`#a94a3c`) sobre `bg` | ~4.7:1 | AA | UI text 14px+ |

**Regras:**
- Body text e prosa: AAA mínimo (`text` + `bg`).
- UI text 14px+: AA mínimo (4.5:1).
- Componentes não-textuais (borders, ícones): AA UI mínimo (3:1).
- Nunca usar `text-muted` para texto em prosa longa (apenas labels, helpers, timestamps).

## Anti-padrões — como NÃO usar Sage

❌ **Saturar accent além de 600.** Stops 700–950 só pra texto em fundo claro accent, nunca como bg de área grande.

❌ **Accent como bg de toda a sidebar.** Sidebar é greige (`surface` ou `surface-elevated`). Accent na sidebar fica como hover-state e active-state apenas.

❌ **Accent em texto de longa leitura.** Body de e-mail, descrição de pedido, prosa de doc — tudo `text` (`#1c1a16`). Accent só em link, label de status, ações.

❌ **`#000` ou `#fff` puro.** Texto preto puro contra bg warm-offwhite cria vibração; use `#1c1a16` e `#faf9f6`.

❌ **Misturar Sage com cores fora dos estados.** Não importe roxo, azul-bandeira, ciano — não fazem parte do sistema. Se precisa diferenciar tags do usuário, use stops do greige + 1 acento; se precisa de cores categóricas (gráfico), abrir RFC.

❌ **Gradients accent → accent.** Sage não usa gradients; use solid + shadow se precisar profundidade.

## Acessibilidade (visão de cor)

Sage foi escolhida também por segurança em deficiências de visão:

- **Deuteranopia** (verde-cego, ~6% homens): Sage 500 vira marrom-acinzentado dessaturado; mantém 4.2:1 contra bg, ainda AA. Diferenciação verde-vermelho dos estados (success vs error) preservada porque error é warm-red (não puro green/red).
- **Protanopia** (vermelho-cego): comportamento similar; Sage 500 vira amarelo-oliva.
- **Tritanopia** (azul-amarelo, raro): menos afetada — Sage permanece reconhecível como verde dessaturado.

Em todos os casos, **nunca dependa só de cor pra comunicar estado**. Use ícone Phosphor + cor + label de texto. Ex: badge de SLA estourado tem cor error, ícone `Warning`, e texto "Vencido há 2h".
