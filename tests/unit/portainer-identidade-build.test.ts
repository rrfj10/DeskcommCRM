import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const script = resolve("deploy/portainer/identidade-build.sh");
const git = execFileSync("sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "portainer-base-"));
  const run = (...args: string[]) =>
    execFileSync(git, args, {
      cwd: dir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  run("init", "-q");
  run("config", "user.name", "Teste");
  run("config", "user.email", "teste@example.test");
  run("commit", "--allow-empty", "-qm", "base");
  const base = run("rev-parse", "HEAD");
  run("update-ref", "refs/portainer-base/v1.0.0", base);
  run("checkout", "-qb", "fork");
  run("commit", "--allow-empty", "-qm", "release");
  run("update-ref", "refs/portainer-base/v1.1.0", run("rev-parse", "HEAD"));
  run("commit", "--allow-empty", "-qm", "personalizacao");
  const revision = run("rev-parse", "HEAD");
  run("checkout", "-qb", "outra", base);
  run("commit", "--allow-empty", "-qm", "outra linhagem");
  run("update-ref", "refs/portainer-base/v9.0.0", run("rev-parse", "HEAD"));
  run("checkout", "-q", "fork");
  mkdirSync(join(dir, "bin"));
  writeFileSync(
    join(dir, "bin/git"),
    '#!/bin/sh\nif [ "$1" = fetch ]; then printf "%s\\n" "$@" > "$TEST_FETCH_LOG"; exit 0; fi\nexec "$REAL_GIT" "$@"\n',
  );
  chmodSync(join(dir, "bin/git"), 0o755);
  return {
    dir,
    revision,
    run,
    env: {
      ...process.env,
      PATH: join(dir, "bin") + ":" + process.env.PATH,
      REAL_GIT: git,
      TEST_FETCH_LOG: join(dir, "fetch.log"),
    },
  };
}

describe("release base comprovada no build", () => {
  it("escolhe a maior release ancestral e rejeita uma tag maior de outra linhagem", () => {
    const f = fixture();
    try {
      const r = spawnSync("bash", [script, f.revision], {
        cwd: f.dir,
        env: f.env,
        encoding: "utf8",
      });
      expect(r.status, r.stderr).toBe(0);
      expect(r.stdout.trim()).toBe("base_version=1.1.0");
      expect(readFileSync(join(f.dir, "fetch.log"), "utf8")).toContain(
        "https://github.com/melgarafael/DeskcommCRM.git",
      );
    } finally {
      rmSync(f.dir, { recursive: true, force: true });
    }
  });
  it("sem release ancestral não publica uma versão inventada", () => {
    const f = fixture();
    try {
      for (const ref of ["v1.0.0", "v1.1.0"])
        f.run("update-ref", "-d", "refs/portainer-base/" + ref);
      const r = spawnSync("bash", [script, f.revision], {
        cwd: f.dir,
        env: f.env,
        encoding: "utf8",
      });
      expect(r.status).toBe(1);
      expect(r.stdout).toBe("");
      expect(r.stderr).toContain("não foi possível comprovar");
    } finally {
      rmSync(f.dir, { recursive: true, force: true });
    }
  });
});
