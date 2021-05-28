################# kubernetes deploy #########################################################################
# Owner: Adiel Ribeiro 
# Date: 2021/27/05
# Contact: contato@nuvym.com
#          https://www.linkedin.com/company/nuvym-cloud/
#############################################################################################################
# This script deploys Control Plane Server with AWS CNI, Calico policies and Weave network ############# 
# Please, adjust it accordingly to your needs!
#############################################################################################################
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
sudo usermod -a -G docker admin
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
################################################################################################################
sudo chown -R admin /etc/apt/sources.list.d/
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sudo bash
sudo chmod 755 /usr/local/bin/helm
###################################### cgroup driver ###########################################################
cat <<EOF | tee kubeadm-config.yaml
kind: ClusterConfiguration
apiVersion: kubeadm.k8s.io/v1beta2
kubernetesVersion: v1.21.0
controlPlaneEndpoint: master
dns:
  type: CoreDNS
networking:
  dnsDomain: kubernetes.cluster
  serviceSubnet: 192.168.1.0/24
  podSubnet: 192.168.0.0/24
apiServer:
  extraArgs:
    advertise-address: 10.0.0.10
controllerManager:
  extraArgs:
    bind-address: 10.0.0.10
---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
################################################################################################################
############### start kubeadm ##################################################################################
sudo kubeadm init --config kubeadm-config.yaml
################################################################################################################
############################ enable debian admin user to manage the cluster ####################################
rm -rf $HOME/.kube
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
################################################################################################################
################################### aws cni ###############################################################################
curl -L -o aws-cni https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/master/config/v1.7/aws-k8s-cni.yaml
kubectl apply -f aws-cni
#######################################################################################################################
############ calico datastore ##################################################################################
mkdir $HOME/calico && cd $HOME/calico 
wget https://docs.projectcalico.org/manifests/crds.yaml
kubectl apply -f crds.yaml
wget https://github.com/projectcalico/calicoctl/releases/download/v3.14.0/calicoctl
chmod +x calicoctl
sudo mv calicoctl /usr/local/bin/
####################################################################################################################
export KUBECONFIG=$HOME/.kube/config
export DATASTORE_TYPE=kubernetes
echo "export KUBECONFIG=$HOME/.kube/config" >> $HOME/.bashrc
echo "export DATASTORE_TYPE=kubernetes" >> $HOME/.bashrc
#########################################################################################################################
######################### ipp pools ####################################################################################
cat > pool.yaml <<EOF
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: pool
spec:
  cidr: 192.168.0.0/24
#  name: IP_AUTODETECTION_METHOD                     #################################################
#              value: "interface=eth0"               #################################################
  vxlanMode: Always                                 #################################################
  natOutgoing: true
  disabled: false
  nodeSelector: all()
EOF
##########################################################################################################################
calicoctl create -f pool.yaml
##########################################################################################################################
###################################### calico CNI ##############################################################
mkdir cni && cd cni
################################################################################################################
openssl req -newkey rsa:4096 \
           -keyout cni.key \
           -nodes \
           -out cni.csr \
           -subj "/CN=calico-cni"
################################################################################################################
sudo openssl x509 -req -in cni.csr \
                  -CA /etc/kubernetes/pki/ca.crt \
                  -CAkey /etc/kubernetes/pki/ca.key \
                  -CAcreateserial \
                  -out cni.crt \
                  -days 1095
################################################################################################################
sudo chown admin cni.crt
sudo chown root:admin /etc/kubernetes/pki/ && sudo chmod 750 /etc/kubernetes/pki/
sudo chown admin /etc/kubernetes/pki/ca.crt
############################## kubeconfig #########################################################################
APISERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')
kubectl config set-cluster kubernetes \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true \
    --server=$APISERVER \
    --kubeconfig=cni.kubeconfig

kubectl config set-credentials calico-cni \
    --client-certificate=cni.crt \
    --client-key=cni.key \
    --embed-certs=true \
    --kubeconfig=cni.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes \
    --user=calico-cni \
    --kubeconfig=cni.kubeconfig

