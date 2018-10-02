# Ansible tooling for deploying the Transparency Toolkit

# THIS IS PROBABLY NOT WORKING CORRECTLY

## LookingGlass on Debian

```shell
apt-get update \
  && apt-get install -y -q --no-install-recommends ansible python-apt \
  && make lint \
  && make LookingGlass
```

Check that everything is up to date:
```shell
ansible-playbook --check -v --ask-become-pass -c local LookingGlass.yml
```

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

