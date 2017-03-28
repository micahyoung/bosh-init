#/bin/bash
set -ex

# run from root
export HOME=/root
cd $HOME

host_ip="172.18.161.6"
proxy_ip="172.18.161.5"
network_interface=ens7
bosh_cli_url="http://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.1-linux-amd64"
director_host=bosh-director
stemcell_url="http://s3.amazonaws.com/bosh-core-stemcells/openstack/bosh-stemcell-3363.9-openstack-kvm-ubuntu-trusty-go_agent.tgz"

PRIVATE_CIDR=10.0.0.0/24
PRIVATE_GATEWAY_IP=10.0.0.1
DNS_IP=10.0.0.2
NETWORK_UUID='6db713e0-b17b-4bf8-ae44-80e02992a74d' #update
OPENSTACK_IP=172.18.161.6
PRIVATE_IP=10.0.0.3
FLOATING_IP=172.18.161.252
IDENTITY_API_ENDPOINT=http://172.18.161.6:5000/v2.0
OPENSTACK_PROJECT=demo
OPENSTACK_DOMAIN=nova
OPENSTACK_USERNAME=admin
OPENSTACK_PASSWORD=password
OPENSTACK_TENANT=demo

export http_proxy="http://$proxy_ip:8123"
export https_proxy="http://$proxy_ip:8123"
export no_proxy="127.0.0.1,localhost,$host_ip,$proxy_ip,$director_host,$PRIVATE_IP,$FLOATING_IP"

# set up bosh network interface
cat > /etc/network/interfaces.d/bosh.cfg <<EOF
auto $network_interface
iface $network_interface inet dhcp
EOF

# bring interface up, if not already
ifup $network_interface

curl -L $bosh_cli_url > bosh-cli
chmod +x bosh-cli

DEBIAN_FRONTEND=noninteractive sudo apt-get -qqy update
DEBIAN_FRONTEND=noninteractive sudo apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -qqy \
  build-essential zlibc zlib1g-dev ruby ruby-dev openssl libxslt-dev libxml2-dev libssl-dev libreadline6 libreadline6-dev libyaml-dev libsqlite3-dev sqlite3


cat > bosh-init.yml <<EOF
---
name: bosh

releases:
- name: bosh
  url: https://bosh.io/d/github.com/cloudfoundry/bosh?v=261.2
  sha1: d4635b4b82b0dc5fd083b83eb7e7405832f6654b
- name: bosh-openstack-cpi
  url: https://bosh.io/d/github.com/cloudfoundry-incubator/bosh-openstack-cpi-release?v=30
  sha1: 2fff8e1c241a91267ddd099a553c1339d2709821

resource_pools:
- name: vms
  network: private
  stemcell:
    url: $stemcell_url
    sha1: 1cddb531c96cc4022920b169a37eda71069c87dd
  cloud_properties:
    instance_type: m1.medium

disk_pools:
- name: disks
  disk_size: 15_000

networks:
- name: private
  type: manual
  subnets:
  - range: $PRIVATE_CIDR # <--- Replace with a private subnet CIDR
    gateway: $PRIVATE_GATEWAY_IP # <--- Replace with a private subnet's gateway
    dns: [$DNS_IP] # <--- Replace with your DNS
    reserved: [$DNS_IP]
    cloud_properties: {net_id: $NETWORK_UUID} # <--- # Replace with private network UUID
- name: public
  type: vip

