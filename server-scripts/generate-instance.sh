#!/usr/bin/env bash
set -eu

# generates a new instance VM and a corresponding OCR VM
# usage: generate-instance.sh NAME GW IP MAC TEMPLATE-NAME TEMPLATE-RANGE

### parameters:

INSTANCE_NAME="$1"
INSTANCE_GW="$2"
INSTANCE_IP="$3"
INSTANCE_MAC="$4"
TEMPLATE_NAME="$5"
TEMPLATE_RANGE="$6"


# sanity checking of parameters:

TEMPLATE_RANGE="${TEMPLATE_RANGE}"
[ "${TEMPLATE_RANGE/[^0-9]/$'\n'}" = "${TEMPLATE_RANGE}" ]
[ -n "${TEMPLATE_RANGE}" ]
# number between 0-255, must be unique, is used to assign a local
# IP address.
INSTANCE_NAME="${INSTANCE_NAME}"
[ "${INSTANCE_NAME/[^0-9a-z_]/$'\n'}" = "${INSTANCE_NAME}" ]
[ -n "${INSTANCE_NAME}" ]
# name of the instance, should be alphanumeric/_ and non-empty.
TEMPLATE_NAME="${TEMPLATE_NAME}"
[ "${TEMPLATE_NAME/[^0-9a-z_]/$'\n'}" = "${TEMPLATE_NAME}" ]
[ -n "${TEMPLATE_NAME}" ]
# name of the instance, should be alphanumeric/_ and non-empty.


template="${TEMPLATE_NAME}"

AA_IP="10.13.${TEMPLATE_RANGE}.2"

[ -d "/tt_archive_config/${INSTANCE_NAME}/" ] \
    || { echo "VM directory /tt_archive_config/${INSTANCE_NAME}/ does not exist"
         exit 1; }


domain="${INSTANCE_NAME}"
domain_ocr="${domain}_ocr"

# create folders for OCR
mkdir -p "/tt_ocr/${domain}_"{in,out}"/raw_docs"
mkdir -p "/tt_ocr/${domain}_out/ocred_docs"
chown -R libvirt-qemu:libvirt-qemu "/tt_ocr/${domain}_"{in,out}
chmod -R a+rwx "/tt_ocr/${domain}_"{in,out}

lvcreate --snapshot --extents '25%ORIGIN' -n "${domain}" /dev/storage/${template}-template
lvcreate --snapshot --extents '15%ORIGIN' -n "${domain_ocr}" /dev/storage/${template}-template

# TODO here we should also replace SECRET_KEY_BASE etc...
# RequiresMountsFor={{ required_mounts }}
# required_mounts: /tt-config /etc/systemd/system

################# prepare OCR VM:
virt-sysprep --no-logfile \
  --operations ssh-hostkeys,utmp,logfiles,crash-data,customize \
  --hostname "${domain_ocr}" -a /dev/storage/"${domain_ocr}" \
  --append-line '/etc/fstab:/ocr_in/ /home/tt/ocr_in 9p '"$(
  )"'nofail,rw,sync,dirsync,noatime,x-systemd.device-timeout=10,'"$(
  )"'timeo=14,cache=none,trans=virtio,x-systemd.idle-timeout=0,'"$(
  )"'x-systemd.before=ocrserver.service 0 0' \
  --append-line '/etc/fstab:/ocr_out/ /home/tt/ocr_out 9p nofail,rw,sync,dirsync,noatime,x-systemd.device-timeout=10,timeo=14,cache=none,trans=virtio,x-systemd.idle-timeout=0,x-systemd.requires-mounts-for=/ocr_in,x-systemd.before=ocrserver.service 0 0' \
  --firstboot-command 'set -eux; systemctl daemon-reload && for x in tika ocrserver; do systemctl unmask "$x" ; systemctl enable "$x" ; systemctl start "$x" ; done' \
  & # <-- run in the background so we can parallelize the VM preparation
prepare_ocr_pid=$!


