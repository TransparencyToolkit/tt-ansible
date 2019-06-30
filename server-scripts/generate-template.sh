#!/usr/bin/env bash
set -eux

##### initial installation:
# TODO firewall-cmd version of these:
# -t nat -A POSTROUTING -s 10.13.1.0/24 '!' -d 10.0.0.0/8 -o eth0 -j MASQUERADE
# -A FORWARD -s 10.0.0.0/8 -d 10.13.1.0/24 -m state --state NEW -j ACCEPT
# -A FORWARD -s 10.0.0.0/8 -d 10.0.0.0/8 -m state --state ESTABLISHED -j ACCEPT
# -A FORWARD -s 10.0.0.0/8 -d 10.0.0.0/8 -j REJECT

#### per reboot:
# losetup -f /vms/file-backed-lvm.pv
# lvscan
# virsh start admin

LOCAL_UNIX_PASSWORD="localonly"

template="$1"
template_range="$2"

# "||true" because it might not exist already:
virsh destroy "admin-${template}" || true
virsh undefine "admin-${template}" || true
lvremove -f "storage/${template}-template" || true
lvcreate -y --size 50g storage -n "${template}-template"

virt-builder -v --check-signatures --update \
    --install 'ansible,python-apt,git,sudo,make,tmux,openssh-server' \
    --mkdir /root/.ssh/ \
    --chmod '0700:/root/.ssh/' \
    --upload '/root/.ssh/authorized_keys:/root/.ssh/' \
    --memsize 7000 \
    --smp 4 \
    --copy-in 'tt-ansible:/' \
    --run-command "$( # turn off persistent interface names since we
                      # only have one, and otherwise we get a new per boot:
    )"'touch /etc/udev/rules.d/75-persistent-net-generator.rules' \
    --run-command 'adduser --disabled-password --gecos "" tt' \
    --run-command 'echo "tt ALL=(ALL) NOPASSWD: ALL" | tee -a /etc/sudoers' \
    --run-command 'chown -R tt:tt /tt-ansible' \
    --run-command 'set -ex; su tt -lc "cd /tt-ansible && make lint"' \
    --run-command 'set -ex; for xx in enp1s0 enp2s0 enp3s0 enp4s0 enp5s0 enp6s0 ens1 ens2 ens3 ens4 ens5 ens6; do echo "allow-hotplug ${xx}" > /etc/network/interfaces.d/${xx} && echo "iface ${xx} inet dhcp" >> /etc/network/interfaces.d/${xx}; done' \
    --firstboot-command 'set -ex ; sleep 5 && su tt -lc "cd /tt-ansible && make template"' \
    --firstboot-command 'systemctl list-unit-files "*.service"' \
    --firstboot-command 'shutdown now' \
  --hostname 'tt-vm' \
  --output "/dev/storage/${template}-template" \
  --timezone 'Europe/Berlin' \
  --root-password "password:${LOCAL_UNIX_PASSWORD}" \
  debian-9

# TODO Insteead of "systemctl disable" we should use
# TODO "systemctl mask" to properly prevent starting the services
# TODO since "disable" will only turn off automatic starting unless
# TODO something depends on it.
# TODO Then we should use "systemctl unmask" to re-enable...

lvcreate --snapshot --extents '10%ORIGIN' -n built-${template} /dev/storage/${template}-template

virt-install --import --os-variant debian9 \
  --connect qemu:///system \
  --virt-type kvm \
  --name "test-${template_range}-template" \
  --metadata "title=Transient Template VM" \
  --memory 7000 \
  --disk "path=/dev/storage/${template}-template,format=raw,discard=unmap" \
  --vcpus 4 \
  --graphics none \
  --network 'network=default' \
  --rng /dev/random \
  --transient

#### copy, split into AA and VM templates

# create `adminvm` copy:
lvcreate --snapshot --extents '10%ORIGIN' -n "admin-${template}" /dev/storage/${template}-template

# clear various things, TODO reset SECRET_KEY_BASE, etc
virt-sysprep --no-logfile \
  --operations utmp,logfiles,crash-data,customize \
  --hostname "admin-${template}" -a "/dev/storage/admin-${template}" --network \
  --append-line '/etc/fstab:/data/tt_archive_config/ /data/tt_archive_config 9p nofail,rw,sync,dirsync,noatime,noauto,x-systemd.automount,x-systemd.device-timeout=10,timeo=14,x-systemd.idle-timeout=0,cache=none,trans=virtio,x-systemd.requires-mounts-for=/tt-config 0 0' \
  --firstboot-command 'dpkg-reconfigure openssh-server && for x in redis-server postgresql elasticsearch apt-daily apt-daily-upgrade docmanager archiveadministrator; do systemctl unmask "$x" ; systemctl enable "$x" ; systemctl start "$x"; done' \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.13.${template_range}.1 port port=3002 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 port port=3002 protocol=tcp accept'" \
  --firstboot-command 'firewall-cmd --reload'

# TODO
# TODO --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.13.${template_range}.1 port port=3002 protocol=tcp accept'" \
# TODO --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.0.0/8 port port=3000 protocol=tcp accept'"
# TODO: why doesn't firewall-cmd like address=10.0.0.2/255.0.0.255 ?
# TODO firewall rules:
# TODO - 3002 (AA) is accessible to the GW for nginx to access it
# TODO  would like to make 3000 (DM) only accessible to archivevms?

# create network for AA
virsh net-define --file <(cat <<EOF
<network>  <name>aa-${template}</name>
  <bridge name='aa-${template}' stp='on' delay='0' />
  <forward mode="route" />
  <ip address="10.13.${template_range}.1" netmask="255.255.255.0" >
    <dhcp><range start="10.13.${template_range}.2" end="10.13.${template_range}.2"/></dhcp></ip>
</network>
EOF
) || true
virsh net-autostart "aa-${template}"
virsh net-start "aa-${template}" || true
mkdir -p /tt_archive_config
chmod a+rwx /tt_archive_config # TODO libvirt
virt-install --import --os-variant debian9 \
  --connect qemu:///system \
  --virt-type kvm \
  --name "admin-${template}" \
  --metadata "title=ArchiveAdministrator vm $template" \
  --memory 5500 \
  --disk "path=/dev/storage/admin-${template},format=raw,discard=unmap" \
  --vcpus 1 \
  --graphics none \
  --network "network=aa-${template}" \
  --autostart \
  --noautoconsole \
  --import \
  --rng /dev/random \
  --filesystem 'source=/tt_archive_config/,target=/data/tt_archive_config/' \
  --filesystem 'source=/tt_archive_config/admin,target=/tt-config/'


# To get 'admin' in a NAT'ed network where you can access the internet to pull
# updates:
# virsh net-edit vm-aa
#  replace   <forward mode="route" />
#  with      <forward mode="nat" />
# virsh shutdown admin
# virsh net-destroy vm-aa
# virsh net-start vm-aa
# virsh start admin
# atlernatively something like -A POSTROUTING -s 10.13.1.0/24 -o eth0 -j MASQUERADE
