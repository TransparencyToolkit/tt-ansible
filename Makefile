lint:
	ansible-playbook --syntax-check -c local Catalyst.yml
	ansible-playbook --syntax-check -c local LookingGlass.yml
