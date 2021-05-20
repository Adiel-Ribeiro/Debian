############################ This script deploys Kubernetes Nodes #####################################
#!/bin/bash
#############################################################################################################
################# iptables bridge traffic ###################################################################
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system
#############################################################################################################
################ Container Runtime Interface ################################################################
################ install docker #############################################################################
sudo apt-get update -y
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
curl -fsSL https://download.docker.com/linux/debian/gpg | \
sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg --batch
echo \
  "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo chmod 644 /usr/share/keyrings/*
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
################### configure docker #########################################################################
sudo mkdir /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
################################## restart docker and enable on boot ##########################################
sudo systemctl enable docker
sudo systemctl daemon-reload
sudo systemctl restart docker
################################################################################################################
################################### kubeadm kubelet and kubectl ################################################
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg \
https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] \
https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /usr/share/keyrings/*
sleep 10
sudo apt-get update -y 
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
############################################################################################################################
######################################### calico ##########################################################################
sudo curl -L -o /opt/cni/bin/calico https://github.com/projectcalico/cni-plugin/releases/download/v3.14.0/calico-amd64
sudo chmod 755 /opt/cni/bin/calico
sudo curl -L -o /opt/cni/bin/calico-ipam https://github.com/projectcalico/cni-plugin/releases/download/v3.14.0/calico-ipam-amd64
sudo chmod 755 /opt/cni/bin/calico-ipam
###############################################################################################################################
sudo mkdir -p /etc/cni/net.d/
######################################## copy kube config from an already running nfs server ##################################
sudo apt-get install -y nfs-common
cd $HOME
mkdir efs 
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 10.0.0.5:/ efs
sudo cp efs/cni.kubeconfig /etc/cni/net.d/calico-kubeconfig
############################################################################################################################
sudo chmod 750 /etc/cni/ && sudo chown root:admin /etc/cni/
sudo chmod 750 /etc/cni/net.d && sudo chown root:admin /etc/cni/net.d/
sudo chown root:admin /etc/cni/net.d/calico-kubeconfig && sudo chmod 640 /etc/cni/net.d/calico-kubeconfig
###########################################################################################################################
cat > /etc/cni/net.d/10-calico.conflist <<EOF
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "log_level": "info",
      "datastore_type": "kubernetes",
      "mtu": 1500,
      "ipam": {
          "type": "calico-ipam"
      },
      "policy": {
          "type": "k8s"
      },
      "kubernetes": {
          "kubeconfig": "/etc/cni/net.d/calico-kubeconfig"
      }
    },
    {
      "type": "portmap",
      "snat": true,
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF
############################################################################################################################
sudo reboot 
###########################################################################################################################