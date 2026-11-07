import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { describe, expect, it } from "vitest";

function executar(codigo: string) {
  const pasta = mkdtempSync(join(tmpdir(), "setup-portainer-"));
  try {
    return spawnSync("bash", ["-s", "--", "deploy/portainer/imagens/setup.sh", pasta], {
      input: `source "$1"\nstate="$2"\nsleep() { :; }\n${codigo}`,
      encoding: "utf8",
      timeout: 15_000,
    });
  } finally {
    rmSync(pasta, { recursive: true, force: true });
  }
}

describe("setup Portainer — conflitos, convergência e retomada", () => {
  it("carregar as funções não aplica schema nem chama Docker", () => {
    const r = executar('printf "carregado"');
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toBe("carregado");
  });

  it("repete update out of sequence e recupera na terceira tentativa", () => {
    const r = executar(`
      docker() {
        local n=0; [ ! -f "$state/n" ] || n="$(cat "$state/n")"
        n=$((n+1)); echo "$n" > "$state/n"
        if [ "$n" -lt 3 ]; then echo 'rpc error: update out of sequence' >&2; return 1; fi
        echo atualizado
      }
      swarm_com_retry update --detach --image exemplo:versao deskcomm_app
      cat "$state/n"
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toBe("atualizado\n3\n");
  });

  it("esgota cinco disputas sem anunciar sucesso", () => {
    const r = executar(`
      docker() { echo tentativa >> "$state/n"; echo 'update out of sequence' >&2; return 1; }
      trap 'wc -l < "$state/n"' EXIT
      swarm_com_retry update deskcomm_app
      echo sucesso
    `);
    expect(r.status).toBe(1);
    expect(r.stdout.trim()).toBe("5");
    expect(r.stderr).toContain("update out of sequence");
  });

  it("falha de permissão não é repetida nem ocultada", () => {
    const r = executar(`
      docker() { echo tentativa >> "$state/n"; echo 'permission denied' >&2; return 1; }
      trap 'wc -l < "$state/n"' EXIT
      swarm_com_retry update deskcomm_app
    `);
    expect(r.status).toBe(1);
    expect(r.stdout.trim()).toBe("1");
    expect(r.stderr).toContain("permission denied");
  });

  it("só aceita réplicas do serviço exato, depois de sair de updating", () => {
    const r = executar(`
      docker() {
        case "$2" in
          inspect)
            if [ -f "$state/viu" ]; then echo completed; else touch "$state/viu"; echo updating; fi ;;
          ls) printf 'deskcomm_app_antigo 2/2\ndeskcomm_app 1/1\n' ;;
        esac
      }
      aguardar_replicas deskcomm_app 1
      echo pronto
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout.trim()).toBe("pronto");
  });

  it.each(["paused", "rollback_started", "rollback_completed", "rollback_paused"])(
    "%s reprova mesmo com uma réplica rodando",
    (estado) => {
      const r = executar(`
        docker() { if [ "$2" = inspect ]; then echo ${estado}; else echo 'deskcomm_app 1/1'; fi; }
        aguardar_replicas deskcomm_app 1
        echo pronto
      `);
      expect(r.status).toBe(1);
      expect(r.stderr).toContain(estado);
      expect(r.stdout).not.toContain("pronto");
    },
  );

  it("timeout de convergência é falha", () => {
    const r = executar(`
      docker() { if [ "$2" = inspect ]; then echo updating; else echo 'deskcomm_app 0/1'; fi; }
      aguardar_replicas deskcomm_app 1
    `);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("não convergiu");
  });

  it("pausa até 0/0 e restaura as duas réplicas anteriores", () => {
    const r = executar(`
      QUEM_PAUSA=deskcomm_app; PAUSADOS=''
      docker() {
        case "$2" in
          inspect) case "$4" in *Replicas*) echo 2 ;; *) echo completed ;; esac ;;
          scale) echo "\${4#*=}" > "$state/replicas" ;;
          ls) local n; n="$(cat "$state/replicas")"; echo "deskcomm_app $n/$n" ;;
        esac
      }
      pausar
      echo "pausados=$PAUSADOS"
      retomar
      echo "replicas=$(cat "$state/replicas") pendentes=$PAUSADOS"
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain("deskcomm_app:2");
    expect(r.stdout).toContain("replicas=2 pendentes=\n");
  });

  it("falha ao retomar preserva o serviço pendente e reprova", () => {
    const r = executar(`
      PAUSADOS='deskcomm_app:2'
      docker() { echo 'permission denied' >&2; return 1; }
      retomar && exit 42
      echo "pendentes=$PAUSADOS"
    `);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("pendentes= deskcomm_app:2");
    expect(r.stderr).toContain("não foi possível restaurar");
  });

  it("a limpeza converte falha de retomada em exit 1", () => {
    const r = executar(`
      PAUSADOS='deskcomm_app:1'
      docker() { return 1; }
      trap finalizar EXIT
      exit 0
    `);
    expect(r.status).toBe(1);
  });
  it("o fluxo principal não aplica schema quando não conseguiu pausar", () => {
    const r = executar(`
      STACK=deskcomm; IMAGE_OWNER=teste; DESKCOMM_VERSION=teste
      POSTGRES_PASSWORD=teste; SERVICE_ROLE_KEY=teste; OWNER_EMAIL=teste@example.test; OWNER_PASSWORD=teste
      NUVEMSHOP_OAUTH_ENCRYPTION_KEY=teste; CPF_ENCRYPTION_KEY=teste; FORCAR_SCHEMA=1
      sql() { case "$1" in *storage*) echo 2 ;; *) echo 1 ;; esac; }
      sha256sum() { echo 'hash arquivo'; }
      psql() { :; }
      pausar() { return 1; }
      reaplicar() { echo 'SCHEMA_APLICADO'; }
      main
    `);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain("não foi possível pausar");
    expect(r.stdout).not.toContain("SCHEMA_APLICADO");
    expect(r.stdout).not.toContain("Pronto.");
  });

  it("a atualização completa aguarda os três serviços antes de dizer Pronto", () => {
    const r = executar(`
      STACK=deskcomm; IMAGE_OWNER=teste; DESKCOMM_VERSION=sha-teste
      docker() {
        case "$2" in
          inspect) if [ "$3" = --format ]; then echo 1; fi ;;
          update) echo "$5" >> "$state/atualizados" ;;
        esac
      }
      aguardar_replicas() { echo "$1 pronto"; }
      instalar_observador() { :; }
      atualizar_servicos
      cat "$state/atualizados"
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toMatch(
      /deskcomm_app pronto[\s\S]*deskcomm_worker pronto[\s\S]*deskcomm_scheduler pronto[\s\S]*Pronto\./,
    );
    expect(r.stdout).toContain("ghcr.io/teste/deskcommcrm:sha-teste");
  });

  it("rollback de um serviço impede Pronto e a atualização dos seguintes", () => {
    const r = executar(`
      STACK=deskcomm; IMAGE_OWNER=teste; DESKCOMM_VERSION=sha-teste
      docker() {
        case "$2" in
          inspect) if [ "$3" = --format ]; then echo 1; fi ;;
          update) echo "$*" >> "$state/atualizados" ;;
        esac
      }
      aguardar_replicas() { return 1; }
      trap 'cat "$state/atualizados"' EXIT
      instalar_observador() { :; }
      atualizar_servicos
    `);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain("deskcomm_app");
    expect(r.stdout).not.toContain("deskcomm_worker");
    expect(r.stdout).not.toContain("Pronto.");
    expect(r.stderr).toContain("não ficou pronta");
  });
  it("instala o observador em uma stack antiga sem copiar as credenciais", () => {
    const r = executar(`
      STACK=deskcomm; IMAGE_OWNER=teste; DESKCOMM_VERSION=sha-teste
      docker() {
        if [ "$2" = inspect ]; then return 1; fi
        printf '%s\\n' "$@" > "$state/create"
      }
      aguardar_replicas() { :; }
      instalar_observador
      cat "$state/create"
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain("deskcomm_runtime");
    expect(r.stdout).toContain("--runtime");
    expect(r.stdout).toContain("br.portainer.runtime.stack=deskcomm");
    expect(r.stdout).not.toContain("POSTGRES_PASSWORD");
    expect(r.stdout).not.toContain("INTERNAL_SECRET");
  });

  it("atualiza o observador existente, sem criar outro", () => {
    const r = executar(`
      STACK=deskcomm; IMAGE_OWNER=teste; DESKCOMM_VERSION=sha-teste
      docker() { if [ "$2" != inspect ]; then printf '%s\\n' "$@" > "$state/update"; fi; }
      aguardar_replicas() { :; }
      instalar_observador
      cat "$state/update"
    `);
    expect(r.status, r.stderr).toBe(0);
    expect(r.stdout).toContain("update");
    expect(r.stdout).toContain("--args=--runtime");
    expect(r.stdout).not.toContain("create");
  });
});
