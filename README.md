# Ansible tooling for deploying the Transparency Toolkit

# THIS IS PROBABLY NOT WORKING CORRECTLY

These recipes are being tested on Debian-`stable` and Debian-`testing`.

TODO pipeline diagram

DocUpload -> OCRServer -> IndexServer -> DocManager -> Catalyst -> LookingGlass w/ever

**Ports used**
|--------------------|
| Port | Service     |
|------|-------------|
| 3000 | DocManager  |
| 9004 | Catalyst    |
| 9292 | DocUpload   |
| 9393 | OCRServer   |
| 9494 | IndexServer |
|------|-------------|


## Prerequisites

This repository contains a number of Ansible recipes to help deploy the Transparency Toolkit tools on servers.

The `.yml` files in the top directory (`Catalyst.yml`, `DocUpload.yml`, ...) are so-called "Ansible Playbooks."

To use our playbooks you must have the [Ansible](https://ansible.com/)
deployment tools installed, the `sudo` utility, and the Python bindings to
[libapt-pkg bindings](https://pypi.org/project/python-apt/).
These can be installed with the following commands:
```shell
sudo apt update \
  && sudo apt install -y -q --no-install-recommends \
       ansible python-apt sudo
```

Each of the playbooks has a number of configuration options that you can
specify using the `--extra-vars` argument, which takes a JSON dictionary.

We will be documenting the configuration options for each playbook below, but
you can also manually consult the options for each role in
the `roles/*/defaults/main.yml` files.

**NB:** Since the pipeline is encrypted using [GPG](https://gnupg.org/), you must configure `gpg_recipient` and `gpg_signer` for most of the playbooks.

## Installing DocUpload

```bash
ansible-playbook -v --ask-become-pass --forks 10 -c local DocUpload.yml \
  --extra-vars "{
    'ocrserver_url': 'http://127.1.2.3:9393',
    'lookingglass_url': 'https://demo.transparency.tools/',
  }"
```

## SystemD services

Our services are installed as systemd services.
Quick cheatsheet for managing systemd services:
|------------------------------------------------------------|
| View status           | `sudo systemctl status docupload`  |
| Restart               | `sudo systemctl restart docupload` |
| View logs             | `sudo journalctl -u docupload`     |
| Live view (tail) logs | `sudo journalctl -fu docupload`    |
|------------------------------------------------------------|


### Environment variable overrides

You can override a variety of default settings **ON AN ALREADY INSTALLED SYSTEM** by appending to files in `/etc/systemd/MY.SERVICE.service.d/*`, or by creating new files in those directories.
TODO
To override the default, append your line **after** `# END ANSIBLE MANAGED BLOCK`. The ansible scripts will update those sections with the upstream defaults, so custom changes have to be below those.
Example: `/etc/systemd/system/docupload.service.d/gpg_signer.conf`:
```systemd
# BEGIN ANSIBLE MANAGED BLOCK
[Service]
Environment="gpg_signer='12345678'"
# END ANSIBLE MANAGED BLOCK
Environment="gpg_signer='my-real-keygrip-here'"
```

Another variable you might want to overwrite is `docupload_tmpdir` which controls the location of the temporary files that DocUpload generates.

## TODO NOTES
- provision postgres users with lower privs
- http://docs.ansible.com/ansible/latest/index.html
- --no-install-recommends
- authentication?
  - [ansible playbook lookups](http://docs.ansible.com/ansible/latest/playbooks_lookups.html#examples)
  - elasticsearch authentication?
- rvm
  - https://rvm.io/rvm/install
  - add user to rvm group
  - . /etc/profile.d/rvm.sh
- ansible-git:  `verify_commit` / `refspec` to pin our code
- get rid of gpg-agent and dirmngr for the temporary imports
