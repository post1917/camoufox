include upstream.sh
export

cf_source_dir := camoufox-$(version)-$(release)
ff_source_tarball := firefox-$(version).source.tar.xz

debs := python3 python3-dev python3-pip p7zip-full golang-go msitools wget aria2
rpms := python3 python3-devel p7zip golang msitools wget aria2
pacman := python python-pip p7zip go msitools wget aria2

.PHONY: help fetch setup setup-minimal clean set-target distclean build package \
        build-launcher check-arch revert edits run bootstrap mozbootstrap dir \
        package-linux package-macos package-windows vcredist_arch patch unpatch \
        workspace check-arg edit-cfg ff-dbg

help:
	@echo "Available targets:"
	@echo "  fetch           - Fetch the Firefox source code"
	@echo "  setup           - Setup Camoufox & local git repo for development"
	@echo "  bootstrap       - Set up build environment"
	@echo "  mozbootstrap    - Sets up mach"
	@echo "  dir             - Prepare Camoufox source directory with BUILD_TARGET"
	@echo "  revert          - Kill all working changes"
	@echo "  edits           - Camoufox developer UI"
	@echo "  build-launcher  - Build launcher"
	@echo "  clean           - Remove build artifacts"
	@echo "  distclean       - Remove everything including downloads"
	@echo "  build           - Build Camoufox"
	@echo "  set-target      - Change the build target with BUILD_TARGET"
	@echo "  package-linux   - Package Camoufox for Linux"
	@echo "  package-macos   - Package Camoufox for macOS"
	@echo "  package-windows - Package Camoufox for Windows"
	@echo "  run             - Run Camoufox"
	@echo "  edit-cfg        - Edit camoufox.cfg"
	@echo "  ff-dbg          - Setup vanilla Firefox with minimal patches"
	@echo "  patch           - Apply a patch"
	@echo "  unpatch         - Remove a patch"
	@echo "  workspace       - Sets the workspace to a patch, assuming its applied"

_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
$(eval $(_ARGS):;@:)

fetch:
	aria2c -x16 -s16 -k1M -o $(ff_source_tarball) "https://archive.mozilla.org/pub/firefox/releases/$(version)/source/firefox-$(version).source.tar.xz"; \

setup-minimal:
	# Note: Only docker containers are intended to run this directly.
	# Run this before `make dir` or `make build` to avoid setting up a local git repo.
	if [ ! -f $(ff_source_tarball) ]; then \
		make fetch; \
	fi
	# Create new cf_source_dir
	rm -rf $(cf_source_dir)
	mkdir -p $(cf_source_dir)
	tar -xJf $(ff_source_tarball) -C $(cf_source_dir) --strip-components=1
	# Copy settings & additions
	cd $(cf_source_dir) && bash ../scripts/copy-additions.sh $(version) $(release)

setup: setup-minimal
	# Initialize local git repo for development
	cd $(cf_source_dir) && \
		git init -b main && \
		git add -f -A && \
		git commit -m "Initial commit" && \
		git tag -a unpatched -m "Initial commit"

ff-dbg: setup
	# Only apply patches to help debug vanilla Firefox
	make patch ./patches/chromeutil.patch
	make patch ./patches/debug-url-navigation.patch
	echo "\nLOCAL_INCLUDES += ['/camoucfg']" >> $(cf_source_dir)/dom/base/moz.build
	touch $(cf_source_dir)/_READY
	make checkpoint

revert:
	cd $(cf_source_dir) && git reset --hard unpatched

dir:
	@if [ ! -d $(cf_source_dir) ]; then \
		make setup; \
	fi
	python3 scripts/patch.py $(version) $(release)
	touch $(cf_source_dir)/_READY

set-target:
	python3 scripts/patch.py $(version) $(release) --mozconfig-only

mozbootstrap:
	cd $(cf_source_dir) && MOZBUILD_STATE_PATH=$$HOME/.mozbuild ./mach --no-interactive bootstrap --application-choice=browser

bootstrap: dir
	(sudo apt-get -y install $(debs) || sudo dnf -y install $(rpms) || sudo pacman -Sy $(pacman))
	make mozbootstrap