kubectl config use-context default --kubeconfig=cni.kubeconfig
##########################################################################################################################
chmod 600 cni.kubeconfig
################################### calico #######################################################################
##################################################################################################################
kubectl apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: calico-cni
rules:
  # The CNI plugin needs to get pods, nodes, and namespaces.
  - apiGroups: [""]
    resources:
      - pods
      - nodes
      - namespaces
    verbs:
      - get
  # The CNI plugin patches pods/status.
  - apiGroups: [""]
    resources:
      - pods/status
    verbs:
      - patch
 # These permissions are required for Calico CNI to perform IPAM allocations.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - blockaffinities
      - ipamblocks
      - ipamhandles
    verbs:
      - get
      - list
      - create
      - update
      - delete
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - ipamconfigs
      - clusterinformations
      - ippools
    verbs:
      - get
      - list
EOF
####################################################################################################################
kubectl create clusterrolebinding calico-cni --clusterrole=calico-cni --user=calico-cni
####################################################################################################################
sudo curl -L -o /opt/cni/bin/calico https://github.com/projectcalico/cni-plugin/releases/download/v3.14.0/calico-amd64
sudo chmod 755 /opt/cni/bin/calico
sudo curl -L -o /opt/cni/bin/calico-ipam https://github.com/projectcalico/cni-plugin/releases/download/v3.14.0/calico-ipam-amd64
sudo chmod 755 /opt/cni/bin/calico-ipam
###############################################################################################################################
sudo mkdir -p /etc/cni/net.d/
sudo cp cni.kubeconfig /etc/cni/net.d/calico-kubeconfig
############################################################################################################################
sudo chmod 750 /etc/cni/ && sudo chown root:admin /etc/cni/
sudo chmod 770 /etc/cni/net.d && sudo chown root:admin /etc/cni/net.d/
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
sudo chmod 750 /etc/cni/net.d
############################################################################################################################
######################################## copy kube config to an already running nfs server ##################################
sudo apt-get install -y nfs-common
mkdir $HOME/efs 
cd $HOME
############################################################################################################################
cat <<EOF | tee mount.bash
#!/bin/bash
sudo mount 10.0.0.5:/ efs
sudo cp /etc/cni/net.d/calico-kubeconfig $HOME/efs/calico-kubeconfig
sudo chown -R admin /var/lib/cni
sudo chown -R admin /var/log/containers/ /var/log/pods/ /var/log/aws-routed-eni/
EOF
##########################################################################################################################
chmod +x mount.bash
################################# cron #################################################################################
echo "@reboot /home/admin/mount.bash" > $HOME/cron
cat $HOME/cron | crontab -u admin -
############################################### typha #####################################################################
mkdir $HOME/typha && cd $HOME/typha
######################################### cert #################################################################
openssl req -x509 -newkey rsa:4096 \
                  -keyout typhaca.key \
                  -nodes \
                  -out typhaca.crt \
                  -subj "/CN=Calico Typha CA" \
                  -days 1095
######################################### config map ########################################################################
kubectl create configmap -n kube-system calico-typha-ca --from-file=typhaca.crt
##############################################################################################################################
######################## csr ########################################################################################
openssl req -newkey rsa:4096 \
           -keyout typha.key \
           -nodes \
           -out typha.csr \
           -subj "/CN=calico-typha"
###############################################################################################################################
openssl x509 -req -in typha.csr \
                  -CA typhaca.crt \
                  -CAkey typhaca.key \
                  -CAcreateserial \
                  -out typha.crt \
                  -days 1095
