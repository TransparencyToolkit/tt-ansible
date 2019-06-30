#!/usr/bin/env bash
set -eu

instance="$1"
vm="vm-${instance}"

for x in "vm-pub-${instance}" "$vm" "${vm}_ocr" "$instance"; do
  virsh destroy -- "$x" || true
  virsh undefine -- "$x" || true #TODO
done

for x in "vm-pub-${instance}" "$vm" ; do
    virsh net-destroy -- "$x" || true
    virsh net-undefine -- "$x" || true
done

rm -f -- "/etc/nginx/sites-enabled/${instance}"
rm -rf -- "/tt_archive_config/${instance}/"
rm -rf -- "/tt_ocr/${instance}_in/"
rm -rf -- "/tt_ocr/${instance}_out/"

case "${instance}" in
    pub-*)
	rm -rf -- "/tt_archive_config/${instance#pub-}/public/" ;;
esac

lvremove -f -- storage/"${instance}" || true
lvremove -f -- storage/"${instance}_ocr" || true
lvremove -f -- "storage/pub-${instance}" || true

systemctl reload nginx
