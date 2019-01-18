.POSIX:

.PHONY: lint LookingGlass Catalyst IndexServer OCRServer load-test-data DocUpload

lint:
	ansible-playbook --syntax-check -c local \
		DocUpload.yml Catalyst.yml LookingGlass.yml \
		load-test-data.yml OCRServer.yml IndexServer.yml

LookingGlass:
	ansible-playbook -v --ask-become-pass --forks 10 -c local LookingGlass.yml

IndexServer:
	ansible-playbook -v --ask-become-pass --forks 10 -c local IndexServer.yml

OCRServer:
	ansible-playbook -v --ask-become-pass --forks 10 -c local OCRServer.yml


Catalyst:
	ansible-playbook -v --ask-become-pass --forks 10 -c local Catalyst.yml

DocUpload:
	ansible-playbook -v --ask-become-pass --forks 10 -c local DocUpload.yml

load-test-data:
	ansible-playbook -v --ask-become-pass --forks 10 -c local load-test-data.yml
