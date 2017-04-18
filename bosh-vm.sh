#/bin/bash
set -ex

# run from root
export HOME=/root
cd $HOME
concourse-manifest/concourse-creds.yml=concourse-manifest/concourse-creds.yml

bosh_cli_url="http://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.1-linux-amd64"
curl -L $bosh_cli_url > bosh-cli
chmod +x bosh-cli

DIRECTOR_FLOATING_IP=$(./bosh-cli int bosh-manifest/bosh-creds.yml --path /external_ip)
PRIVATE_CIDR=$(./bosh-cli int bosh-manifest/bosh-creds.yml --path /internal_cidr)
PRIVATE_GATEWAY_IP=$(./bosh-cli int bosh-manifest/bosh-creds.yml --path /internal_gw)
PRIVATE_IP=$(./bosh-cli int bosh-manifest/bosh-creds.yml --path /internal_ip)
NETWORK_UUID=$(./bosh-cli int bosh-manifest/bosh-creds.yml --path /net_id)
OPENSTACK_IP=172.18.161.6
DNS_IP=10.0.0.2
proxy_ip="172.18.161.5"
network_interface=ens7
stemcell_url="http://s3.amazonaws.com/bosh-core-stemcells/openstack/bosh-stemcell-3363.9-openstack-kvm-ubuntu-trusty-go_agent.tgz"
stemcell_sha1=1cddb531c96cc4022920b169a37eda71069c87dd

export http_proxy="http://$proxy_ip:8123"
export https_proxy="http://$proxy_ip:8123"
export no_proxy="127.0.0.1,localhost,$OPENSTACK_IP,$proxy_ip,$PRIVATE_IP,$DIRECTOR_FLOATING_IP,$PRIVATE_GATEWAY_IP,$DNS_IP"

cat > bosh-stemcells.yml <<EOF
- type: replace
  path: /resource_pools/name=vms/stemcell?
  value:
    url: $stemcell_url
    sha1: $stemcell_sha1
EOF

cat > bosh-env.yml <<EOF
- type: replace
  path: /instance_groups/name=bosh/properties/env?
  value:
    http_proxy: $http_proxy
    https_proxy: $https_proxy
    no_proxy: $no_proxy
EOF

cat > cloud-config.yml <<EOF
azs:
- name: z1
  cloud_properties:
    availability_zone: nova

vm_type_defaults: &vm_type_defaults
  az: z1
  cloud_properties:
    instance_type: m1.small

vm_types:
- name: default
  <<: *vm_type_defaults
- name: web
  <<: *vm_type_defaults
- name: database
  <<: *vm_type_defaults
- name: worker
  <<: *vm_type_defaults

disk_types:
- name: default
  disk_size: 2_000
- name: database
  disk_size: 2_000

networks:
- name: private
  type: manual
  subnets:
  - range: $PRIVATE_CIDR
    gateway: $PRIVATE_GATEWAY_IP
    reserved: $DNS_IP
    cloud_properties:
      net_id: $NETWORK_UUID
      security_groups: [bosh]
    az: z1
- name: public
  type: vip
  az: z1

compilation:
  workers: 3
  reuse_compilation_vms: true
  network: private
  <<: *vm_type_defaults
EOF

cat > concourse-groundcrew-properties.yml <<EOF
- type: replace
  path: /instance_groups/name=worker/jobs/name=groundcrew/properties?
  value:
    http_proxy_url: $http_proxy
    https_proxy_url: $https_proxy
    no_proxy: [$no_proxy]
EOF

# set up bosh network interface
cat > /etc/network/interfaces.d/bosh.cfg <<EOF
auto $network_interface
iface $network_interface inet dhcp
EOF

# bring interface up, if not already
ifup $network_interface

DEBIAN_FRONTEND=noninteractive sudo apt-get -qqy update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qqy \
  build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev libreadline6 libreadline6-dev libyaml-dev libsqlite3-dev sqlite3

sudo route add $DIRECTOR_FLOATING_IP gw $OPENSTACK_IP || true
sudo route add -net $PRIVATE_CIDR gw $OPENSTACK_IP || true

git clone https://github.com/cloudfoundry/bosh-deployment.git

./bosh-cli create-env bosh-deployment/bosh.yml \
  --state bosh-deployment-state.json \
  -o bosh-deployment/openstack/cpi.yml \
  -o bosh-deployment/openstack/keystone-v2.yml \
  -o bosh-deployment/external-ip-not-recommended.yml \
  -o bosh-manifest/bosh-releases.yml \
  -o bosh-stemcells.yml \
  -o bosh-manifest/bosh-disk-pools.yml \
  -o bosh-env.yml \
  --vars-store bosh-manifest/bosh-creds.yml \
  --tty \
  ;

./bosh-cli interpolate bosh-manifest/bosh-creds.yml --path /director_ssl/ca > director.pem
./bosh-cli alias-env --ca-cert director.pem -e $DIRECTOR_FLOATING_IP bosh
./bosh-cli log-in -e bosh --client admin --client-secret admin
./bosh-cli update-cloud-config -e bosh --non-interactive cloud-config.yml
./bosh-cli upload-stemcell -e bosh $stemcell_url
./bosh-cli deploy -e bosh -d bosh-concourse bosh-manifest/bosh-concourse-deployment.yml \
  -o concourse-groundcrew-properties.yml \
  --vars-store concourse-manifest/concourse-creds.yml \
  -n \
  ;
