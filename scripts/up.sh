#!/bin/bash

# Copyright (C) 2021 by CPQD

set -eux -o pipefail

# Pre-requisites

if ! kubectl version --client=true; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    kubectl version --client=true
fi

if ! kind version; then
    wget https://github.com/kubernetes-sigs/kind/releases/download/v0.11.1/kind-linux-amd64
    sudo install -o root -g root -m 0755 kind-linux-amd64 /usr/local/bin/kind
    kind version
fi

if ! helm version; then
    curl https://baltocdn.com/helm/signing.asc | sudo apt-key add -
    sudo apt-get install apt-transport-https --yes
    echo "deb https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
    sudo apt-get update
    sudo apt-get install -y helm
    helm version
fi

if ! jq --version; then
    sudo apt-get install -y jq
    jq --version
fi

# kind

kind create cluster --config - <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "loadbalancer=enabled"
    extraMounts:
      - hostPath: /tmp/local-path-provisioner
        containerPath: /var/local-path-provisioner
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP

  - role: worker
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "workloads=enabled"
    extraMounts:
      - hostPath: /tmp/local-path-provisioner
        containerPath: /var/local-path-provisioner

  - role: worker
    kubeadmConfigPatches:
    - |
      kind: JoinConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "workloads=enabled"
    extraMounts:
      - hostPath: /tmp/local-path-provisioner
        containerPath: /var/local-path-provisioner

networking:
  apiServerPort: 6443
  disableDefaultCNI: true

EOF

# metallb

kubectl apply --filename "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 -w0)"

docker network inspect kind | jq -r '.[].IPAM.Config[0].Subnet'

helm repo add metallb https://metallb.github.io/metallb

helm upgrade --install metallb metallb/metallb \
  --version 0.11.0 \
  --create-namespace \
  --namespace metallb-system \
  --set "configInline.address-pools[0].addresses[0]="172.18.0.10-172.18.0.20"" \
  --set "configInline.address-pools[0].name=default" \
  --set "configInline.address-pools[0].protocol=layer2" \
  --set controller.nodeSelector.loadbalancer=enabled \
  --set "controller.tolerations[0].key=node-role.kubernetes.io/master" \
  --set "controller.tolerations[0].effect=NoSchedule" \
  --set speaker.tolerateMaster=true \
  --set speaker.nodeSelector.loadbalancer=enabled
kubectl wait --for condition=Available=True deploy/metallb-controller --namespace metallb-system --timeout -1s
kubectl wait --for condition=ready pod --selector app.kubernetes.io/component=controller --namespace metallb-system --timeout -1s

# metrics-server

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

helm install metrics-server metrics-server/metrics-server \
  --version 3.7.0 \
  --namespace kube-system \
  --set rbac.create=true \
  --set args={"--kubelet-insecure-tls"} \
  --set apiService.create=true
kubectl wait --for condition=Available=True deploy/metrics-server --namespace kube-system --timeout -1s

sleep 5

kubectl top nodes

kubectl top pods --all-namespaces

# dashboard

kubectl apply --filename https://raw.githubusercontent.com/kubernetes/dashboard/v2.4.0/aio/deploy/recommended.yaml

kubectl create -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard

---

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

kubectl --namespace kubernetes-dashboard describe secret $(kubectl --namespace kubernetes-dashboard get secret | awk '/admin-user/ {print $1}')

echo 'Run "kubectl proxy" !'

# nginx-ingress-controller

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version 4.0.9 \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.nodeSelector.loadbalancer=enabled \
  --set "controller.tolerations[0].key=node-role.kubernetes.io/master" \
  --set "controller.tolerations[0].effect=NoSchedule" \
  --set podLabels.loadbalancer=enabled \
  --set "service.annotations.metallb.universe.tf/address-pool=default" \
  --set defaultBackend.enabled=true \
  --set defaultBackend.image.repository=rafaelperoco/default-backend,defaultBackend.image.tag=1.0.0
kubectl wait --for condition=Available=True deploy/ingress-nginx-controller --namespace ingress-nginx --timeout -1s

kubectl get service --namespace ingress-nginx ingress-nginx-controller

