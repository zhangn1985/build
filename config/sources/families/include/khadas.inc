ARCH=arm64
OFFSET=16
ATF_COMPILE="no"
BOOTBRANCH='tag:v2020.01'
KERNELBRANCH='branch:linux-5.5.y'
KERNELPATCHDIR=khadas
BOOTPATCHDIR=khadas
LINUXFAMILY=khadas
BOOTENV_FILE='khadas-default.txt'

family_firmware_install() {
	cp -rpf $SRC/cache/sources/khadas-blobs/firmware/* $1
}
