#!/bin/bash
set -e

echo "[*] Updating packages..."
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl gpg

echo "[*] Installing containerd..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y containerd.io

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[*] Installing Kubernetes tools..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "[*] Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "[*] Loading kernel modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[*] Initializing kubeadm..."
sudo kubeadm init --pod-network-cidr=10.10.0.0/16 --node-name=kube-node-1

echo "[*] Configuring kubectl..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl taint nodes --all node-role.kubernetes.io/control-plane-

echo "[*] Installing Calico operator..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

echo "[*] Waiting for tigera-operator to be ready..."
kubectl wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=300s

echo "[*] Configuring Calico installation..."
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.10.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF

echo "[*] Waiting for Installation to be processed..."
kubectl wait --for=condition=Ready installation/default --timeout=600s

echo "[*] Waiting for Calico pods to be ready..."
kubectl wait --for=condition=Ready --timeout=600s -n calico-system -l k8s-app=calico-node pod
kubectl wait --for=condition=Ready --timeout=600s -n calico-system -l k8s-app=calico-kube-controllers pod

echo "[*] Installing Helm..."
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

echo "[*] Verifying cluster status..."
kubectl get nodes
kubectl get pods -A

echo "[*] Installing ingress-nginx with Helm..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install nginx-ingress ingress-nginx/ingress-nginx \
  --namespace default \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.controllerValue="k8s.io/ingress-nginx" \
  --set controller.ingressClassResource.enabled=true \
  --set controller.ingressClass=nginx \
  --set controller.service.type=NodePort

echo "[*] Waiting for ingress controller to be ready..."
kubectl wait --for=condition=Ready --timeout=300s -n default -l app.kubernetes.io/name=ingress-nginx pod

kubectl get pods -n default
kubectl get svc -n default
kubectl get ingressclass

echo "[*] Done! Kubernetes cluster is ready."
