#/bin/bash
set -ex

network_uuid=${1:?"Net UUID required"}

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
NETWORK_UUID=$network_uuid
OPENSTACK_IP=172.18.161.6
PRIVATE_IP=10.0.0.3
DIRECTOR_FLOATING_IP=172.18.161.254
IDENTITY_API_ENDPOINT=http://172.18.161.6:5000/v2.0
OPENSTACK_PROJECT=demo
OPENSTACK_DOMAIN=nova
OPENSTACK_USERNAME=admin
OPENSTACK_PASSWORD=password
OPENSTACK_TENANT=demo

CONCOURSE_FLOATING_IP=172.18.161.253
CONCOURSE_EXTERNAL_URL=http://ci.foo.com

export http_proxy="http://$proxy_ip:8123"
export https_proxy="http://$proxy_ip:8123"
export no_proxy="127.0.0.1,localhost,$host_ip,$proxy_ip,$director_host,$PRIVATE_IP,$DIRECTOR_FLOATING_IP,$PRIVATE_GATEWAY_IP,$DNS_IP"

cat > bosh-init.yml <<EOF
cloud_provider:
  mbus: "https://mbus:mbus-password@$DIRECTOR_FLOATING_IP:6868" # <--- Uncomment & change

  properties:
    agent:
      mbus: "https://mbus:mbus-password@0.0.0.0:6868"
    blobstore:
      path: /var/vcap/micro_bosh/data/cache
      provider: local
    ntp: &ntp
    - time1.google.com
    - time2.google.com
    - time3.google.com
    - time4.google.com
    openstack: &openstack
      api_key: $OPENSTACK_PASSWORD
      auth_url: $IDENTITY_API_ENDPOINT
      default_key_name: bosh
      default_security_groups:
      - bosh
      domain: $OPENSTACK_DOMAIN
      project: $OPENSTACK_PROJECT
      region: RegionOne
      tenant: $OPENSTACK_TENANT
      username: $OPENSTACK_USERNAME
  ssh_tunnel:
    host: $DIRECTOR_FLOATING_IP
    port: 22
    private_key: ./bosh.pem
    user: vcap
  template:
    name: openstack_cpi
    release: bosh-openstack-cpi
disk_pools:
- disk_size: 15_000
  name: disks
jobs:
- instances: 1
  templates:
  - name: nats
    release: bosh
  - name: postgres
    release: bosh
  - name: blobstore
    release: bosh
  - name: director
    release: bosh
  - name: health_monitor
    release: bosh
  - name: registry
    release: bosh
  - name: openstack_cpi
    release: bosh-openstack-cpi
  name: bosh
  networks:
  - default:
    - dns
    - gateway
    name: private
    static_ips:
    - $PRIVATE_IP
  - name: public
    static_ips:
    - $DIRECTOR_FLOATING_IP
  persistent_disk_pool: disks
  properties:
    agent:
      mbus: "nats://nats:nats-password@$PRIVATE_IP:4222"
    blobstore:
      address: $PRIVATE_IP
      agent:
        password: agent-password
        user: agent
      director:
        password: director-password
        user: director
      port: 25250
      provider: dav
    director:
      address: 127.0.0.1
      cpi_job: openstack_cpi
      db: *db
      max_threads: 3
      name: my-bosh
      user_management:
        local:
          users:
          - name: admin
            password: admin
          - name: hm
            password: hm-password
        provider: local
    env:
      http_proxy: $http_proxy
      https_proxy: $https_proxy
      no_proxy: $no_proxy
    hm:
      director_account:
        password: hm-password
        user: hm
      resurrector_enabled: true
    nats:
      address: 127.0.0.1
      password: nats-password
      user: nats
    ntp: *ntp
    openstack: *openstack
    postgres: &db
      adapter: postgres
      database: bosh
      host: 127.0.0.1
      listen_address: 127.0.0.1
      password: postgres-password
      user: postgres
    registry:
      address: $PRIVATE_IP
      db: *db
      host: $PRIVATE_IP
      http:
        user: admin
        password: admin
        port: 25777
      password: admin
      port: 25777
      username: admin

  resource_pool: vms
name: bosh
networks:
- name: private
  subnets:
  - cloud_properties:
      net_id: $NETWORK_UUID
    dns:
    - $DNS_IP
    gateway: $PRIVATE_GATEWAY_IP
    range: $PRIVATE_CIDR
    reserved:
    - $DNS_IP
  type: manual
