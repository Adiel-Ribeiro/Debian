################# kubernetes deploy #########################################################################
# Owner: Adiel Ribeiro 
# Date: 2021/05/28
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
net.bridge.bridge-nf-call-iptables = 1
EOF
sudo sysctl --system
#############################################################################################################
sudo bash -c "echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf"
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
############################################################################################################################
######################################## nfs server #######################################################################
sudo apt-get install -y nfs-common
mkdir $HOME/efs 
cd $HOME
############################################################################################################################
cat <<EOF | tee start.bash
#!/bin/bash
sudo mount 10.0.0.5:/ efs
sudo chown -R admin /var/lib/cni
sudo chown -R admin /var/log/containers/ /var/log/pods/ /var/log/aws-routed-eni/
sudo chown -R admin efs
sudo chown -R admin /var/lib/calico
EOF
##########################################################################################################################
chmod +x start.bash
################################# cron #################################################################################
echo "@reboot /home/admin/mount.bash" > $HOME/cron
cat $HOME/cron | crontab -u admin -
#######################################################################################################################
#################################### calico node ####################################################################
mkdir $HOME/calico-node && cd $HOME/calico-node
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
            # Wait for the datastore.
            - name: WAIT_FOR_DATASTORE
              value: "true"
            # Set based on the k8s node name.
            - name: NODENAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            # Choose the backend to use.
            - name: CALICO_NETWORKING_BACKEND
              valueFrom:
                configMapKeyRef:
                  name: calico-config
                  key: calico_backend
            # Enable VXLAN #################################################################################
            - name: CALICO_IPV4POOL_VXLAN
              value: "Always" ###################################################################################
            # Cluster type to identify the deployment type
            - name: CLUSTER_TYPE
              value: "k8s,bgp"
            # Auto-detect the BGP IP address.
            - name: IP
              value: "autodetect"
            # The default IPv4 pool to create on startup if none exists. Pod IPs will be
            # chosen from this range. Changing this value after installation will have
            # no effect. This should fall within `--cluster-cidr`.
            - name: CALICO_IPV4POOL_CIDR
              value: "192.168.0.0/24"
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
        - name: calico-node-certs
          secret:
            secretName: calico-node-certs
EOF
##############################################################################################################################
kubectl apply -f - <<EOF
# See https://github.com/projectcalico/kube-controllers
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calico-kube-controllers
  namespace: kube-system
  labels:
    k8s-app: calico-kube-controllers
spec:
  # The controllers can only have a single active instance.
  replicas: 1
  selector:
    matchLabels:
      k8s-app: calico-kube-controllers
  strategy:
    type: Recreate
  template:
    metadata:
      name: calico-kube-controllers
      namespace: kube-system
      labels:
        k8s-app: calico-kube-controllers
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        # Mark the pod as a critical add-on for rescheduling.
        - key: CriticalAddonsOnly
          operator: Exists
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
      serviceAccountName: calico-kube-controllers
      priorityClassName: system-cluster-critical
{{- if eq .Values.datastore "etcd" }}
      # The controllers must run in the host network namespace so that
      # it isn't governed by policy that would prevent it from working.
      hostNetwork: true
      containers:
        - name: calico-kube-controllers
          image: {{.Values.kubeControllers.image}}:{{ .Values.kubeControllers.tag }}
          env:
            # The location of the etcd cluster.
            - name: ETCD_ENDPOINTS
              valueFrom:
                configMapKeyRef:
                  name: {{include "variant_name" . | lower}}-config
                  key: etcd_endpoints
            # Location of the CA certificate for etcd.
            - name: ETCD_CA_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: {{include "variant_name" . | lower}}-config
                  key: etcd_ca
            # Location of the client key for etcd.
            - name: ETCD_KEY_FILE
              valueFrom:
                configMapKeyRef:
                  name: {{include "variant_name" . | lower}}-config
                  key: etcd_key
            # Location of the client certificate for etcd.
            - name: ETCD_CERT_FILE
              valueFrom:
                configMapKeyRef:
                  name: {{include "variant_name" . | lower}}-config
                  key: etcd_cert
            # Choose which controllers to run.
            - name: ENABLED_CONTROLLERS
              value: policy,namespace,serviceaccount,workloadendpoint,node
{{- if .Values.kubeControllers.env }}
{{ toYaml .Values.kubeControllers.env | indent 12 }}
{{- end }}
          volumeMounts:
            # Mount in the etcd TLS secrets.
            - mountPath: /calico-secrets
              name: etcd-certs
          livenessProbe:
            exec:
              command:
              - /usr/bin/check-status
              - -l
            periodSeconds: 10
            initialDelaySeconds: 10
            failureThreshold: 6
          readinessProbe:
            exec:
              command:
              - /usr/bin/check-status
              - -r
            periodSeconds: 10
      volumes:
        # Mount in the etcd TLS secrets with mode 400.
        # See https://kubernetes.io/docs/concepts/configuration/secret/
        - name: etcd-certs
          secret:
            secretName: calico-etcd-secrets
            defaultMode: 0440
{{- else }}
      containers:
        - name: calico-kube-controllers
          image: {{.Values.kubeControllers.image}}:{{ .Values.kubeControllers.tag }}
          env:
            # Choose which controllers to run.
            - name: ENABLED_CONTROLLERS
              value: node
            - name: DATASTORE_TYPE
              value: kubernetes
          livenessProbe:
            exec:
              command:
              - /usr/bin/check-status
              - -l
            periodSeconds: 10
            initialDelaySeconds: 10
            failureThreshold: 6
          readinessProbe:
            exec:
              command:
              - /usr/bin/check-status
              - -r
            periodSeconds: 10
{{- end }}

---

apiVersion: v1
kind: ServiceAccount
metadata:
  name: calico-kube-controllers
  namespace: kube-system

---

# This manifest creates a Pod Disruption Budget for Controller to allow K8s Cluster Autoscaler to evict

apiVersion: policy/v1beta1
kind: PodDisruptionBudget
metadata:
  name: calico-kube-controllers
  namespace: kube-system
  labels:
    k8s-app: calico-kube-controllers
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      k8s-app: calico-kube-controllers
EOF
#########################################################################################################################
sudo chown -R admin /var/lib/etcd
sudo chown -R admin /var/lib/kubelet
sudo chown -R admin /etc/cni
#########################################################################################################################
#################################### wave network ############################################################
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | \
base64 | tr -d '\n')&env.IPALLOC_RANGE=192.168.0.0/24"
##################################################################################################################
rm $HOME/kubernetes.bash
sudo reboot 
##############################################################################################################################