##########################################################################################################################
kubectl create secret generic -n kube-system calico-typha-certs --from-file=typha.key --from-file=typha.crt
#########################################################################################################################
########################################## rbac ####################################################################
kubectl create serviceaccount -n kube-system calico-typha
########################################################################################################################
kubectl apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: calico-typha
rules:
  - apiGroups: [""]
    resources:
      - pods
      - namespaces
      - serviceaccounts
      - endpoints
      - services
      - nodes
    verbs:
      # Used to discover service IPs for advertisement.
      - watch
      - list
  - apiGroups: ["networking.k8s.io"]
    resources:
      - networkpolicies
    verbs:
      - watch
      - list
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - globalfelixconfigs
      - felixconfigurations
      - bgppeers
      - globalbgpconfigs
      - bgpconfigurations
      - ippools
      - ipamblocks
      - globalnetworkpolicies
      - globalnetworksets
      - networkpolicies
      - clusterinformations
      - hostendpoints
      - blockaffinities
      - networksets
    verbs:
      - get
      - list
      - watch
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      #- ippools
      #- felixconfigurations
      - clusterinformations
    verbs:
      - get
      - create
      - update
EOF
#########################################################################################################################
kubectl create clusterrolebinding calico-typha --clusterrole=calico-typha --serviceaccount=kube-system:calico-typha
#########################################################################################################################
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calico-typha
  namespace: kube-system
  labels:
    k8s-app: calico-typha
spec:
  replicas: 0 ###############################################################################
  revisionHistoryLimit: 2
  selector:
    matchLabels:
      k8s-app: calico-typha
  template:
    metadata:
      labels:
        k8s-app: calico-typha
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: 'true'
    spec:
      hostNetwork: true
      tolerations:
        # Mark the pod as a critical add-on for rescheduling.
        - key: CriticalAddonsOnly
          operator: Exists
      serviceAccountName: calico-typha
      priorityClassName: system-cluster-critical
      containers:
      - image: calico/typha:v3.8.0
        name: calico-typha
        ports:
        - containerPort: 5473
          name: calico-typha
          protocol: TCP
        env:
          # Disable logging to file and syslog since those don't make sense in Kubernetes.
          - name: TYPHA_LOGFILEPATH
            value: "none"
          - name: TYPHA_LOGSEVERITYSYS
            value: "none"
          # Monitor the Kubernetes API to find the number of running instances and rebalance
          # connections.
          - name: TYPHA_CONNECTIONREBALANCINGMODE
            value: "kubernetes"
          - name: TYPHA_DATASTORETYPE
            value: "kubernetes"
          - name: TYPHA_HEALTHENABLED
            value: "true"
          # Location of the CA bundle Typha uses to authenticate calico/node; volume mount
          - name: TYPHA_CAFILE
            value: /calico-typha-ca/typhaca.crt
          # Common name on the calico/node certificate
          - name: TYPHA_CLIENTCN
            value: calico-node
          # Location of the server certificate for Typha; volume mount
          - name: TYPHA_SERVERCERTFILE
            value: /calico-typha-certs/typha.crt
          # Location of the server certificate key for Typha; volume mount
          - name: TYPHA_SERVERKEYFILE
            value: /calico-typha-certs/typha.key
        livenessProbe:
          httpGet:
            path: /liveness
            port: 9098
            host: localhost
          periodSeconds: 45
          initialDelaySeconds: 45
        readinessProbe:
          httpGet:
            path: /readiness
            port: 9098
            host: localhost
          periodSeconds: 20
        volumeMounts:
        - name: calico-typha-ca
          mountPath: "/calico-typha-ca"
          readOnly: true
        - name: calico-typha-certs
          mountPath: "/calico-typha-certs"
          readOnly: true
      volumes:
      - name: calico-typha-ca
        configMap:
          name: calico-typha-ca
      - name: calico-typha-certs
        secret:
          secretName: calico-typha-certs
EOF
#######################################################################################################################
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: calico-typha
  namespace: kube-system
  labels:
    k8s-app: calico-typha
spec:
  ports:
    - port: 5473
      protocol: TCP
      targetPort: calico-typha
      name: calico-typha
  selector:
    k8s-app: calico-typha
