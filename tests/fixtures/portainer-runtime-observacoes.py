"""Fixtures exercitam o coletor real sem Docker, segredos ou rede."""
import importlib.util
import json
import subprocess
from pathlib import Path

spec = importlib.util.spec_from_file_location("portainer_runtime", Path(__file__).parents[2] / "deploy/portainer/imagens/runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class Fake(runtime.Observer):
    def __init__(self, scenario):
        super().__init__("deskcomm", "teste")
        self.scenario = scenario
        self.count = {}

    def proof(self, revision, version):
        if self.scenario == "origem_indisponivel":
            raise subprocess.CalledProcessError(1, "git")
        return "a" * 40

    def selection(self, role):
        self.count[role] = self.count.get(role, 0) + 1
        number = str(runtime.ROLES.index(role) + 1)
        if self.scenario == "mudou" and self.count[role] > 1:
            return ["9" * 64]
        if self.scenario == "duas_replicas" and role == "app":
            return [number * 64, "9" * 64]
        if self.scenario == "ausente" and role == "worker":
            return []
        return [number * 64]

    def inspect(self, *args):
        if args[0] == "inspect":
            ident = args[1]
            role = runtime.ROLES[int(ident[0]) - 1]
            state = {"Running": self.scenario != "parado", "Health": {"Status": "healthy"}}
            if self.scenario == "sem_healthcheck":
                state.pop("Health")
            if self.scenario == "unhealthy":
                state["Health"]["Status"] = "unhealthy"
            return {"Image": "sha256:" + ident, "State": state, "Config": {"Labels": {
                "com.docker.swarm.service.id": "service-" + role}}}
        if args[0] == "service":
            role = args[2].removeprefix("deskcomm_")
            return {"ID": "service-" + role, "Spec": {
                "Name": args[2], "Labels": {"com.docker.stack.namespace": "deskcomm"}}}
        ident = args[2].removeprefix("sha256:")
        revision = "c" * 40 if self.scenario == "divergente" and ident[0] == "3" else "b" * 40
        return {"Config": {"Env": ["APP_VERSION=" + ("abc1234" if self.scenario == "sha_curto" else "1.102.0")],
                           "Labels": {"org.opencontainers.image.source":
                                      "https://github.com/outro/projeto" if self.scenario == "outra_origem" else self.repo,
                                      "org.opencontainers.image.revision": revision}}}


if __name__ == "__main__":
    scenarios = ["saudavel", "divergente", "parado", "sem_healthcheck", "unhealthy", "ausente",
                 "duas_replicas", "mudou", "origem_indisponivel", "sha_curto", "outra_origem"]
    print(json.dumps({s: Fake(s).collect() for s in scenarios}))