jobs:
- name: bosh
  instances: 1

  templates:
  - {name: nats, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: registry, release: bosh}
  - {name: openstack_cpi, release: bosh-openstack-cpi}

  resource_pool: vms
  persistent_disk_pool: disks

  networks:
  - name: private
    static_ips: [$PRIVATE_IP] # <--- Replace with a private IP
    default: [dns, gateway]
  - name: public
    static_ips: [$FLOATING_IP] # <--- Replace with a floating IP

  properties:
    env:
      http_proxy: $http_proxy
      https_proxy: $https_proxy
      no_proxy: $no_proxy

    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password # <--- Uncomment & change

    postgres: &db
      listen_address: 127.0.0.1
      host: 127.0.0.1
      user: postgres
      password: postgres-password # <--- Uncomment & change
      database: bosh
      adapter: postgres

    registry:
      address: $PRIVATE_IP # <--- Replace with a private IP
      host: $PRIVATE_IP # <--- Replace with a private IP
      db: *db
      http:
        user: admin
        password: admin # <--- Uncomment & change
        port: 25777
      username: admin
      password: admin # <--- Uncomment & change
      port: 25777

    blobstore:
      address: $PRIVATE_IP # <--- Replace with a private IP
      port: 25250
      provider: dav
      director:
        user: director
        password: director-password # <--- Uncomment & change
      agent:
        user: agent
        password: agent-password # <--- Uncomment & change

    director:
      address: 127.0.0.1
      name: my-bosh
      db: *db
      cpi_job: openstack_cpi
      max_threads: 3
      user_management:
        provider: local
        local:
          users:
          - {name: admin, password: admin} # <--- Uncomment & change
          - {name: hm, password: hm-password} # <--- Uncomment & change

    hm:
      director_account:
        user: hm
        password: hm-password # <--- Uncomment & change
      resurrector_enabled: true

    openstack: &openstack
      auth_url: $IDENTITY_API_ENDPOINT # <--- Replace with OpenStack Identity API endpoint
      project: $OPENSTACK_PROJECT # <--- Replace with OpenStack project name
      domain: $OPENSTACK_DOMAIN # <--- Replace with OpenStack domain name
      username: $OPENSTACK_USERNAME # <--- Replace with OpenStack username
      api_key: $OPENSTACK_PASSWORD # <--- Replace with OpenStack password
      tenant: $OPENSTACK_TENANT
      default_key_name: bosh
      default_security_groups: [bosh]

    agent: {mbus: "nats://nats:nats-password@$PRIVATE_IP:4222"} # <--- Uncomment & change

    ntp: &ntp [0.pool.ntp.org, 1.pool.ntp.org]

cloud_provider:
  template: {name: openstack_cpi, release: bosh-openstack-cpi}

  ssh_tunnel:
    host: $FLOATING_IP # <--- Replace with a floating IP
    port: 22
    user: vcap
    private_key: ./bosh.pem

  mbus: "https://mbus:mbus-password@$FLOATING_IP:6868" # <--- Uncomment & change

  properties:
    openstack: *openstack
    agent: {mbus: "https://mbus:mbus-password@0.0.0.0:6868"} # <--- Uncomment & change
    blobstore: {provider: local, path: /var/vcap/micro_bosh/data/cache}
    ntp: *ntp
EOF

cat > cloud-config.yml <<EOF
azs:
- name: z1
  cloud_properties:
    availability_zone: nova

vm_type_defaults: &vm_type_defaults
  az: z1
  cloud_properties:
    instance_type: m1.feather

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
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    reserved: 10.0.0.2
    cloud_properties:
      net_id: $NETWORK_UUID
      security_groups: [bosh]
    az: z1
- name: public
  type: vip
  az: z1

compilation:
  workers: 2
  reuse_compilation_vms: true
  network: private
  <<: *vm_type_defaults
EOF

