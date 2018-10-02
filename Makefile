.PHONY: lint LookingGlass Catalyst

lint:
	ansible-playbook --syntax-check -c local Catalyst.yml
	ansible-playbook --syntax-check -c local LookingGlass.yml

LookingGlass:
	ansible-playbook -v --ask-become-pass -c local LookingGlass.yml

Catalyst:
	ansible-playbook -v --ask-become-pass -c local Catalyst.yml
