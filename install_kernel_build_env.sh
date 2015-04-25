#!/bin/bash
# Script to setup env to build kernel and modules for QEMU
# http://www.wiki.xilinx.com/Build+kernel
apt-get update
apt-get upgrade
apt-get install -y git build-essential gcc-arm-linux-gnueabi u-boot-tools
git clone https://github.com/Xilinx/linux-xlnx.git
cd linux-xlnx/
# Switch to tag from Xilinx git repo (tag xilinx-v14.7 =  kernel 3.10.0)
git checkout xilinx-v14.7
export CROSS_COMPILE=arm-linux-gnueabi-
make mrproper
make ARCH=arm xilinx_zynq_defconfig
# Enable building of TUN module
sed -i -r "s/# CONFIG_TUN is not set/CONFIG_TUN=m/" .config
# Build kernel and modules
#make ARCH=arm
# Build kernel
#make ARCH=arm UIMAGE_LOADADDR=0x8000 uImage
# Build only modules
#make ARCH=arm modules
