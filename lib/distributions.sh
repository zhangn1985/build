#!/bin/bash
#
# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# This file is a part of the Armbian build script
# https://github.com/armbian/build/

# Functions:
# install_common
# install_rclocal
# install_distribution_specific
# post_debootstrap_tweaks

install_common()
{
	display_alert "Applying common tweaks" "" "info"

	# install rootfs encryption related packages separate to not break packages cache
	if [[ $CRYPTROOT_ENABLE == yes ]]; then
		display_alert "Installing rootfs encryption related packages" "cryptsetup" "info"
		chroot "${SDCARD}" /bin/bash -c "apt -y -qq --no-install-recommends install cryptsetup" \
		>> "${DEST}"/debug/install.log 2>&1
		if [[ $CRYPTROOT_SSH_UNLOCK == yes ]]; then
			display_alert "Installing rootfs encryption related packages" "dropbear-initramfs" "info"
			chroot "${SDCARD}" /bin/bash -c "apt -y -qq --no-install-recommends install dropbear-initramfs " \
			>> "${DEST}"/debug/install.log 2>&1
		fi

	fi

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> "${SDCARD}"/etc/fstab
	# required for initramfs-tools-core on Stretch since it ignores the / fstab entry
	echo "/dev/mmcblk0p2 /usr $ROOTFS_TYPE defaults 0 2" >> "${SDCARD}"/etc/fstab

	# adjust initramfs dropbear configuration
	# needs to be done before kernel installation, else it won't be in the initrd image
	if [[ $CRYPTROOT_ENABLE == yes && $CRYPTROOT_SSH_UNLOCK == yes ]]; then
		# Set the port of the dropbear ssh deamon in the initramfs to a different one if configured
		# this avoids the typical 'host key changed warning' - `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
		[[ -f $SDCARD/etc/dropbear-initramfs/config ]] && \
		sed -i 's/^#DROPBEAR_OPTIONS=/DROPBEAR_OPTIONS="-p '"${CRYPTROOT_SSH_UNLOCK_PORT}"'"/' \
		"${SDCARD}"/etc/dropbear-initramfs/config

		# setup dropbear authorized_keys, either provided by userpatches or generated
		if [[ -f $USERPATCHES_PATH/dropbear_authorized_keys ]]; then
			cp "$USERPATCHES_PATH"/dropbear_authorized_keys "${SDCARD}"/etc/dropbear-initramfs/authorized_keys
		else
			# generate a default ssh key for login on dropbear in initramfs
			# this key should be changed by the user on first login
			display_alert "Generating a new SSH key pair for dropbear (initramfs)" "" ""
			ssh-keygen -t ecdsa -f "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa \
			-N '' -O force-command=cryptroot-unlock -C 'AUTOGENERATED_BY_ARMBIAN_BUILD'  >> "${DEST}"/debug/install.log 2>&1

			# /usr/share/initramfs-tools/hooks/dropbear will automatically add 'id_ecdsa.pub' to authorized_keys file
			# during mkinitramfs of update-initramfs
			#cat $SDCARD/etc/dropbear-initramfs/id_ecdsa.pub > $SDCARD/etc/dropbear-initramfs/authorized_keys
			CRYPTROOT_SSH_UNLOCK_KEY_NAME="Armbian_${REVISION}_${BOARD^}_${RELEASE}_${BRANCH}_${VER/-$LINUXFAMILY/}".key
			# copy dropbear ssh key to image output dir for convenience
			cp "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa "${DEST}/images/${CRYPTROOT_SSH_UNLOCK_KEY_NAME}"
			display_alert "SSH private key for dropbear (initramfs) has been copied to:" \
			"$DEST/images/$CRYPTROOT_SSH_UNLOCK_KEY_NAME" "info"
		fi
	fi

	# create modules file
	local modules=MODULES_${BRANCH^^}
	if [[ -n ${!modules} ]]; then
		tr ' ' '\n' <<< ${!modules} > "${SDCARD}"/etc/modules
	elif [[ -n ${MODULES} ]]; then
		tr ' ' '\n' <<< "$MODULES" > "${SDCARD}"/etc/modules
	fi

	# create blacklist files
	local blacklist=MODULES_BLACKLIST_${BRANCH^^}
	if [[ -n ${!blacklist} ]]; then
		tr ' ' '\n' <<< ${!blacklist} | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	elif [[ -n ${MODULES_BLACKLIST} ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	fi

	# configure MIN / MAX speed for cpufrequtils
	cat <<-EOF > "${SDCARD}"/etc/default/cpufrequtils	
	ENABLE=true
	MIN_SPEED=$CPUMIN
	MAX_SPEED=$CPUMAX
	GOVERNOR=$GOVERNOR
	EOF

	if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
	# remove default interfaces file if present
	# before installing board support package
	rm -f "${SDCARD}"/etc/network/interfaces

	mkdir -p "${SDCARD}"/selinux

	# remove Ubuntu's legal text
	[[ -f $SDCARD/etc/legal ]] && rm "${SDCARD}"/etc/legal

	# Prevent loading paralel printer port drivers which we don't need here.
	# Suppress boot error if kernel modules are absent
	if [[ -f $SDCARD/etc/modules-load.d/cups-filters.conf ]]; then
		sed "s/^lp/#lp/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^ppdev/#ppdev/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^parport_pc/#parport_pc/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
	fi

	# console fix due to Debian bug
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i "${SDCARD}"/etc/default/console-setup

	# add the /dev/urandom path to the rng config file
	echo "HRNGDEVICE=/dev/urandom" >> "${SDCARD}"/etc/default/rng-tools

	# ping needs privileged action to be able to create raw network socket
	# this is working properly but not with (at least) Debian Buster
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /bin/ping"
	fi

	# change time zone data
	echo "${TZDATA}" > "${SDCARD}"/etc/timezone
	chroot "${SDCARD}" /bin/bash -c "dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1"

	# set root password
	chroot "${SDCARD}" /bin/bash -c "(echo $ROOTPWD;echo $ROOTPWD;) | passwd root >/dev/null 2>&1"

	# force change root password at first login
	chroot "${SDCARD}" /bin/bash -c "chage -d 0 root"

	# change console welcome text
	echo -e "Armbian ${REVISION} ${RELEASE^} \\l \n" > "${SDCARD}"/etc/issue
	echo "Armbian ${REVISION} ${RELEASE^}" > "${SDCARD}"/etc/issue.net

	# enable few bash aliases enabled in Ubuntu by default to make it even
	sed "s/#alias ll='ls -l'/alias ll='ls -l'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias la='ls -A'/alias la='ls -A'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias l='ls -CF'/alias l='ls -CF'/" -i "${SDCARD}"/etc/skel/.bashrc
	# root user is already there. Copy bashrc there as well
	cp "${SDCARD}"/etc/skel/.bashrc "${SDCARD}"/root

	# display welcome message at first root login
	touch "${SDCARD}"/root/.not_logged_in_yet

	if [[ ${DESKTOP_AUTOLOGIN} != no ]]; then
		# set desktop autologin
		touch "${SDCARD}"/root/.desktop_autologin
	fi

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}
	cp "${SRC}/config/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"

	if [[ -n $BOOTENV_FILE ]]; then
		if [[ -f $USERPATCHES_PATH/bootenv/$BOOTENV_FILE ]]; then
			cp "$USERPATCHES_PATH/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
		elif [[ -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
			cp "${SRC}/config/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
		fi
	fi

	# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
	# instead of copying sunxi-specific template
	if [[ $ROOTFS_TYPE == nfs ]]; then
		display_alert "Copying NFS boot script template"
		if [[ -f $USERPATCHES_PATH/nfs-boot.cmd ]]; then
			cp "$USERPATCHES_PATH"/nfs-boot.cmd "${SDCARD}"/boot/boot.cmd
		else
			cp "${SRC}"/config/templates/nfs-boot.cmd.template "${SDCARD}"/boot/boot.cmd
		fi
	fi

	[[ -n $OVERLAY_PREFIX && -f $SDCARD/boot/armbianEnv.txt ]] && \
		echo "overlay_prefix=$OVERLAY_PREFIX" >> "${SDCARD}"/boot/armbianEnv.txt

	[[ -n $DEFAULT_OVERLAYS && -f $SDCARD/boot/armbianEnv.txt ]] && \
		echo "overlays=${DEFAULT_OVERLAYS//,/ }" >> "${SDCARD}"/boot/armbianEnv.txt

	[[ -n $BOOT_FDT_FILE && -f $SDCARD/boot/armbianEnv.txt ]] && \
		echo "fdtfile=${BOOT_FDT_FILE}" >> "${SDCARD}/boot/armbianEnv.txt"

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > "${SDCARD}"/etc/fake-hwclock.data

	echo "${HOST}" > "${SDCARD}"/etc/hostname

	# set hostname in hosts file
	cat <<-EOF > "${SDCARD}"/etc/hosts
	127.0.0.1   localhost $HOST
	::1         localhost $HOST ip6-localhost ip6-loopback
	fe00::0     ip6-localnet
	ff00::0     ip6-mcastprefix
	ff02::1     ip6-allnodes
	ff02::2     ip6-allrouters
	EOF

	# install kernel and u-boot packages
	[[ $INSTALL_KERNEL == yes ]] && install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb"
	install_deb_chroot "${DEB_STORAGE}/${CHOSEN_UBOOT}_${UBOOT_VERSION}+${SUBREVISION}_${ARCH}.deb"


	if [[ $BUILD_DESKTOP == yes ]]; then
		install_deb_chroot "${DEB_STORAGE}/$RELEASE/armbian-${RELEASE}-desktop_${REVISION}_all.deb"
		# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
		desktop_postinstall
	fi

	if [[ $INSTALL_HEADERS == yes ]]; then
		install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb"
	fi

	if [[ $BUILD_MINIMAL != yes ]] && [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
		install_deb_chroot "${DEB_STORAGE}/armbian-config_${REVISION}_all.deb"
	fi

	if [[ -f ${DEB_STORAGE}/${CHOSEN_FIRMWARE}_${REVISION}_all.deb ]]; then
		install_deb_chroot "${DEB_STORAGE}/${CHOSEN_FIRMWARE}_${REVISION}_all.deb"
	fi

	if [[ -f ${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
		[[ $INSTALL_KERNEL == yes ]] && install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb"
	fi

	if [[ -f ${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb && $INSTALL_KSRC == yes ]]; then
		install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb"
	fi

	if [[ $WIREGUARD == yes ]]; then
		# install wireguard tools
		chroot "${SDCARD}" /bin/bash -c "apt -y -qq install wireguard-tools --no-install-recommends" >> "${DEST}"/debug/install.log 2>&1
	fi

	if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
		# install board support package
		install_deb_chroot "${DEB_STORAGE}/$RELEASE/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}.deb" >> "${DEST}"/debug/install.log 2>&1
	else
		rm -rf "${SRC}"/packages/bsp/common/etc/NetworkManager/
		rm -rf "${SRC}"/packages/bsp/common/etc/X11/
		rm -rf "${SRC}"/packages/bsp/common/etc/apt/apt.conf.d/81-armbian-no-languages
		rm -rf "${SRC}"/packages/bsp/common/etc/cron.d/
		rm -rf "${SRC}"/packages/bsp/common/etc/cron.daily/
		rm -rf "${SRC}"/packages/bsp/common/etc/default/armbian-ramlog.dpkg-dist
		rm -rf "${SRC}"/packages/bsp/common/etc/default/armbian-zram-config.dpkg-dist
		rm -rf "${SRC}"/packages/bsp/common/etc/initramfs/
		rm -rf "${SRC}"/packages/bsp/common/etc/kernel/preinst.d/
		rm -rf "${SRC}"/packages/bsp/common/etc/modprobe.d/
		rm -rf "${SRC}"/packages/bsp/common/etc/network/
		rm -rf "${SRC}"/packages/bsp/common/etc/profile.d/armbian-lang.sh
		rm -rf "${SRC}"/packages/bsp/common/etc/systemd/
		rm -rf "${SRC}"/packages/bsp/common/etc/udev/
		rm -rf "${SRC}"/packages/bsp/common/etc/update-motd.d/41-armbian-config
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-firstrun-config.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-firstrun.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-hardware-monitor.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-hardware-optimize.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-ramlog.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/armbian-zram-config.service
		rm -rf "${SRC}"/packages/bsp/common/lib/systemd/system/systemd-journald.service.d/
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-firstrun
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-firstrun-config
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-hardware-monitor
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-hardware-optimization
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-ramlog
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-truncate-logs
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/armbian/armbian-zram-config
		rm -rf "${SRC}"/packages/bsp/common/usr/lib/chromium-browser/
		rm -rf "${SRC}"/packages/bsp/common/etc/initramfs/post-update.d/99-uboot
		rsync -a "${SRC}"/packages/bsp/common/* "${SDCARD}"/
		cat <<-EOF > "${SDCARD}"/etc/armbian-release
		# PLEASE DO NOT EDIT THIS FILE
		BOARD=$BOARD
		BOARD_NAME="$BOARD_NAME"
		BOARDFAMILY=${BOARDFAMILY}
		BUILD_REPOSITORY_URL=${BUILD_REPOSITORY_URL}
		BUILD_REPOSITORY_COMMIT=${BUILD_REPOSITORY_COMMIT}
		DISTRIBUTION_CODENAME=${RELEASE}
		DISTRIBUTION_STATUS=${DISTRIBUTION_STATUS}
		VERSION=$REVISION
		LINUXFAMILY=$LINUXFAMILY
		BRANCH=$BRANCH
		ARCH=$ARCHITECTURE
		IMAGE_TYPE=$IMAGE_TYPE
		BOARD_TYPE=$BOARD_TYPE
		INITRD_ARCH=$INITRD_ARCH
		KERNEL_IMAGE_TYPE=$KERNEL_IMAGE_TYPE
		EOF
	fi

	# freeze armbian packages
	if [[ $BSPFREEZE == yes ]]; then
		display_alert "Freezing Armbian packages" "$BOARD" "info"
		chroot "${SDCARD}" /bin/bash -c "apt-mark hold ${CHOSEN_KERNEL} ${CHOSEN_KERNEL/image/headers} \
			linux-u-boot-${BOARD}-${BRANCH} ${CHOSEN_KERNEL/image/dtb}" >> "${DEST}"/debug/install.log 2>&1
	fi

	# copy boot splash images
	cp "${SRC}"/packages/blobs/splash/armbian-u-boot.bmp "${SDCARD}"/boot/boot.bmp
	cp "${SRC}"/packages/blobs/splash/armbian-desktop.png "${SDCARD}"/boot/boot-desktop.png

	# execute $LINUXFAMILY-specific tweaks
	[[ $(type -t family_tweaks) == function ]] && family_tweaks

	# enable additional services
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-firstrun.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-firstrun-config.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-zram-config.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-hardware-optimize.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-ramlog.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-resize-filesystem.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable armbian-hardware-monitor.service >/dev/null 2>&1"

	if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
	# copy "first run automated config, optional user configured"
 	cp "${SRC}"/packages/bsp/armbian_first_run.txt.template "${SDCARD}"/boot/armbian_first_run.txt.template

	# switch to beta repository at this stage if building nightly images
	[[ $IMAGE_TYPE == nightly ]] \
	&& echo "deb http://beta.armbian.com $RELEASE main ${RELEASE}-utils ${RELEASE}-desktop" \
	> "${SDCARD}"/etc/apt/sources.list.d/armbian.list

	# Cosmetic fix [FAILED] Failed to start Set console font and keymap at first boot
	[[ -f $SDCARD/etc/console-setup/cached_setup_font.sh ]] \
	&& sed -i "s/^printf '.*/printf '\\\033\%\%G'/g" "${SDCARD}"/etc/console-setup/cached_setup_font.sh
	[[ -f $SDCARD/etc/console-setup/cached_setup_terminal.sh ]] \
	&& sed -i "s/^printf '.*/printf '\\\033\%\%G'/g" "${SDCARD}"/etc/console-setup/cached_setup_terminal.sh
	[[ -f $SDCARD/etc/console-setup/cached_setup_keyboard.sh ]] \
	&& sed -i "s/-u/-x'/g" "${SDCARD}"/etc/console-setup/cached_setup_keyboard.sh

	# fix for https://bugs.launchpad.net/ubuntu/+source/blueman/+bug/1542723
	chroot "${SDCARD}" /bin/bash -c "chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper"
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /usr/lib/dbus-1.0/dbus-daemon-launch-helper"

	# disable low-level kernel messages for non betas
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" "${SDCARD}"/etc/sysctl.conf
	fi

	# disable repeated messages due to xconsole not being installed.
	[[ -f $SDCARD/etc/rsyslog.d/50-default.conf ]] && \
	sed '/daemon\.\*\;mail.*/,/xconsole/ s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.d/50-default.conf

	# disable deprecated parameter
	sed '/.*$KLogPermitNonKernelFacility.*/,// s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.conf
	fi

	# enable getty on multiple serial consoles
	# and adjust the speed if it is defined and different than 115200
	#
	# example: SERIALCON="ttyS0:15000000,ttyGS1"
	#
	ifs=$IFS
	for i in $(echo ${SERIALCON:-'ttyS0'} | sed "s/,/ /g")
	do
		IFS=':' read -r -a array <<< "$i"
		# add serial console to secure tty list
		[ -z "$(grep -w '^${array[0]}' "${SDCARD}"/etc/securetty 2> /dev/null)" ] && \
		echo "${array[0]}" >>  "${SDCARD}"/etc/securetty
		if [[ ${array[1]} != "115200" && -n ${array[1]} ]]; then
			# make a copy, fix speed and enable
			cp "${SDCARD}"/lib/systemd/system/serial-getty@.service \
			"${SDCARD}"/lib/systemd/system/serial-getty@${array[0]}.service
			sed -i "s/--keep-baud 115200/--keep-baud ${array[1]},115200/" \
			"${SDCARD}"/lib/systemd/system/serial-getty@${array[0]}.service
		fi
		display_alert "Enabling serial console" "${array[0]}" "info"
		chroot "${SDCARD}" /bin/bash -c "systemctl daemon-reload" >> "${DEST}"/debug/install.log 2>&1
		chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable serial-getty@${array[0]}.service" \
		>> "${DEST}"/debug/install.log 2>&1
		if [[ ${array[0]} == "ttyGS0" && $LINUXFAMILY == sun8i && $BRANCH == default ]]; then
			mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d
			cat <<-EOF > "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d/10-switch-role.conf
			[Service]
			ExecStartPre=-/bin/sh -c "echo 2 > /sys/bus/platform/devices/sunxi_usb_udc/otg_role"
			EOF
		fi
	done
	IFS=$ifs

	if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
	[[ $LINUXFAMILY == sun*i ]] && mkdir -p "${SDCARD}"/boot/overlay-user

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch "${SDCARD}"/var/swap

	# install initial asound.state if defined
	mkdir -p "${SDCARD}"/var/lib/alsa/
	[[ -n $ASOUND_STATE ]] && cp "${SRC}/packages/blobs/asound.state/${ASOUND_STATE}" "${SDCARD}"/var/lib/alsa/asound.state

	# save initial armbian-release state
	cp "${SDCARD}"/etc/armbian-release "${SDCARD}"/etc/armbian-image-release

	# DNS fix. package resolvconf is not available everywhere
	if [ -d /etc/resolvconf/resolv.conf.d ]; then
		echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolvconf/resolv.conf.d/head
	fi

	# permit root login via SSH for the first boot
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' "${SDCARD}"/etc/ssh/sshd_config

	# enable PubkeyAuthentication
	sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "${SDCARD}"/etc/ssh/sshd_config

	# configure network manager
	sed "s/managed=\(.*\)/managed=true/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

	# remove network manager defaults to handle eth by default
	rm -f "${SDCARD}"/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

	# avahi daemon defaults if exists
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service ]] && \
	cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service "${SDCARD}"/etc/avahi/services/
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service ]] && \
	cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service "${SDCARD}"/etc/avahi/services/

	# Just regular DNS and maintain /etc/resolv.conf as a file
	sed "/dns/d" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
	sed "s/\[main\]/\[main\]\ndns=default\nrc-manager=file/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
	if [[ -n $NM_IGNORE_DEVICES ]]; then
		mkdir -p "${SDCARD}"/etc/NetworkManager/conf.d/
		cat <<-EOF > "${SDCARD}"/etc/NetworkManager/conf.d/10-ignore-interfaces.conf
		[keyfile]
		unmanaged-devices=$NM_IGNORE_DEVICES
		EOF
	fi

	# nsswitch settings for sane DNS behavior: remove resolve, assure libnss-myhostname support
	sed "s/hosts\:.*/hosts:          files mymachines dns myhostname/g" -i "${SDCARD}"/etc/nsswitch.conf
	fi
}




install_rclocal()
{

		cat <<-EOF > "${SDCARD}"/etc/rc.local
		#!/bin/sh -e
		#
		# rc.local
		#
		# This script is executed at the end of each multiuser runlevel.
		# Make sure that the script will "exit 0" on success or any other
		# value on error.
		#
		# In order to enable or disable this script just change the execution
		# bits.
		#
		# By default this script does nothing.

		exit 0
		EOF
		chmod +x "${SDCARD}"/etc/rc.local

}




install_distribution_specific()
{

	display_alert "Applying distribution specific tweaks for" "$RELEASE" "info"

	case $RELEASE in

	xenial)

			# remove legal info from Ubuntu
			[[ -f $SDCARD/etc/legal ]] && rm "${SDCARD}"/etc/legal

			# ureadahead needs kernel tracing options that AFAIK are present only in mainline. disable
			chroot "${SDCARD}" /bin/bash -c \
			"systemctl --no-reload mask ondemand.service ureadahead.service >/dev/null 2>&1"
			chroot "${SDCARD}" /bin/bash -c \
			"systemctl --no-reload mask setserial.service etc-setserial.service >/dev/null 2>&1"

		;;

	stretch|buster)
		if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
			# remove doubled uname from motd
			[[ -f $SDCARD/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname
			# rc.local is not existing but one might need it
			install_rclocal
		fi
		;;

	bullseye)

			# remove doubled uname from motd
			[[ -f $SDCARD/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname
			# rc.local is not existing but one might need it
			install_rclocal
			# fix missing versioning
			[[ $(grep -L "VERSION_ID=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION_ID="11"' >> "${SDCARD}"/etc/os-release
			[[ $(grep -L "VERSION=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION="11 (bullseye)"' >> "${SDCARD}"/etc/os-release

			# remove security updates repository since it does not exists yet
			sed '/security/ d' -i "${SDCARD}"/etc/apt/sources.list

		;;
	bionic|eoan|focal)

			# remove doubled uname from motd
			[[ -f $SDCARD/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname

			# remove motd news from motd.ubuntu.com
			[[ -f $SDCARD/etc/default/motd-news ]] && sed -i "s/^ENABLED=.*/ENABLED=0/" "${SDCARD}"/etc/default/motd-news

			# rc.local is not existing but one might need it
			install_rclocal

			# Basic Netplan config. Let NetworkManager manage all devices on this system
			[[ -d "${SDCARD}"/etc/netplan ]] && cat <<-EOF > "${SDCARD}"/etc/netplan/armbian-default.yaml
			network:
			  version: 2
			  renderer: NetworkManager
			EOF

			# DNS fix
			sed -i "s/#DNS=.*/DNS=$NAMESERVER/g" "${SDCARD}"/etc/systemd/resolved.conf

			# Journal service adjustements
			sed -i "s/#Storage=.*/Storage=volatile/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#Compress=.*/Compress=yes/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitIntervalSec=.*/RateLimitIntervalSec=30s/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitBurst=.*/RateLimitBurst=10000/g" "${SDCARD}"/etc/systemd/journald.conf

			# disable conflicting services
			chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload mask ondemand.service >/dev/null 2>&1"

		;;
	
	esac

}




post_debootstrap_tweaks()
{
	if [[ x${USE_ARMBIAN_CONFIG} == x || ${USE_ARMBIAN_CONFIG} = "yes" ]]; then
	# remove service start blockers and QEMU binary
	rm -f "${SDCARD}"/sbin/initctl "${SDCARD}"/sbin/start-stop-daemon
	chroot "${SDCARD}" /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/initctl"
	chroot "${SDCARD}" /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/start-stop-daemon"
	rm -f "${SDCARD}"/usr/sbin/policy-rc.d "${SDCARD}/usr/bin/${QEMU_BINARY}"
	fi
}