diff:
	@cd $(cf_source_dir) && git diff $(_ARGS)

checkpoint:
	cd $(cf_source_dir) && git commit -m "Checkpoint" -a -uno

clean:
	cd $(cf_source_dir) && git clean -fdx && ./mach clobber
	make revert

distclean:
	rm -rf $(cf_source_dir) $(ff_source_tarball)

build:
	@if [ ! -f $(cf_source_dir)/_READY ]; then \
		make dir; \
	fi
	cd $(cf_source_dir) && ./mach build

edits:
	python ./scripts/developer.py $(version) $(release)

check-arch:
	@if ! echo "x86_64 i686 arm64" | grep -qw "$(arch)"; then \
		echo "Error: Invalid arch value. Must be x86_64, i686, or arm64."; \
		exit 1; \
	fi

build-launcher: check-arch
	cd launcher && bash build.sh $(arch) $(os)

package-linux:
	make build-launcher arch=$(arch) os=linux;
	python3 scripts/package.py linux \
		--includes \
			settings/chrome.css \
			settings/properties.json \
			bundle/fontconfigs \
		--version $(version) \
		--release $(release) \
		--arch $(arch) \
		--fonts windows macos linux

package-macos:
	make build-launcher arch=$(arch) os=macos;
	python3 scripts/package.py macos \
		--includes \
			settings/chrome.css \
			settings/properties.json \
		--version $(version) \
		--release $(release) \
		--arch $(arch) \
		--fonts windows linux

package-windows:
	make build-launcher arch=$(arch) os=windows;
	python3 scripts/package.py windows \
		--includes \
			settings/chrome.css \
			settings/properties.json \
			~/.mozbuild/vs/VC/Redist/MSVC/14.38.33135/$(vcredist_arch)/Microsoft.VC143.CRT/*.dll \
		--version $(version) \
		--release $(release) \
		--arch $(arch) \
		--fonts macos linux

run-launcher:
	rm -rf $(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/launch;
	make build-launcher arch=x86_64 os=linux;
	cp launcher/dist/launch $(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/launch;
	$(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/launch

run-pw:
	rm -rf $(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/launch;
	make build-launcher arch=x86_64 os=linux;
	python3 scripts/run-pw.py \
		--version $(version) \
		--release $(release)

run:
	cd $(cf_source_dir) \
	&& rm -rf ~/.camoufox $(cf_source_dir)/obj-x86_64-pc-linux-gnu/tmp/profile-default \
	&& CAMOU_CONFIG=$${CAMOU_CONFIG:-'{}'} \
	&& CAMOU_CONFIG="$${CAMOU_CONFIG%?}, \"debug\": true}" ./mach run $(args)

edit-cfg:
	@if [ ! -f $(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/camoufox.cfg ]; then \
		echo "Error: camoufox.cfg not found. Apply config.patch first."; \
		exit 1; \
	fi
	$(EDITOR) $(cf_source_dir)/obj-x86_64-pc-linux-gnu/dist/bin/camoufox.cfg

check-arg:
	@if [ -z "$(_ARGS)" ]; then \
		echo "Error: No file specified. Usage: make <command> ./patches/file.patch"; \
		exit 1; \
	fi

patch:
	@make check-arg $(_ARGS);
	cd $(cf_source_dir) && patch -p1 -i ../$(_ARGS)

unpatch:
	@make check-arg $(_ARGS);
	cd $(cf_source_dir) && patch -p1 -R -i ../$(_ARGS)

workspace:
	@make check-arg $(_ARGS);
	@if (cd $(cf_source_dir) && patch -p1 -R --dry-run --force -i ../$(_ARGS)) > /dev/null 2>&1; then \
		echo "Patch is already applied. Unapplying..."; \
		make unpatch $(_ARGS); \
	else \
		echo "Patch is not applied. Proceeding with application..."; \
	fi
	make checkpoint || trueZ
	make patch $(_ARGS)

vcredist_arch := $(shell echo $(arch) | sed 's/x86_64/x64/' | sed 's/i686/x86/')