EOF
#######################################################################################################################
#################################### calico node ####################################################################
mkdir $HOME/calico-node && cd $HOME/calico-node
#####################################################################################################################
############################################# cert ###################################################################
openssl req -newkey rsa:4096 \
           -keyout calico-node.key \
           -nodes \
           -out calico-node.csr \
           -subj "/CN=calico-node"
#####################################################################################################################
######################### cert sign in #######################################################################
openssl x509 -req -in calico-node.csr \
                  -CA $HOME/typha/typhaca.crt \
                  -CAkey $HOME/typha/typhaca.key \
                  -CAcreateserial \
                  -out calico-node.crt \
                  -days 1095
########################################################################################################################
kubectl create secret generic -n kube-system calico-node-certs --from-file=calico-node.key --from-file=calico-node.crt
############################################################################################################################
kubectl create serviceaccount -n kube-system calico-node
##########################################################################################################################
kubectl apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: calico-node
rules:
  - apiGroups: [""]
    resources:
      - endpoints
      - services
    verbs:
      # Used to discover service IPs for advertisement.
      - watch
      - list
      # Used to discover Typhas.
      - get
  # Pod CIDR auto-detection on kubeadm needs access to config maps.
  - apiGroups: [""]
    resources:
      - configmaps
    verbs:
      - get
  - apiGroups: [""]
    resources:
      - nodes/status
    verbs:
      # Needed for clearing NodeNetworkUnavailable flag.
      - patch
      # Calico stores some configuration information in node annotations.
      - update
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - globalfelixconfigs
      - felixconfigurations
      - bgppeers
      - globalbgpconfigs
      - bgpconfigurations
      - ippools
      - ipamblocks
      - globalnetworkpolicies
      - globalnetworksets
      - networkpolicies
      - clusterinformations
      - hostendpoints
      - blockaffinities
      - networksets
    verbs:
      - get
      - list
      - watch
  # Calico must create and update some CRDs on startup.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - ippools
      - felixconfigurations
      - clusterinformations
    verbs:
      - create
      - update
  # Calico stores some configuration information on the node.
  - apiGroups: [""]
    resources:
      - nodes
    verbs:
      - get
      - list
      - watch
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - ipamconfigs
    verbs:
      - get
  # Block affinities must also be watchable by confd for route aggregation.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - blockaffinities
    verbs:
      - watch
EOF
#########################################################################################################################
kubectl create clusterrolebinding calico-node --clusterrole=calico-node --serviceaccount=kube-system:calico-node
#######################################################################################################################
kubectl apply -f - <<EOF
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: calico-node
  namespace: kube-system
  labels:
    k8s-app: calico-node
