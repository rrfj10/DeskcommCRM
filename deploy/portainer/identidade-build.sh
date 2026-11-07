#!/usr/bin/env bash
# Resolve uma release oficial ancestral; package.json mantém 0.1.0 e não é a régua.
set -euo pipefail
revision="${1:?informe o commit completo}"
[[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo 'revisão inválida' >&2; exit 1; }
git fetch --quiet --filter=blob:none --no-tags https://github.com/melgarafael/DeskcommCRM.git \
  '+refs/tags/v*:refs/portainer-base/v*'
while IFS= read -r ref; do
  version="${ref##*/}"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
  if git merge-base --is-ancestor "$ref^{commit}" "$revision"; then
    printf 'base_version=%s\n' "${version#v}"
    exit 0
  fi
done < <(git for-each-ref --sort=-version:refname --format='%(refname)' refs/portainer-base/)
echo 'não foi possível comprovar uma release base da imagem' >&2
exit 1