- name: public
  type: vip
releases:
- name: bosh
  url: https://bosh.io/d/github.com/cloudfoundry/bosh?v=261.2
  sha1: d4635b4b82b0dc5fd083b83eb7e7405832f6654b
- name: bosh-openstack-cpi
  url: https://bosh.io/d/github.com/cloudfoundry-incubator/bosh-openstack-cpi-release?v=30
  sha1: 2fff8e1c241a91267ddd099a553c1339d2709821
resource_pools:
- cloud_properties:
    instance_type: m1.director
  name: vms
  network: private
  stemcell:
    url: $stemcell_url
    sha1: 1cddb531c96cc4022920b169a37eda71069c87dd
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
  workers: 3
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

cat > bosh-concourse-deployment.yml <<EOF
---
name: bosh-concourse

releases:
- name: concourse
  url: https://bosh.io/d/github.com/concourse/concourse?v=2.7.0
  sha1: 826932f631d0941b3e4cc9cb19e0017c7f989b56
  version: 2.7.0
- name: garden-runc
  url: https://bosh.io/d/github.com/cloudfoundry/garden-runc-release?v=1.3.0
  sha1: 816044289381e3b7b66dd73fbcb20005594026a3
  version: 1.3.0

stemcells:
- alias: trusty
  os: ubuntu-trusty
  version: latest

instance_groups:
- name: web
  instances: 1
  # replace with a VM type from your BOSH Director's cloud config
  vm_type: web
  stemcell: trusty
  azs: [z1]
  networks:
  - name: private
    default: [dns, gateway]
  - name: public
    static_ips: [$CONCOURSE_FLOATING_IP] # <--- Replace with a floating IP
  jobs:
  - name: atc
    release: concourse
    properties:
      # replace with your CI's externally reachable URL, e.g. https://ci.foo.com
      external_url: $CONCOURSE_EXTERNAL_URL

      # replace with username/password, or configure GitHub auth
      basic_auth_username: admin
      basic_auth_password: admin

      postgresql_database: &atc_db atc
  - name: tsa
    release: concourse
    properties: {}

- name: db
  instances: 1
  # replace with a VM type from your BOSH Director's cloud config
  vm_type: database
  stemcell: trusty
  # replace with a disk type from your BOSH Director's cloud config
  persistent_disk_type: default
  azs: [z1]
  networks: [{name: private}]
  jobs:
  - name: postgresql
    release: concourse
    properties:
      databases:
      - name: *atc_db
        # make up a role and password
        role: concourse
        password: concourse

- name: worker
  instances: 1
  # replace with a VM type from your BOSH Director's cloud config
  vm_type: worker
  stemcell: trusty
  azs: [z1]
  networks: [{name: private}]

  jobs:
  - name: groundcrew
    release: concourse
    properties:
      http_proxy_url: $http_proxy
      https_proxy_url: $https_proxy
      no_proxy: [$no_proxy]

  - name: baggageclaim
    release: concourse
    properties: {}

  - name: garden
    release: garden-runc
    properties:
      garden:
        listen_network: tcp
        listen_address: 0.0.0.0:7777

update:
  canaries: 1
  max_in_flight: 1
  serial: false
  canary_watch_time: 1000-60000
  update_watch_time: 1000-60000
EOF

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

chmod 600 bosh.pem

sudo route add $DIRECTOR_FLOATING_IP gw $OPENSTACK_IP || true
sudo route add -net $PRIVATE_CIDR gw $OPENSTACK_IP || true

./bosh-cli create-env --tty bosh-init.yml

scp -i bosh.pem -o StrictHostKeyChecking=no vcap@$DIRECTOR_FLOATING_IP:/var/vcap/store/director/nginx/director.pem .
echo $DIRECTOR_FLOATING_IP $director_host | sudo tee -a /etc/hosts
./bosh-cli alias-env --ca-cert director.pem -e $director_host bosh
./bosh-cli log-in -e bosh --client admin --client-secret admin
./bosh-cli update-cloud-config -e bosh --non-interactive cloud-config.yml
./bosh-cli upload-stemcell -e bosh $stemcell_url
./bosh-cli deploy -e bosh -d bosh-concourse -n bosh-concourse-deployment.yml
