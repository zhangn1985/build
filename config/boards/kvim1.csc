# Amlogic S905x quad core 2Gb RAM SoC eMMC
BOARD_NAME="Khadas VIM1"
BOARDFAMILY="vim"
BOOTCONFIG="khadas-vim_defconfig"
KERNEL_TARGET="dev"
FULL_DESKTOP="yes"

# this helper function includes postprocess for p212 and its variants.
# $1 PATH for uboot blob repo
# $2 dir name in uboot blob repo
#redefine it.
uboot_vim1_postprocess()
{
	mv u-boot.bin bl33.bin

	$1/$2/blx_fix.sh 	$1/$2/bl30.bin \
					$1/$2/zero_tmp \
					$1/$2/bl30_zero.bin \
					$1/$2/bl301.bin \
					$1/$2/bl301_zero.bin \
					$1/$2/bl30_new.bin bl30

	python $1/$2/acs_tool.pyc $1/$2/bl2.bin $1/$2/bl2_acs.bin $1/$2/acs.bin 0

	$1/$2/blx_fix.sh 	$1/$2/bl2_acs.bin \
					$1/$2/zero_tmp \
					$1/$2/bl2_zero.bin \
					$1/$2/bl21.bin \
					$1/$2/bl21_zero.bin \
					$1/$2/bl2_new.bin bl2

	$1/$2/aml_encrypt_gxl 	--bl3enc --input $1/$2/bl30_new.bin
	$1/$2/aml_encrypt_gxl 	--bl3enc --input $1/$2/bl31.img
	$1/$2/aml_encrypt_gxl 	--bl3enc --input bl33.bin

	$1/$2/aml_encrypt_gxl 	--bl2sig --input $1/$2/bl2_new.bin --output bl2.n.bin.sig

	$1/$2/aml_encrypt_gxl 	--bootmk \
						--output u-boot.bin \
						--bl2 bl2.n.bin.sig \
						--bl30 $1/$2/bl30_new.bin.enc \
						--bl31 $1/$2/bl31.img.enc \
						--bl33 bl33.bin.enc
}

uboot_custom_postprocess()
{
	uboot_vim1_postprocess $SRC/cache/sources/khadas-blobs/  vim1
}
