################# kubernetes deploy #########################################################################
# Name: kubernetes.bash 
# Owner: Adiel Ribeiro 
# Date: 2021/05/31
# Contact: contato@nuvym.com
#          https://www.linkedin.com/company/nuvym-cloud/
#############################################################################################################
# This script deploys Kubernetes Control Plane Server with AWS CNI, Calico policies and Flannel network #####
# It assumes that your already have an EFS running 
# This script also install kubernetes by separate modules, that allows you to modify them easily  
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
########################## iptables forwarding ##############################################################
sudo bash -c "echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf"
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
######################################## nfs server #######################################################################
sudo apt-get install -y nfs-common
rm -rf $HOME/efs
mkdir $HOME/efs
sudo mount 10.0.0.5:/ $HOME/efs
sleep 5
sudo rm -rfv efs/*
sudo chown -R admin $HOME/efs
sudo bash -c "echo 10.0.0.5:/ /home/admin/efs nfs defaults 0 0 >> /etc/fstab"
############################################################################################################################
mkdir $HOME/efs/yaml 
cd $HOME/efs/yaml
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
############ calico datastore ##################################################################################
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
  vxlanMode: Always                                 #################################################
  natOutgoing: true
  disabled: false
  nodeSelector: all()
EOF
##########################################################################################################################
calicoctl create -f pool.yaml
############################################################################################################################
########################################### cluster role #############################################################
cat > cluster-role.yaml <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: calico-node
rules:
  # The CNI plugin needs to get pods, nodes, and namespaces.
  - apiGroups: [""]
    resources:
      - pods
      - nodes
      - namespaces
    verbs:
      - get
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
  # Watch for changes to Kubernetes NetworkPolicies.
  - apiGroups: ["networking.k8s.io"]
    resources:
      - networkpolicies
    verbs:
      - watch
      - list
  # Used by Calico for policy information.
  - apiGroups: [""]
    resources:
      - pods
      - namespaces
      - serviceaccounts
    verbs:
      - list
      - watch
  # The CNI plugin patches pods/status.
  - apiGroups: [""]
    resources:
      - pods/status
    verbs:
      - patch
  # Calico monitors various CRDs for config.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - globalfelixconfigs
      - felixconfigurations
      - bgppeers
      - globalbgpconfigs
      - bgpconfigurations
      - ippools
      - ipamblocks
      - ipamconfigs
      - globalnetworkpolicies
      - globalnetworksets
      - networkpolicies
      - networksets
      - clusterinformations
      - hostendpoints
      - blockaffinities
    verbs:
      - get
      - list
      - watch
  # Calico must create and update some CRDs on startup.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - ippools
      - ipamblocks
      - ipamconfigs
      - blockaffinities
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
  # These permissions are only required for upgrade from v2.6, and can
  # be removed after upgrade or on fresh installations.
  - apiGroups: ["crd.projectcalico.org"]
    resources:
      - bgpconfigurations
      - bgppeers
    verbs:
      - create
      - update
EOF
#########################################################################################################################
kubectl apply -f cluster-role.yaml
#########################################################################################################################
kubectl create serviceaccount -n kube-system calico-node
##########################################################################################################################
kubectl create clusterrolebinding calico-node --clusterrole=calico-node --serviceaccount=kube-system:calico-node
#######################################################################################################################
cat > calico-daemonset.yaml <<EOF
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
            # Enable VXLAN #################################################################################
            - name: CALICO_IPV4POOL_VXLAN
              value: "Always" ###################################################################################
            # Cluster type to identify the deployment type
            - name: CLUSTER_TYPE
              value: "k8s"
            # Enable IPIP
            - name: CALICO_IPV4POOL_IPIP
              value: "Always"
            # The default IPv4 pool to create on startup if none exists. Pod IPs will be
            # chosen from this range. Changing this value after installation will have
            # no effect. This should fall within cluster-cidr.
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
            periodSeconds: 40
            initialDelaySeconds: 40
            failureThreshold: 20
          readinessProbe:
            exec:
              command:
              - /bin/calico-node
              - -felix-ready
            periodSeconds: 40
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
EOF
########################################################################################################################
kubectl apply -f calico-daemonset.yaml
########################################################################################################################
kubectl set env daemonset/calico-node -n kube-system IP_AUTODETECTION_METHOD=interface=eth0
######################################################################################################################
######################### AWS CNI ########################################################################################
cat <<EOF | tee aws-cni.yaml
---
"apiVersion": "rbac.authorization.k8s.io/v1"
"kind": "ClusterRoleBinding"
"metadata":
  "name": "aws-node"
"roleRef":
  "apiGroup": "rbac.authorization.k8s.io"
  "kind": "ClusterRole"
  "name": "aws-node"
"subjects":
- "kind": "ServiceAccount"
  "name": "aws-node"
  "namespace": "kube-system"
---
"apiVersion": "rbac.authorization.k8s.io/v1"
"kind": "ClusterRole"
"metadata":
  "name": "aws-node"
"rules":
- "apiGroups":
  - "crd.k8s.amazonaws.com"
  "resources":
  - "eniconfigs"
  "verbs":
  - "get"
  - "list"
  - "watch"
- "apiGroups":
  - ""
  "resources":
  - "pods"
  - "namespaces"
  "verbs":
  - "list"
  - "watch"
  - "get"
- "apiGroups":
  - ""
  "resources":
  - "nodes"
  "verbs":
  - "list"
  - "watch"
  - "get"
  - "update"
- "apiGroups":
  - "extensions"
  "resources":
  - "*"
  "verbs":
  - "list"
  - "watch"
---
"apiVersion": "apiextensions.k8s.io/v1beta1"
"kind": "CustomResourceDefinition"
"metadata":
  "name": "eniconfigs.crd.k8s.amazonaws.com"
"spec":
  "group": "crd.k8s.amazonaws.com"
  "names":
    "kind": "ENIConfig"
    "plural": "eniconfigs"
    "singular": "eniconfig"
  "scope": "Cluster"
  "versions":
  - "name": "v1alpha1"
    "served": true
    "storage": true
---
"apiVersion": "apps/v1"
"kind": "DaemonSet"
"metadata":
  "labels":
    "k8s-app": "aws-node"
  "name": "aws-node"
  "namespace": "kube-system"
"spec":
  "selector":
    "matchLabels":
      "k8s-app": "aws-node"
  "template":
    "metadata":
      "labels":
        "k8s-app": "aws-node"
    "spec":
      "affinity":
        "nodeAffinity":
          "requiredDuringSchedulingIgnoredDuringExecution":
            "nodeSelectorTerms":
            - "matchExpressions":
              - "key": "beta.kubernetes.io/os"
                "operator": "In"
                "values":
                - "linux"
              - "key": "beta.kubernetes.io/arch"
                "operator": "In"
                "values":
                - "amd64"
                - "arm64"
              - "key": "eks.amazonaws.com/compute-type"
                "operator": "NotIn"
                "values":
                - "fargate"
            - "matchExpressions":
              - "key": "kubernetes.io/os"
                "operator": "In"
                "values":
                - "linux"
              - "key": "kubernetes.io/arch"
                "operator": "In"
                "values":
                - "amd64"
                - "arm64"
              - "key": "eks.amazonaws.com/compute-type"
                "operator": "NotIn"
                "values":
                - "fargate"
      "containers":
      - "env":
        - "name": "ADDITIONAL_ENI_TAGS"
          "value": "{}"
        - "name": "AWS_VPC_CNI_NODE_PORT_SUPPORT"
          "value": "true"
        - "name": "AWS_VPC_ENI_MTU"
          "value": "9001"
        - "name": "AWS_VPC_K8S_CNI_CONFIGURE_RPFILTER"
          "value": "false"
        - "name": "AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG"
          "value": "false"
        - "name": "AWS_VPC_K8S_CNI_EXTERNALSNAT"
          "value": "false"
        - "name": "AWS_VPC_K8S_CNI_LOGLEVEL"
          "value": "DEBUG"
        - "name": "AWS_VPC_K8S_CNI_LOG_FILE"
          "value": "/host/var/log/aws-routed-eni/ipamd.log"
        - "name": "AWS_VPC_K8S_CNI_RANDOMIZESNAT"
          "value": "prng"
        - "name": "AWS_VPC_K8S_CNI_VETHPREFIX"
          "value": "eni"
        - "name": "AWS_VPC_K8S_PLUGIN_LOG_FILE"
          "value": "/var/log/aws-routed-eni/plugin.log"
        - "name": "AWS_VPC_K8S_PLUGIN_LOG_LEVEL"
          "value": "DEBUG"
        - "name": "DISABLE_INTROSPECTION"
          "value": "false"
        - "name": "DISABLE_METRICS"
          "value": "false"
        - "name": "ENABLE_POD_ENI"
          "value": "false"
        - "name": "MY_NODE_NAME"
          "valueFrom":
            "fieldRef":
              "fieldPath": "spec.nodeName"
        - "name": "WARM_ENI_TARGET"
          "value": "1"
        "image": "602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni:v1.7.10"
        "livenessProbe":
          "exec":
            "command":
            - "/app/grpc-health-probe"
            - "-addr=:50051"
          "initialDelaySeconds": 180
        "name": "aws-node"
        "ports":
        - "containerPort": 61678
          "name": "metrics"
        "readinessProbe":
          "exec":
            "command":
            - "/app/grpc-health-probe"
            - "-addr=:50051"
          "initialDelaySeconds": 3
        "resources":
          "requests":
            "cpu": "10m"
        "securityContext":
          "capabilities":
            "add":
            - "NET_ADMIN"
        "volumeMounts":
        - "mountPath": "/host/opt/cni/bin"
          "name": "cni-bin-dir"
        - "mountPath": "/host/etc/cni/net.d"
          "name": "cni-net-dir"
        - "mountPath": "/host/var/log/aws-routed-eni"
          "name": "log-dir"
        - "mountPath": "/var/run/aws-node"
          "name": "run-dir"
        - "mountPath": "/var/run/dockershim.sock"
          "name": "dockershim"
        - "mountPath": "/run/xtables.lock"
          "name": "xtables-lock"
      "hostNetwork": true
      "initContainers":
      - "env":
        - "name": "DISABLE_TCP_EARLY_DEMUX"
          "value": "false"
        "image": "602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon-k8s-cni-init:v1.7.10"
        "name": "aws-vpc-cni-init"
        "securityContext":
          "privileged": true
        "volumeMounts":
        - "mountPath": "/host/opt/cni/bin"
          "name": "cni-bin-dir"
      "priorityClassName": "system-node-critical"
      "serviceAccountName": "aws-node"
      "terminationGracePeriodSeconds": 0
      "tolerations":
      - "operator": "Exists"
      "volumes":
      - "hostPath":
          "path": "/opt/cni/bin"
        "name": "cni-bin-dir"
      - "hostPath":
          "path": "/etc/cni/net.d"
        "name": "cni-net-dir"
      - "hostPath":
          "path": "/var/run/dockershim.sock"
        "name": "dockershim"
      - "hostPath":
          "path": "/run/xtables.lock"
        "name": "xtables-lock"
      - "hostPath":
          "path": "/var/log/aws-routed-eni"
          "type": "DirectoryOrCreate"
        "name": "log-dir"
      - "hostPath":
          "path": "/var/run/aws-node"
          "type": "DirectoryOrCreate"
        "name": "run-dir"
  "updateStrategy":
    "rollingUpdate":
      "maxUnavailable": "10%"
    "type": "RollingUpdate"
---
"apiVersion": "v1"
"kind": "ServiceAccount"
"metadata":
  "name": "aws-node"
  "namespace": "kube-system"
...
EOF
#############################################################################################################################
kubectl apply -f aws-cni.yaml
#############################################################################################################################
#################################### flannel network ############################################################
cat <<EOF | tee flannel.yaml
---
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: psp.flannel.unprivileged
  annotations:
    seccomp.security.alpha.kubernetes.io/allowedProfileNames: docker/default
    seccomp.security.alpha.kubernetes.io/defaultProfileName: docker/default
    apparmor.security.beta.kubernetes.io/allowedProfileNames: runtime/default
    apparmor.security.beta.kubernetes.io/defaultProfileName: runtime/default
spec:
  privileged: false
  volumes:
  - configMap
  - secret
  - emptyDir
  - hostPath
  allowedHostPaths:
  - pathPrefix: "/etc/cni/net.d"
  - pathPrefix: "/etc/kube-flannel"
  - pathPrefix: "/run/flannel"
  readOnlyRootFilesystem: false
  # Users and groups
  runAsUser:
    rule: RunAsAny
  supplementalGroups:
    rule: RunAsAny
  fsGroup:
    rule: RunAsAny
  # Privilege Escalation
  allowPrivilegeEscalation: false
  defaultAllowPrivilegeEscalation: false
  # Capabilities
  allowedCapabilities: ['NET_ADMIN', 'NET_RAW']
  defaultAddCapabilities: []
  requiredDropCapabilities: []
  # Host namespaces
  hostPID: false
  hostIPC: false
  hostNetwork: true
  hostPorts:
  - min: 0
    max: 65535
  # SELinux
  seLinux:
    # SELinux is unused in CaaSP
    rule: 'RunAsAny'
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
rules:
- apiGroups: ['extensions']
  resources: ['podsecuritypolicies']
  verbs: ['use']
  resourceNames: ['psp.flannel.unprivileged']
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flannel
  namespace: kube-system
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-system
  labels:
    tier: node
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "192.168.0.0/24",
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-system
  labels:
    tier: node
    app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni
        image: quay.io/coreos/flannel:v0.14.0
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: quay.io/coreos/flannel:v0.14.0
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
EOF
##################################################################################################################
mkdir $HOME/efs/scripts
cd $HOME/efs/scripts
##################################### startup script ######################################################################
cat <<EOF | tee start.bash
#!/bin/bash
sudo chown -R admin /var/lib/cni
sudo chown -R admin /var/log/containers/ /var/log/pods/ /var/log/aws-routed-eni/
sudo chown -R admin efs
sudo chown -R admin /var/lib/calico
sudo chown -R admin /var/lib/etcd
sudo chown -R admin /var/lib/kubelet
sudo chown -R admin /etc/cni
sudo chown -R admin /etc/kube-flannel
mkdir $HOME/efs/bkp
sudo tar cf $HOME/efs/bkp/etcd.tar /etc/kubernetes/
EOF
##########################################################################################################################
chmod +x start.bash
################################# cron #################################################################################
echo "@reboot $HOME/efs/scripts/start.bash" > $HOME/cron
cat $HOME/cron | crontab -u admin -
#########################################################################################################################
rm $HOME/kubernetes.bash
sudo reboot 
##############################################################################################################################