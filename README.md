# Ansible tooling for deploying the Transparency Toolkit

# THIS IS PROBABLY NOT WORKING CORRECTLY

These recipes are being tested on Debian-`stable` and Debian-`testing`.

TODO pipeline diagram

DocUpload -> OCRServer -> IndexServer -> DocManager -> Catalyst -> LookingGlass w/ever

**Ports used**

| Port | Service      | Description |
| ---- | ------------ | --- |
| 3000 | DocManager   | Document storage |
| 3001 | LookingGlass | Frontend |
| 9002 | Stanford-NER | |
| 9004 | Catalyst     | |
| 9292 | DocUpload    | Small interface for uploading files. |
| 9393 | OCRServer    | |
| 9494 | IndexServer  | |
| 9998 | Tika         | Component of OCRServer. |

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

## Hosted instance

See the [server-scripts README](#./server-scripts/README.md) for details on how to deploy a server that can automatically provision these services.

## Installing DocUpload manually

```bash
ansible-playbook -v --ask-become-pass --forks 10 -c local DocUpload.yml \
  --extra-vars "{
    'ocrserver_url': 'http://127.1.2.3:9393',
    'lookingglass_url': 'https://demo.transparency.tools/',
  }"
```

Additional configuration options:
```python
# The user under which to run the DocUpload service:
# (defaults to installing user)
docupload_user

# Directory into which data will be written before it is
# sent upstream to the OCRServer:
docupload_tmpdir

# The IP or hostname the DocUpload service will bind to
# (listen on, on port 9292):
docupload_ip: '127.0.0.1'
```

## Installing IndexServer manually

```bash
ansible-playbook -v --ask-become-pass --forks 10 -c local IndexServer.yml \
  --extra-vars "{
    'docmanager_url': 'http://127.1.2.3:3000',
  }"
```

Additional configuration options:
```python
# The user under which to run the DocUpload service:
# (defaults to installing user)
indexserver_user

docmanager_url
```

## Installing DocManager manually

```bash
ansible-playbook -v --ask-become-pass --forks 10 -c local DocManager.yml \
  --extra-vars "{
    'docmanager_url': 'http://127.0.0.1:3000',
  }"
```

Additional configuration options:
```python
docmanager_user
docmanager_ip

postgres_db
postgres_username

catalyst_url
```


## Installing OCRServer

```bash
ansible-playbook -v --ask-become-pass --forks 10 -c local OCRServer.yml
```

Additional configuration options:
```python
ocrserver_user

tika_version: '1.19.1'

indexserver_url: http://127.0.0.1:9494
```



## SystemD services

Our services are installed as systemd services.
Quick cheatsheet for managing systemd services:

| Action to perform     | Shell command                      |
| --------------------- | ---------------------------------- |
| View status           | `sudo systemctl status docupload`  |
| Restart               | `sudo systemctl restart docupload` |
| View logs             | `sudo journalctl -u docupload`     |
| Live view (tail) logs | `sudo journalctl -fu docupload`    |


### Environment variable overrides

You can override the default configuration options after installation
by appending to files in `/etc/systemd/MY.SERVICE.service.d/*`,
or by creating new files in those directories.

To override the default, append your line **after**
`# END ANSIBLE MANAGED BLOCK`.
The ansible scripts will update those sections with the
 upstream defaults, so custom changes have to be below those.

Example: `/etc/systemd/system/docupload.service.d/gpg_signer.conf`:
```systemd
# BEGIN ANSIBLE MANAGED BLOCK
[Service]
Environment="gpg_signer='12345678'"
# END ANSIBLE MANAGED BLOCK
Environment="gpg_signer='my-real-keygrip-here'"
```

## TODO NOTES
- provision postgres users with lower privs
- http://docs.ansible.com/ansible/latest/index.html
- --no-install-recommends
- authentication?
  - [ansible playbook lookups](http://docs.ansible.com/ansible/latest/playbooks_lookups.html#examples)
  - elasticsearch authentication?
- rvm
  - https://rvm.io/rvm/install
  - . /etc/profile.d/rvm.sh
- ansible-git:  `verify_commit` / `refspec` to pin our code
- get rid of gpg-agent and dirmngr for the temporary imports
