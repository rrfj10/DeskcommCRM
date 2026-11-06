# syntax=docker/dockerfile:1
# Gateway do Supabase com a configuração embutida, na ref self-hosted/v0.8.1.
FROM envoyproxy/envoy:v1.39.1
ARG BASE=https://raw.githubusercontent.com/supabase/supabase/self-hosted/v0.8.1/docker/volumes/api/envoy
ADD --chmod=644 --checksum=sha256:3697f23b0be9ec5b829f937c600eb9b878f1f778ab510b42ad5e4f14742447e9 ${BASE}/envoy.yaml /etc/envoy/envoy.yaml
ADD --chmod=644 --checksum=sha256:1d7514b891370ed27c25911df008887402e16ab09273e6e433225bb7f09f7905 ${BASE}/cds.yaml /etc/envoy/cds.yaml
ADD --chmod=644 --checksum=sha256:9d9a6d6ea0a372be99e165d995f012d383d5cc8473b92a06b7aa0bbd73566c3d ${BASE}/lds.template.yaml /etc/envoy/lds.template.yaml
ADD --chmod=755 --checksum=sha256:8a0c9503764de32ba39e0d81e73629457b13ec42ef19897e30e4918c996d0508 ${BASE}/docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/bin/sh", "/docker-entrypoint.sh"]