################# prepare instance VM:
</dev/null ssh-keygen -t ed25519 -N '' -f "/tt_archive_config/${INSTANCE_NAME}/id_ed25519"
#chmod a+r "/tt_archive_config/${INSTANCE_NAME}/id_ed25519"
virt-sysprep --no-logfile \
  --operations ssh-hostkeys,utmp,logfiles,crash-data,customize \
  --hostname "${domain}" -a /dev/storage/"${domain}" --network \
  --mkdir '/home/tt/.ssh' \
  --upload "/tt_archive_config/${INSTANCE_NAME}/id_ed25519:/home/tt/.ssh/" \
  --upload "/tt_archive_config/${INSTANCE_NAME}/id_ed25519.pub:/home/tt/.ssh/" \
  --append-line '/home/tt/.ssh/config:StrictHostKeyChecking no' \
  --run-command 'chown -R tt:tt /home/tt/.ssh/ && chmod -R 0700 /home/tt/.ssh/' \
  --append-line '/etc/fstab:/ocr_in/ /home/tt/ocr_in 9p nofail,rw,sync,dirsync,noatime,x-systemd.device-timeout=10,timeo=14,cache=none,trans=virtio,x-systemd.idle-timeout=0,x-systemd.before=docupload.service 0 0' \
  --append-line '/etc/fstab:/ocr_out/ /home/tt/ocr_out 9p nofail,rw,sync,dirsync,noatime,x-systemd.device-timeout=10,timeo=14,cache=none,trans=virtio,x-systemd.idle-timeout=0,x-systemd.before=indexserver.service 0 0' \
  --run-command 'sed -i s,127.0.0.1,0.0.0.0,g /lib/systemd/system/lookingglass.service /lib/systemd/system/docmanager.service /lib/systemd/system/docupload.service && for xx in enp1s0 enp2s0 enp4s0 enp5s0 enp6s0 ens4 ens5; do echo "allow-hotplug ${xx}" | tee -a /etc/network/interfaces.d/${xx} && echo "iface ${xx} inet dhcp" | tee -a /etc/network/interfaces.d/${xx}; done ' \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${AA_IP} port port=3000 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${INSTANCE_GW} port port=3001 protocol=tcp accept'" \
  --firstboot-command "firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=${INSTANCE_GW} port port=9292 protocol=tcp accept'" \
  --firstboot-command 'firewall-cmd --reload' \
  --firstboot-command 'set -eux; dpkg-reconfigure openssh-server && systemctl daemon-reload && for x in postgresql elasticsearch indexserver stanford-ner docmanager docmanager-reload docmanager-reload.path catalyst lookingglass docupload; do systemctl unmask "$x" ; systemctl enable "$x" ; systemctl start "$x"; done' &
prepare_instance_pid=$!

# firewall rules: 3000 (DocManager) allowed from AA_IP
#                 3001 (LookingGlass) allowed from INSTANCE_GW
#                 9292 (DocUpload) allowed from INSTANCE_GW

# public vm: DM, LG, indexserver

# generate random bridge name because linux doesn't like
# bridges with more than 15 characters in them.
bridge_name=$(head /dev/urandom | tr -dc A-Za-z | head -c 10)

# create network for INSTANCE_NAME
virsh net-define --file <(cat <<EOF
<network>  <name>vm-${domain}</name>
  <bridge name='br${bridge_name}' stp='on' delay='0' />
  <forward mode="route" />
  <ip address="${INSTANCE_GW}" netmask="255.255.255.252" >
    <dhcp><range start="${INSTANCE_IP}" end="${INSTANCE_IP}"/>
    <host mac='${INSTANCE_MAC}' name='archive' ip='${INSTANCE_IP}'/>
    </dhcp></ip>
</network>
EOF
)
virsh net-autostart "vm-${domain}"
virsh net-info "vm-${domain}" |fgrep Active|fgrep yes \
    || virsh net-start "vm-${domain}"

# instance domain:
wait $prepare_instance_pid
virt-install --import --os-variant debian9 \
  --connect qemu:///system \
  --virt-type kvm \
  --name "vm-${domain}" \
  --metadata "title=instance ${INSTANCE_NAME}: ${INSTANCE_IP}" \
  --memory 6000 \
  --disk "path=/dev/storage/${domain},format=raw,discard=unmap" \
  --vcpus 2 \
  --graphics none \
  --network "mac=${INSTANCE_MAC},network=vm-${domain}" \
  --noautoconsole \
  --autostart \
  --import \
  --rng /dev/random \
  --filesystem "source=/tt_archive_config/${domain}/,target=/tt-config/" \
  --filesystem "source=/tt_ocr/${domain}_in/,target=/ocr_in/" \
  --filesystem "source=/tt_ocr/${domain}_out/,target=/ocr_out/"

# OCR domain:
wait $prepare_ocr_pid
virt-install --import --os-variant debian9 \
  --connect qemu:///system \
  --virt-type kvm \
  --name "vm-${domain_ocr}" \
  --metadata "title=OCR ${INSTANCE_NAME}: ${INSTANCE_IP}" \
  --memory 4000 \
  --disk "path=/dev/storage/${domain_ocr},format=raw,discard=unmap" \
  --vcpus 2 \
  --graphics none \
  --network none \
  --noautoconsole \
  --import \
  --rng /dev/random \
  --filesystem "source=/tt_archive_config/${domain}/,target=/tt-config/" \
  --filesystem "source=/tt_ocr/${domain}_in/,target=/ocr_in/" \
  --filesystem "source=/tt_ocr/${domain}_out/,target=/ocr_out/"
