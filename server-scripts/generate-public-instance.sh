#!/usr/bin/env bash
set -eu

# generates a new instance VM and a corresponding OCR VM
# usage: generate-instance.sh NUM NAME

### parameters:

INSTANCE_NAME="$1"
domain="pub-${INSTANCE_NAME}"
INSTANCE_GW="$2"
INSTANCE_IP="$3"
INSTANCE_MAC="$4"
ARCHIVE_IP="$5"
TEMPLATE_NAME="$6"
TEMPLATE_RANGE="$7"


template="${TEMPLATE_NAME}"
AA_IP="10.13.${TEMPLATE_RANGE}.2"

[ -d "/tt_archive_config/${INSTANCE_NAME}/public/" ] \
    || { echo "VM directory /tt_archive_config/${INSTANCE_NAME}/public/ does not exist"
         exit 1; }

lvcreate --snapshot --extents '20%ORIGIN' -n "${domain}" /dev/storage/${template}-template

virt-sysprep --no-logfile \
  --operations ssh-hostkeys,utmp,logfiles,crash-data,customize \
  --hostname "${domain}" -a /dev/storage/"${domain}" --network \
  --mkdir /home/tt/.ssh \
  --mkdir /root/.ssh \
  --upload "/tt_archive_config/${INSTANCE_NAME}/id_ed25519.pub:/home/tt/.ssh/authorized_keys" \
  --upload "/tt_archive_config/${INSTANCE_NAME}/id_ed25519.pub:/root/.ssh/authorized_keys2" \
  --chmod '0700:/home/tt/.ssh' \
    --chmod '0700:/root/.ssh' \
    --chmod '0700:/home/tt/.ssh/authorized_keys' \
    --chmod '0700:/root/.ssh/authorized_keys' \
    --run-command 'chown -R tt:tt /home/tt/.ssh' \
  --run-command "$( # TODO
    )"'for xx in enp1s0 enp2s0 ; do echo "allow-hotplug ${xx}" > /etc/network/interfaces.d/${xx} && echo "iface ${xx} inet dhcp" >> /etc/network/interfaces.d/${xx}; done ' \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${AA_IP} port port=3000 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${ARCHIVE_IP} port port=22 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${INSTANCE_GW} port port=22 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${INSTANCE_GW} port port=3001 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --reload" \
  --firstboot-command 'dpkg-reconfigure openssh-server ; for x in postgresql elasticsearch indexserver docmanager docmanager-reload docmanager-reload.path lookingglass; do systemctl unmask "$x" && systemctl enable "$x" && systemctl start "$x"; done'

# firewall rules:  3000 (DM) allowed from AA_IP
#                  22  (ssh) allowed from ARCHIVE_IP
#                  22  (ssh) allowed from INSTANCE_GW
#                  3001 (LG) allowed from INSTANCE_GW


# generate random bridge name because linux doesn't like
# bridges with more than 15 characters in them.
bridge_name=$(head /dev/urandom | tr -dc A-Za-z | head -c 10)

virsh net-define --file <(cat <<EOF
<network>  <name>vm-${domain}</name>
  <bridge name='br${bridge_name}' stp='on' delay='0' />
  <forward mode="route" />
  <ip address="${INSTANCE_GW}" netmask="255.255.255.252" >
    <dhcp><range start="${INSTANCE_IP}" end="${INSTANCE_IP}"/>
    <host mac='${INSTANCE_MAC}' name='public' ip='${INSTANCE_IP}'/>
    </dhcp></ip>
</network>
EOF
)
virsh net-autostart "vm-${domain}"
virsh net-info "vm-${domain}" |fgrep Active|fgrep yes \
    || virsh net-start "vm-${domain}"
virsh net-start "vm-${domain}" || { echo failed to start net; }

# public domain:
virt-install --import --os-variant debian9 \
  --connect qemu:///system \
  --virt-type kvm \
  --name "vm-${domain}" \
  --metadata "title=public ${INSTANCE_NAME}: ${INSTANCE_IP}" \
  --memory 4000 \
  --disk "path=/dev/storage/${domain},format=raw,discard=unmap" \
  --vcpus 2 \
  --graphics none \
  --network "mac=${INSTANCE_MAC},network=vm-${domain}" \
  --noautoconsole \
  --autostart \
  --import \
  --rng /dev/random \
  --filesystem "source=/tt_archive_config/${INSTANCE_NAME}/public/,target=/tt-config/"
