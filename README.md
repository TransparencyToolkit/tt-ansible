# Ansible tooling for deploying the Transparency Toolkit

# THIS IS PROBABLY NOT WORKING CORRECTLY

## LookingGlass on Debian

```shell
apt update \
  && apt install -y -q --no-install-recommends ansible python-apt \
  && make lint \
  && make LookingGlass
```

Check that everything is up to date:
```shell
make lint
ansible-playbook --check -v --ask-become-pass -c local LookingGlass.yml
```

Installing LookingGlass:
```
make LookingGlass
```

## Environment variable overrides

You can override a variety of default settings by appending to files in `/etc/systemd/MY.SERVICE.service.d/*`, or by creating new files in those directories.
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
- ansible-playbook -e `EXTRA_VARS`
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
