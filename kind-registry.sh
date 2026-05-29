#!/bin/sh
set -o errexit

# Simple local HTTP image registry for kind.
#
# kubelet/containerd default to pulling over HTTPS, which fails against a plain
# HTTP registry. config.yaml enables the containerd registry config dir, and the
# per-node hosts.toml below points the registry alias at the http:// endpoint and
# marks it insecure so image pull/push works over HTTP.
#
# Note: containerd 2.x (these nodes run 2.2.0) ignores the inline
# registry.mirrors/configs config, so this hosts.toml style is required.

cluster_name='mykindk8s'
reg_name='kind-registry'
reg_port='5001'

# 1. Create the registry container unless it already exists.
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always \
    -p "127.0.0.1:${reg_port}:5000" \
    --network bridge --name "${reg_name}" \
    registry:3
fi

# 2. Create the kind cluster (1 control-plane + 2 workers; the registry config
#    dir is enabled via config.yaml's containerdConfigPatches).
kind create cluster --config config.yaml

# 3. Point containerd on every node at the registry over HTTP, insecurely.
#
# localhost resolves to namespace-local loopback inside a node, so we alias
# localhost:${reg_port} to the registry container on the shared docker network.
# skip_verify = true is containerd's "insecure" switch: it stops the node from
# requiring a verified HTTPS connection, so the plain-HTTP registry works.
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes --name "${cluster_name}"); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
done

# 4. Connect the registry to the cluster network if not already connected.
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# 5. Document the local registry (KEP-1755).
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
