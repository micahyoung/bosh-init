#!/bin/bash

dom_name=bosh-0
if virsh list --all | grep $dom_name; then
  virsh start $dom_name
else
  network_uuid=${1:?"Net UUID required"}

cat > bosh-uvt.sh <<EOF
cat << EOF2 | base64 -d  | tar xJ > bosh-vm.sh
$(tar cJ bosh-vm.sh | base64 -w0)
EOF2
./bosh-vm.sh $(echo $network_uuid)
EOF

  uvt-kvm create --cpu=1 --memory=1024 --disk=10 --run-script-once=bosh-uvt.sh $dom_name release=xenial arch=amd64
fi

while ! uvt-kvm ip $dom_name; do sleep 1; done
virsh attach-interface $dom_name network bosh --mac de:ad:be:ef:00:00 --model virtio
