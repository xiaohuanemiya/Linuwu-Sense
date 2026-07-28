obj-m := src/linuwu_sense.o

KVER  ?= $(shell uname -r)
KDIR  := /lib/modules/$(KVER)/build
PWD   := $(shell pwd)

MDIR  := /lib/modules/$(KVER)/kernel/drivers/platform/x86
MODNAME := linuwu_sense
REAL_USER := $(shell echo $${SUDO_USER:-$$(whoami)})

DKMS_NAME := linuwu-sense
DKMS_VER  := $(shell sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' dkms.conf)
DKMS_SRC  := /usr/src/$(DKMS_NAME)-$(DKMS_VER)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

	# --- auto sign block ---
	# Check if keys exist before attempting to sign
	@if [ -f "$(HOME)/module-signing/MOK.priv" ] && [ -f "$(HOME)/module-signing/MOK.der" ]; then \
	if [ -x "/lib/modules/$(KVER)/build/scripts/sign-file" ]; then \
	SIGN_TOOL="/lib/modules/$(KVER)/build/scripts/sign-file"; \
	elif [ -x "/usr/src/linux-headers-$(KVER)/scripts/sign-file" ]; then \
	SIGN_TOOL="/usr/src/linux-headers-$(KVER)/scripts/sign-file"; \
	else \
	echo "ERROR: sign-file tool not found, but MOK keys exist."; \
	exit 1; \
	fi; \
	echo "Signing module linuwu_sense.ko using $$SIGN_TOOL"; \
	sudo $$SIGN_TOOL sha256 \
	$(HOME)/module-signing/MOK.priv \
	$(HOME)/module-signing/MOK.der \
	$(PWD)/src/linuwu_sense.ko; \
	else \
	echo "MOK keys not found in ~/module-signing/. Skipping module signing (Common for non-Secure Boot)."; \
	fi
	# --- end auto sign block ---

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

uninstall:
	@$(MAKE) --no-print-directory deconfigure
	@sudo rm -f $(MDIR)/$(MODNAME).ko
	@sudo depmod -a
	@echo "Uninstalled $(MODNAME) and cleaned up related configuration."

install: all
	sudo install -d $(MDIR)
	sudo install -m 644 src/$(MODNAME).ko $(MDIR)
	sudo depmod -a
	@$(MAKE) --no-print-directory configure

# Post-install setup shared by the plain install and the DKMS install. Kept as its
# own target so the two paths cannot drift apart: everything after the .ko is in
# place is identical either way.
configure:
	@# Drop any previously loaded build first, otherwise the modprobe below is a
	@# no-op and a reinstall or DKMS upgrade silently keeps running the old .ko.
	@sudo rmmod $(MODNAME) 2>/dev/null || true
	@sudo rmmod acer_wmi 2>/dev/null || true
	@echo "blacklist acer_wmi" | sudo tee /etc/modprobe.d/blacklist-acer_wmi.conf > /dev/null
	@echo "$(MODNAME)" | sudo tee /etc/modules-load.d/$(MODNAME).conf > /dev/null
	sudo modprobe $(MODNAME)
	@sleep 2
	@sudo cp linuwu_sense.service /etc/systemd/system/
	@sudo systemctl daemon-reload
	@sudo systemctl enable linuwu_sense.service
	@sudo systemctl start linuwu_sense.service
	@echo "Setting up group and permissions..."
	@echo "Detected user: $(REAL_USER)"
	@if ! getent group linuwu_sense >/dev/null; then \
		sudo groupadd linuwu_sense; \
	fi
	sudo usermod -aG linuwu_sense $(REAL_USER)
	@echo "Setting permissions via tmpfiles..."
	@model_path=$$(ls /sys/module/$(MODNAME)/drivers/platform:acer-wmi/acer-wmi/ | grep -E 'predator_sense|nitro_sense' || true); \
	if [ -n "$$model_path" ]; then \
		echo "Detected model directory: $$model_path"; \
		conf_file="/etc/tmpfiles.d/$(MODNAME).conf"; \
		[ -f $$conf_file ] || sudo touch $$conf_file; \
		if echo "$$model_path" | grep -q "nitro_sense"; then \
			supported_fields="fan_speed battery_limiter battery_calibration usb_charging"; \
		else \
			supported_fields="backlight_timeout battery_calibration battery_limiter boot_animation_sound fan_speed lcd_override usb_charging"; \
		fi; \
		for f in $$supported_fields; do \
			entry="f /sys/module/$(MODNAME)/drivers/platform:acer-wmi/acer-wmi/$$model_path/$$f 0660 root $(MODNAME)"; \
			grep -qxF "$$entry" $$conf_file || echo "$$entry" | sudo tee -a $$conf_file > /dev/null; \
		done; \
		kb_base="/sys/module/$(MODNAME)/drivers/platform:acer-wmi/acer-wmi/four_zoned_kb"; \
		if [ -d "$$kb_base" ]; then \
			for z in four_zone_mode per_zone_mode; do \
				entry="f $$kb_base/$$z 0660 root $(MODNAME)"; \
				grep -qxF "$$entry" $$conf_file || echo "$$entry" | sudo tee -a $$conf_file > /dev/null; \
			done; \
		fi; \
		sudo systemd-tmpfiles --create $$conf_file; \
	else \
		echo "Warning: Could not detect predator_sense or nitro_sense in sysfs."; \
	fi
	@echo "Module $(MODNAME) installed and configured to load at boot."

# Reverses configure. Split out for the same reason.
deconfigure:
	@sudo rm -f /etc/modules-load.d/$(MODNAME).conf
	@sudo rm -f /etc/modprobe.d/blacklist-acer_wmi.conf
	@sudo systemctl stop linuwu_sense.service 2>/dev/null || true
	@sudo systemctl disable linuwu_sense.service 2>/dev/null || true
	@sudo rm -f /etc/systemd/system/linuwu_sense.service
	@sudo systemctl daemon-reload
	@sudo rmmod $(MODNAME) 2>/dev/null || true
	@sudo modprobe acer_wmi
	@echo "Removing current user from linuwu_sense group if exists..."
	@if getent group linuwu_sense >/dev/null; then \
		sudo gpasswd -d $(REAL_USER) linuwu_sense || true; \
		sudo groupdel linuwu_sense || true; \
	else \
		echo "Group linuwu_sense does not exist."; \
	fi
	@sudo rm -f /etc/tmpfiles.d/$(MODNAME).conf

# ---------------------------------------------------------------------------
# DKMS
#
# Registers the module with DKMS so it is rebuilt automatically on every kernel
# upgrade. Without this, an Ubuntu kernel update leaves the machine with no
# linuwu_sense until someone rebuilds it by hand -- which on a headless box means
# losing remote fan/battery control until you notice.
# ---------------------------------------------------------------------------
# DKMS_VER comes from dkms.conf. If that lookup ever fails, DKMS_SRC collapses to
# "/usr/src/linuwu-sense-" and the rm -rf below would target the wrong path, so
# refuse to run rather than guess.
check-dkms-ver:
	@if [ -z "$(DKMS_VER)" ]; then \
		echo "ERROR: could not read PACKAGE_VERSION from dkms.conf (run make from the project root)."; \
		exit 1; \
	fi

dkms-install: check-dkms-ver
	@echo "Installing $(DKMS_NAME) $(DKMS_VER) into DKMS..."
	@sudo dkms remove -m $(DKMS_NAME) -v $(DKMS_VER) --all 2>/dev/null || true
	sudo rm -rf $(DKMS_SRC)
	sudo install -d $(DKMS_SRC)/src
	sudo install -m 644 src/$(MODNAME).c $(DKMS_SRC)/src/
	sudo install -m 644 Makefile dkms.conf linuwu_sense.service $(DKMS_SRC)/
	sudo dkms add -m $(DKMS_NAME) -v $(DKMS_VER)
	sudo dkms build -m $(DKMS_NAME) -v $(DKMS_VER)
	sudo dkms install -m $(DKMS_NAME) -v $(DKMS_VER)
	@$(MAKE) --no-print-directory configure
	@echo "DKMS install complete -- the module will rebuild itself on kernel upgrades."

dkms-uninstall: check-dkms-ver
	@$(MAKE) --no-print-directory deconfigure
	@sudo dkms remove -m $(DKMS_NAME) -v $(DKMS_VER) --all 2>/dev/null || true
	sudo rm -rf $(DKMS_SRC)
	@sudo depmod -a
	@echo "Removed $(DKMS_NAME) from DKMS."

dkms-status:
	@dkms status -m $(DKMS_NAME) || true

.PHONY: all clean install uninstall configure deconfigure \
	check-dkms-ver dkms-install dkms-uninstall dkms-status
