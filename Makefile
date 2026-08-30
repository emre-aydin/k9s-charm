# Build and test the k9s rock.
#
# Rockcraft only runs on Linux (it's distributed as a snap). If it's not
# installed locally, `make build` transparently builds inside a Multipass
# Ubuntu VM instead (see hack/build-in-vm.sh).

.PHONY: build shell clean vm-down help

help:
	@echo "make build     - build the rock (locally if rockcraft is installed, else via a Multipass VM)"
	@echo "make shell     - load the built .rock into docker and open an interactive zsh shell"
	@echo "make clean     - remove built .rock files from the repo root"
	@echo "make vm-down   - delete the Multipass build VM"

build:
	@if command -v rockcraft >/dev/null 2>&1; then \
		echo "==> rockcraft found locally, building directly"; \
		rockcraft pack; \
	else \
		./hack/build-in-vm.sh; \
	fi

shell: build
	./hack/shell.sh

clean:
	rm -f *.rock

vm-down:
	multipass delete --purge "$${ROCKCRAFT_VM:-k9s-rockcraft-build}"