cat > bosh.pem <<EOF
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA44kTjqdgpX4jdP/ZPpXv4zKh0yNP2pIIIAmdoQ3/WhoTRWlc
HZ1P8qyrQiKG2L+iz1/7sEAcF1IFkOXs5X33u/UVibOzkGBLDfGjkpanAan2qdH9
itLEKVPY2LyblHTsP6c6RwBqOchZVvKAkiZHvw1NyxqiZMPwlTgqtaaIXM1YGIgY
mtFJ+JfQnHk9tm29mcTH8tuo8NFbV+HAtlLVcn1yPcY2qm8xQicEHCHvBAqJtHu0
SxdGoJQkrPoMKEYPxyuzY5xTy1S9ArgeGgQ/geni7SNC8QdYsXLJ0Yv1F3ixSn7P
o8MrFBIHDdR+aWPDf1+OMjUPjpDF2f+z8KR/3QIDAQABAoIBAQCzX6/kSP0+2eb3
6G6KEUew84xxV6gvJepz30C947wHewDwOnQdAJQzOn40P+XQX5rpIsDXHGNI2yd6
KFiOPrUbHsXg7aLEUbU5g+IwwMVd4XCMRfg8BZYRAoGzs1RvP5GzSJD/wkr7zH7p
tXk4PidXbRSD5jZZe8Jg0IuS8nsTtG2Tk6xRZzC6gMbLpIt0sD7EaUTblKXJoJ7s
X2GI5tK/pQ06fWuLtdkXWiXe01HSyjUQ0mUsP8Msf61TLWNpEyElpQlNZJg4R9uN
JbmeiDQQngajGy/Gs7G1ODmDgb/xXd/0DP8ap+zQBgwLswTQOyUfzjl98l/584/r
siO1G0CdAoGBAPGDi0X6OiUoJjWh414NA9Yi9mSCRPbZbuoPtw4V6admVviYwLOf
6DOEDMRmp4r1JihcpByL9UiE2FHNmecJIZo4vq+3tRxvAaoJ+qvK0LW70ANJQg+J
SBm/nQdIrja/befKjGdapT6ZJR7Ysk9W1pH5Z/0B1XBvW/Sl9pGCYzmHAoGBAPEu
5MB8lv6Xx+Zw/5F5xx7LFemaIkGfFcaqnbvEZbF7P09s41oY6igTvRQ0QrzwvaSN
dn6gZG1YxSUbP4xRLiZr0v0Mq3xUc1yZEo9HrPFN8SCcBFjhZlxv72IuWheJy9KF
8VTUPP1Ay0g3hD2iS9cYRsqIRVm9imaLrzG+0ER7AoGBAJdjxtTJotMR1Mm/vd+B
twrvBZZBVmuKJo2P5kZtE/b8Hr5cOkcekJZiSwJ9+r4PJ6kbUUAXt1yK8XJtt/Br
9+VNdrJ9LIkzSE7HTJuNWcDhhuXYcRF+E3UYeJ1NQO9Old07SUGsP3L62pr4aOV0
4LHGLhoZoSqGk5TKx8G0gvBXAoGAI7zOGpObkCgPb98Ij5ba4X44RgAX2V9oS6LW
co88flsD25IH8j7E26FpIAhKZ1LI1ww7JbJAj09bDw+FkBYrX3gUsHhjJK4i1fK8
pEx7nNnuw+U6Y60qjMHtV8AEi35YnF5Kj0ZPrzsdpBrN1pAo6rtnKfWdSRnj2yQR
lq5uj+cCgYBS6dj/noYalrb8izifVX/YcDpHX/ppexnD3dGIRx/ZUDoQzRtcKESO
X5xdkeyISESEgpY9Qf+V7wy/YS4V9schYbXMnRulP5xCuxmhjm1bTw3w6yc3RCzG
4WeUesbrO/5ffHteVU01BGN8DLF3LjfwojBGheV8Y4pM1KtIKdfJyg==
-----END RSA PRIVATE KEY-----
EOF

chmod 600 bosh.pem

sudo route add $FLOATING_IP gw $OPENSTACK_IP || true
sudo route add -net $PRIVATE_CIDR gw $OPENSTACK_IP || true

./bosh-cli create-env --tty bosh-init.yml

scp -i bosh.pem -o StrictHostKeyChecking=no vcap@$FLOATING_IP:/var/vcap/store/director/nginx/director.pem .
echo $FLOATING_IP $director_host | sudo tee -a /etc/hosts
./bosh-cli alias-env --ca-cert director.pem -e $director_host bosh
./bosh-cli log-in -e bosh --client admin --client-secret admin
./bosh-cli update-cloud-config -e bosh --non-interactive cloud-config.yml
./bosh-cli upload-stemcell -e bosh $stemcell_url
