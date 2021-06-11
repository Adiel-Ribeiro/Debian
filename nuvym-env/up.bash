#!/bin/bash 
kubectl -n nuvym delete pvc nfs-disk
kubectl delete pv nfs-disk
kubectl delete -f efs/yaml/examples/nfs-nginx-nuvym.yaml
kubectl apply -f efs/yaml/examples/nfs-nuvym-pv.yaml
kubectl apply -f efs/yaml/examples/nfs-nuvym-pv-claim.yaml
kubectl apply -f efs/yaml/examples/nfs-nginx-nuvym.yaml
kubectl -n nuvym exec -it `kubectl -n nuvym get pod | awk '{print $1}' | awk 'NR==2'` -- bash
exit 0