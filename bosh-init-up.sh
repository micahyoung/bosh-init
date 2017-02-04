#!/bin/bash

dom_name=bosh-init-0
if virsh list --all | grep $dom_name; then
  virsh start $dom_name
else
  uvt-kvm create --cpu=1 --memory=1024 --disk=5 --run-script-once=bosh-init-vm.sh $dom_name release=xenial arch=amd64
fi

while ! uvt-kvm ip $dom_name; do sleep 1; done
virsh attach-interface $dom_name network bosh --mac de:ad:be:ef:00:00 --model virtio
