# Build and test the k9s rock and charm.
#
# Rockcraft and charmcraft only run on Linux (they're distributed as snaps).
# If they aren't installed locally, the build targets transparently fall back
# to building inside a Multipass Ubuntu VM (see hack/).

.PHONY: help build charm unit shell dev-vm deploy clean vm-down

help:
	@echo "make build    - build the rock (locally if rockcraft is installed, else via a Multipass VM)"
	@echo "make charm    - build the charm with charmcraft"
	@echo "make unit     - run the charm unit tests"
	@echo "make shell    - load the built .rock into docker and open an interactive zsh shell"
	@echo "make dev-vm   - provision a Multipass VM with microk8s, juju, charmcraft and rockcraft"
	@echo "make deploy   - build and deploy the charm onto the dev VM's microk8s"
	@echo "make clean    - remove build artifacts"
	@echo "make vm-down  - delete the Multipass build VM"

build:
	@if command -v rockcraft >/dev/null 2>&1; then \
		echo "==> rockcraft found locally, building directly"; \
		cd rock && rockcraft pack && mv *.rock ..; \
	else \
		./hack/build-in-vm.sh; \
	fi

charm:
	@if command -v charmcraft >/dev/null 2>&1; then \
		echo "==> charmcraft found locally, building directly"; \
		charmcraft pack; \
	else \
		echo "error: charmcraft is not installed; run 'make dev-vm' and build there" >&2; \
		exit 1; \
	fi

.venv:
	python3 -m venv .venv
	./.venv/bin/pip install --quiet --upgrade pip
	./.venv/bin/pip install --quiet "ops[testing]~=2.17" pytest pyyaml

unit: .venv
	./.venv/bin/python -m pytest -q

shell: build
	./hack/shell.sh

dev-vm:
	./hack/dev-vm.sh

deploy:
	./hack/deploy.sh

clean:
	rm -f *.rock *.charm
	rm -rf build .venv .pytest_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

vm-down:
	-multipass delete --purge "$${ROCKCRAFT_VM:-k9s-rockcraft-build}"
	-multipass delete --purge "$${DEV_VM:-k9s-dev}"
