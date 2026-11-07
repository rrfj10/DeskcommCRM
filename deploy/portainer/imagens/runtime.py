#!/usr/bin/env python3
"""Observa o Swarm e reporta ao contrato existente; não executa pedidos de update."""
import json
import os
import re
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROLES = ("app", "worker", "scheduler")
SHA = re.compile(r"[a-f0-9]{40,64}\Z")
CONTAINER = re.compile(r"[a-f0-9]{64}\Z")
IMAGE = re.compile(r"sha256:[a-f0-9]{64}\Z")
RELEASE = re.compile(r"v?\d+\.\d+\.\d+\Z")
OFFICIAL = "https://github.com/melgarafael/DeskcommCRM.git"


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=45).stdout.strip()


class Observer:
    def __init__(self, stack, owner, state="/estado/runtime.git"):
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", stack):
            raise ValueError("stack inválida")
        if not re.fullmatch(r"[a-zA-Z0-9-]{1,80}", owner):
            raise ValueError("dono inválido")
        self.stack, self.repo = stack, f"https://github.com/{owner}/DeskcommCRM"
        self.state = state
        self.proofs = {}
        self.proof_issues = set()

    def docker(self, *args):
        return command("docker", *args)

    def inspect(self, *args):
        return json.loads(self.docker(*args))[0]

    def selection(self, role):
        return sorted(self.docker("ps", "--no-trunc", "-q", "--filter",
                                  f"label=com.docker.swarm.service.name={self.stack}_{role}").split())

    def proof(self, revision, version):
        key = (revision, version)
        if key in self.proofs:
            if self.proofs[key] is None:
                raise ValueError("origem não comprovada nesta coleta")
            return self.proofs[key]
        # Tags oficiais e histórico do fork têm origens separadas. Não basta
        # confiar na string APP_VERSION ou nos labels fornecidos pela imagem.
        state = Path(self.state)
        if not state.exists():
            command("git", "init", "--bare", str(state))
        git = ("git", "--git-dir", str(state))
        command(*git, "fetch", "--quiet", "--filter=blob:none", "--no-tags",
                self.repo + ".git", revision)
        ref = "refs/runtime-base/v" + version.removeprefix("v")
        command(*git, "fetch", "--quiet", "--filter=blob:none", "--no-tags", OFFICIAL,
                f"refs/tags/v{version.removeprefix('v')}:{ref}")
        base = command(*git, "rev-parse", ref + "^{commit}")
        if not SHA.fullmatch(base):
            raise ValueError("revisão base inválida")
        command(*git, "merge-base", "--is-ancestor", base, revision)
        self.proofs[key] = base
        return base

    def service(self, role, ids):
        result = dict(role=role, container_id=None, image_id=None, revision=None,
                      base_version=None, base_revision=None, source_verified=False,
                      running=False, healthy=False)
        if len(ids) != 1 or not CONTAINER.fullmatch(ids[0]):
            return result
        container = self.inspect("inspect", ids[0])
        service = self.inspect("service", "inspect", f"{self.stack}_{role}")
        labels = container.get("Config", {}).get("Labels", {})
        if (service["Spec"]["Name"] != f"{self.stack}_{role}"
                or service["Spec"].get("Labels", {}).get("com.docker.stack.namespace") != self.stack
                or labels.get("com.docker.swarm.service.id") != service["ID"]):
            return result
        image_id = container.get("Image", "")
        if not IMAGE.fullmatch(image_id):
            return result
        image = self.inspect("image", "inspect", image_id)
        config = image.get("Config", {})
        metadata = config.get("Labels", {})
        environment = dict(item.split("=", 1) for item in config.get("Env", []) if "=" in item)
        revision = metadata.get("org.opencontainers.image.revision", "")
        version = environment.get("APP_VERSION", "")
        state = container.get("State", {})
        result.update(container_id=ids[0], image_id=image_id,
                      revision=revision if SHA.fullmatch(revision) else None,
                      base_version=version.removeprefix("v") if RELEASE.fullmatch(version) else None,
                      running=state.get("Running") is True,
                      healthy=state.get("Health", {}).get("Status") == "healthy")
        if (metadata.get("org.opencontainers.image.source") == self.repo
                and result["revision"] and result["base_version"]):
            try:
                result["base_revision"] = self.proof(revision, version)
                result["source_verified"] = True
            except (subprocess.SubprocessError, ValueError, OSError):
                self.proofs[(revision, version)] = None
                self.proof_issues.add("release_refs_unavailable")
        return result

    def collect(self):
        self.proofs = {}  # não renova a evidência de origem com um cache antigo
        self.proof_issues = set()
        issues, services, selected = [], [], {}
        for role in ROLES:
            try:
                selected[role] = self.selection(role)
                services.append(self.service(role, selected[role]))
            except (subprocess.SubprocessError, KeyError, ValueError, OSError):
                issues.append("collection_failed")
                services.append(dict(role=role, container_id=None, image_id=None, revision=None,
                                     base_version=None, base_revision=None, source_verified=False,
                                     running=False, healthy=False))
        # Reconfere no fim para não juntar pedaços de um rollout em um recibo.
        for role in ROLES:
            try:
                if self.selection(role) != selected.get(role):
                    issues.append("changed_during_collection")
            except (subprocess.SubprocessError, OSError):
                issues.append("collection_failed")
        return dict(schema=1, collected_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), project=self.stack,
                    services=services, issues=sorted(set(issues) | self.proof_issues))

    def token(self):
        app = self.inspect("service", "inspect", self.stack + "_app")
        values = dict(item.split("=", 1) for item in
                      app["Spec"]["TaskTemplate"]["ContainerSpec"].get("Env", []) if "=" in item)
        token = values.get("INTERNAL_CRON_SECRET") or values.get("INTERNAL_SECRET")
        if not token:
            raise ValueError("credencial do observador ausente")
        return token

    def report(self):
        observation = self.collect()
        current = observation["services"][0]
        payload = dict(kind="heartbeat", supports_forced_update=False,
                       current_version=current["base_version"] or "",
                       current_sha=current["revision"] or "", off_release=True,
                       latest_version="", compare_failed=True, has_known_release=True,
                       changelog="", runtime_confirmation=observation)
        request = urllib.request.Request("http://app:3000/api/v1/system/agent",
                                         data=json.dumps(payload).encode(), method="POST",
                                         headers={"Authorization": "Bearer " + self.token(),
                                                  "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 200:
                raise ValueError("heartbeat recusado")
        Path("/tmp/runtime-ok").touch()
        print("runtime Portainer: observação entregue", flush=True)


def main():
    observer = Observer(os.environ["STACK"], os.environ["IMAGE_OWNER"])
    while True:
        try:
            observer.report()
        except Exception as error:
            # Nunca imprime Docker Env, payload, bearer, resposta ou mensagem
            # arbitrária da exceção; o rodapé expira a evidência sem heartbeat.
            print("runtime Portainer: falha de observação (" + type(error).__name__ + ")", flush=True)
        time.sleep(300)


if __name__ == "__main__":
    main()
