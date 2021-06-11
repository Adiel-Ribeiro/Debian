#!/bin/bash 
kubectl -n nuvym delete pvc nfs-disk
kubectl delete pv nfs-disk
kubectl delete -f efs/yaml/examples/nfs-nginx-nuvym.yaml
exit 0