spec:
  selector:
    matchLabels:
      k8s-app: calico-node
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        k8s-app: calico-node
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      hostNetwork: true
      tolerations:
        # Make sure calico-node gets scheduled on all nodes.
        - effect: NoSchedule
          operator: Exists
        # Mark the pod as a critical add-on for rescheduling.
        - key: CriticalAddonsOnly
          operator: Exists
        - effect: NoExecute
          operator: Exists
      serviceAccountName: calico-node
      # Minimize downtime during a rolling upgrade or deletion; tell Kubernetes to do a "force
      # deletion": https://kubernetes.io/docs/concepts/workloads/pods/pod/#termination-of-pods.
      terminationGracePeriodSeconds: 0
      priorityClassName: system-node-critical
      containers:
        # Runs calico-node container on each Kubernetes node.  This
        # container programs network policy and routes on each
        # host.
        - name: calico-node
          image: calico/node:v3.8.0
          env:
            # Use Kubernetes API as the backing datastore.
            - name: DATASTORE_TYPE
              value: "kubernetes"
            - name: FELIX_TYPHAK8SSERVICENAME
              value: calico-typha
            # Wait for the datastore.
            - name: WAIT_FOR_DATASTORE
              value: "true"
            # Set based on the k8s node name.
            - name: NODENAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            # Choose the backend to use. ########################################################################
              data: 
              enable_bgp: false                                 #################################################
            # Typha is disabled. 
              typha_service_name: “none” 
            # value changed from bird to vxlan 
              calico_backend: “vxlan” 
            # Enable VXLAN
            - name: CALICO_IPV4POOL_VXLAN
              value: "Always" ###################################################################################
            # Cluster type to identify the deployment type
            - name: CLUSTER_TYPE
              value: "k8s,bgp"
            # Auto-detect the BGP IP address.
            - name: IP
              value: "autodetect"
            # Disable file logging so kubectl logs works.
            - name: CALICO_DISABLE_FILE_LOGGING
              value: "true"
            # Set Felix endpoint to host default action to ACCEPT.
            - name: FELIX_DEFAULTENDPOINTTOHOSTACTION
              value: "ACCEPT"
            # Disable IPv6 on Kubernetes.
            - name: FELIX_IPV6SUPPORT
              value: "false"
            # Set Felix logging to "info"
            - name: FELIX_LOGSEVERITYSCREEN
              value: "info"
            - name: FELIX_HEALTHENABLED
              value: "true"
            # Location of the CA bundle Felix uses to authenticate Typha; volume mount
            - name: FELIX_TYPHACAFILE
              value: /calico-typha-ca/typhaca.crt
            # Common name on the Typha certificate; used to verify we are talking to an authentic typha
            - name: FELIX_TYPHACN
              value: calico-typha
            # Location of the client certificate for connecting to Typha; volume mount
            - name: FELIX_TYPHACERTFILE
              value: /calico-node-certs/calico-node.crt
            # Location of the client certificate key for connecting to Typha; volume mount
            - name: FELIX_TYPHAKEYFILE
              value: /calico-node-certs/calico-node.key
          securityContext:
            privileged: true
          resources:
            requests:
              cpu: 250m
          livenessProbe:
            httpGet:
              path: /liveness
              port: 9099
              host: localhost
            periodSeconds: 20
            initialDelaySeconds: 20
            failureThreshold: 10
          readinessProbe:
            exec:
              command:
              - /bin/calico-node
#              - -bird-ready ###############################################################################
              - -felix-ready
            periodSeconds: 20
          volumeMounts:
            - mountPath: /lib/modules
              name: lib-modules
              readOnly: true
            - mountPath: /run/xtables.lock
              name: xtables-lock
              readOnly: false
            - mountPath: /var/run/calico
              name: var-run-calico
              readOnly: false
            - mountPath: /var/lib/calico
              name: var-lib-calico
              readOnly: false
            - mountPath: /var/run/nodeagent
              name: policysync
            - mountPath: "/calico-typha-ca"
              name: calico-typha-ca
              readOnly: true
            - mountPath: /calico-node-certs
              name: calico-node-certs
              readOnly: true
      volumes:
        # Used by calico-node.
        - name: lib-modules
          hostPath:
            path: /lib/modules
        - name: var-run-calico
          hostPath:
            path: /var/run/calico
        - name: var-lib-calico
          hostPath:
            path: /var/lib/calico
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
        # Used to create per-pod Unix Domain Sockets
        - name: policysync
          hostPath:
            type: DirectoryOrCreate
            path: /var/run/nodeagent
        - name: calico-typha-ca
          configMap:
            name: calico-typha-ca
        - name: calico-node-certs
          secret:
            secretName: calico-node-certs
EOF
##############################################################################################################################
sudo chown -R admin /var/lib/etcd
sudo chown -R admin /var/lib/kubelet
sudo chown -R admin /etc/cni
sudo chown -R admin efs
#########################################################################################################################
#################################### wave network ############################################################
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | \
base64 | tr -d '\n')&env.IPALLOC_RANGE=192.168.0.0/24"
##################################################################################################################
rm $HOME/kubernetes.bash
sudo reboot 
##############################################################################################################################