.POSIX:

.PHONY: lint LookingGlass Catalyst IndexServer OCRServer load-test-data

lint:
	ansible-playbook --syntax-check -c local Catalyst.yml
	ansible-playbook --syntax-check -c local LookingGlass.yml
	ansible-playbook --syntax-check -c local load-test-data.yml
	ansible-playbook --syntax-check -c local OCRServer.yml
	ansible-playbook --syntax-check -c local IndexServer.yml

LookingGlass:
	ansible-playbook -v --ask-become-pass --forks 10 -c local LookingGlass.yml

IndexServer:
	ansible-playbook -v --ask-become-pass --forks 10 -c local IndexServer.yml

OCRServer:
	ansible-playbook -v --ask-become-pass --forks 10 -c local OCRServer.yml


Catalyst:
	ansible-playbook -v --ask-become-pass --forks 10 -c local Catalyst.yml

load-test-data:
	ansible-playbook -v --ask-become-pass --forks 10 -c local load-test-data.yml
