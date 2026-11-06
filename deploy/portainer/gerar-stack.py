#!/usr/bin/env python3
"""Gera a stack pronta para colar no Portainer, com domínio e chaves preenchidos.

Rode no seu computador. As chaves ficam em ~/.deskcomm-portainer/chaves.env e rodar
de novo reaproveita todas. Nada disso vai para o Git.

    python3 deploy/portainer/gerar-stack.py --domain crm.empresa.com.br \
      --owner voce@empresa.com.br --traefik-network dcnet \
      --certresolver letsencryptresolver
"""
import argparse, base64, hashlib, hmac, json, os, re, secrets, time
from pathlib import Path


def b64url(dado):
    return base64.urlsafe_b64encode(dado).rstrip(b"=").decode()


def jwt(papel, segredo):
    agora = int(time.time())
    corpo = {"role": papel, "iss": "supabase", "iat": agora, "exp": agora + 315360000}
    h = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    p = b64url(json.dumps(corpo, separators=(",", ":")).encode())
    assinatura = hmac.new(segredo.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{b64url(assinatura)}"


def chaves_novas():
    hexa = secrets.token_hex
    b64 = lambda: base64.b64encode(secrets.token_bytes(32)).decode()
    jwt_secret = hexa(32)
    waha = hexa(32)
    return {
        "POSTGRES_PASSWORD": hexa(32),
        "JWT_SECRET": jwt_secret,
        "ANON_KEY": jwt("anon", jwt_secret),
        "SERVICE_ROLE_KEY": jwt("service_role", jwt_secret),
        "DASHBOARD_PASSWORD": hexa(24),
        "SECRET_KEY_BASE": hexa(32),
        "REALTIME_DB_ENC_KEY": hexa(8),
        "S3_PROTOCOL_ACCESS_KEY_ID": hexa(16),
        "S3_PROTOCOL_ACCESS_KEY_SECRET": hexa(32),
        "INTERNAL_SECRET": hexa(32),
        "INTERNAL_CRON_SECRET": hexa(32),
        "NUVEMSHOP_OAUTH_ENCRYPTION_KEY": hexa(32),
        "CPF_ENCRYPTION_KEY": b64(),
        "AI_CRED_AES_KEY": b64(),
        "WAHA_BYO_ENCRYPTION_KEY": b64(),
        "IMPERSONATE_COOKIE_SECRET": hexa(32),
        "LGPD_SIGNING_KEY": hexa(32),
        "WAHA_HMAC_SECRET": hexa(32),
        "SRH_TOKEN": hexa(32),
        "WAHA_API_KEY": waha,
        "WAHA_API_KEY_SHA512": hashlib.sha512(waha.encode()).hexdigest(),
        "OWNER_PASSWORD": hexa(16),
    }


def gravar(caminho, texto):
    caminho.touch(mode=0o600, exist_ok=True)
    caminho.chmod(0o600)
    caminho.write_text(texto, encoding="utf-8")


def main():
    a = argparse.ArgumentParser(description="Gera a stack do Portainer.")
    a.add_argument("--domain", required=True)
    a.add_argument("--owner", required=True)
    a.add_argument("--traefik-network", required=True)
    a.add_argument("--certresolver", required=True)
    a.add_argument("--entrypoint", default="websecure")
    a.add_argument("--version", default="3f-custom")
    a.add_argument("--image-owner", default="rrfj10")
    a.add_argument("--saida", default="~/.deskcomm-portainer")
    o = a.parse_args()

    pasta = Path(o.saida).expanduser()
    pasta.mkdir(mode=0o700, parents=True, exist_ok=True)
    arquivo = pasta / "chaves.env"
    if arquivo.exists():
        linhas = arquivo.read_text(encoding="utf-8").splitlines()
        chaves = dict(l.split("=", 1) for l in linhas if "=" in l)
    else:
        chaves = chaves_novas()
        gravar(arquivo, "".join(f"{k}={v}\n" for k, v in chaves.items()))

    valores = dict(chaves)
    valores.update(
        DOMAIN=o.domain, OWNER_EMAIL=o.owner, TRAEFIK_NETWORK=o.traefik_network,
        TRAEFIK_CERTRESOLVER=o.certresolver, TRAEFIK_ENTRYPOINT=o.entrypoint,
        DESKCOMM_VERSION=o.version, IMAGE_OWNER=o.image_owner,
    )
    molde = (Path(__file__).parent / "stack.yml").read_text(encoding="utf-8")

    def trocar(m):
        nome, padrao = m.group(1), m.group(3)
        if nome in valores:
            return valores[nome]
        if padrao is not None:
            return padrao
        raise SystemExit(f"ERRO: variável sem valor: {nome}")

    pronto = re.sub(r"\$\{([A-Z0-9_]+)(:-([^}]*))?\}", trocar, molde)
    gravar(pasta / "stack.yml", pronto)
    print(pasta / "stack.yml")


if __name__ == "__main__":
    main()
