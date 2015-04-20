#!/bin/bash
# Script to install and configure QEMU to emulate Zedboard development board with Linaro Nano (Ubuntu) as OS
if [[ "$EUID" -ne 0 ]]; then
	echo "Script must run as root"
	exit 1
fi
set -e
DIR=$(pwd)
apt-get update
apt-get upgrade

# QEMU dependencies
apt-get install -y build-essential git flex bison libglib2.0-dev libpixman-1-dev zlib1g-dev

mkdir qemu_zedboard
cd qemu_zedboard
# Cloned the Xilinx QEMU
# "./configure" failed to complete without --disable-error option
git clone git://github.com/Xilinx/qemu.git
cd qemu
# Ubuntu does not support the "DTC devel" package that QEMU requires (device-tree-compiler package doesn't help). Using submodule to fix it
git submodule update --init dtc
./configure --target-list="arm-softmmu,microblazeel-softmmu" --enable-fdt --disable-kvm --disable-werror
make

# Download prebuilt Linux kernel images from Xilinx from http://www.wiki.xilinx.com/Zynq+Releases
# Note: images above 14.7 failed to start with Segmentation fault
cd ..
mkdir zynq-14.7
cd zynq-14.7
wget http://www.wiki.xilinx.com/file/view/14.7-release.tar.xz/463186206/14.7-release.tar.xz
tar xvJf 14.7-release.tar.xz
rm 14.7-release.tar.xz

# Edit bootargs in device tree
# Device tree compiler to convert DTB->DTS and edit bootargs
apt-get install -y device-tree-compiler
# DTB to DTC
cd zed
dtc -I dtb -O dts -o devicetree.dts devicetree.dtb
# Replace line:
# bootargs = "console=ttyPS0,115200 root=/dev/ram rw earlyprintk";
# with:
# bootargs = "console=ttyPS0,115200 root=/dev/nfs rw nfsroot=10.0.2.2:/srv/nfs,tcp,nolock ip=10.0.2.15::10.0.2.1:255.255.255.0 earlyprintk";
sed -i "s/root=\/dev\/ram rw/root=\/dev\/nfs rw nfsroot=10.0.2.2:\/srv\/nfs,tcp,nolock ip=10.0.2.15::255.255.255.0/" devicetree.dts
# DTS to DTB
dtc -I dts -O dtb -o devicetree.dtb devicetree.dts

# QEMU needs initramfs without the U-Boot header
# U-Boot header can be removed from uramdisk.image.gz with  command
# dd if=./uramdisk.image.gz of=./ramdisk.image.gz skip=16 bs=4

# Install and configure NFS server
apt-get -y install nfs-kernel-server
mkdir -p /srv/nfs/
chown nobody:nogroup /srv/nfs
echo "/srv/nfs 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,insecure)" >> /etc/exports
exportfs -av
service nfs-kernel-server restart

# Script to create network (tunnel) to Zedboard on host
# Enable IP forwarding, NAT on host
cd qemu_zedboard
touch run_tun_client.sh
chmod +x run_tun_client.sh
echo '#!/bin/bash
sleep 30
nc -z 127.0.0.1 10000
while [[ $EXIT_CODE == 0 ]]; do
    sleep 5
    nc -z 127.0.0.1 10000
done
socat TCP:127.0.0.1:10000 TUN:192.168.1.1/24,up &
sleep 5
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT' > run_tun_client.sh

# Extract Linaro Nano to NFS directory
cd $DIR
wget http://releases.linaro.org/14.10/ubuntu/trusty-images/nano/linaro-trusty-nano-20141024-684.tar.gz
tar --strip-components=1 -C /srv/nfs -xzpf linaro-trusty-nano-20141024-684.tar.gz
rm linaro-trusty-nano-20141024-684.tar.gz

# Interface TUN dependencies
apt-get install -y socat curl
wget http://launchpadlibrarian.net/162304803/libwrap0_7.6.q-25_armhf.deb -P /srv/nfs/root
wget https://launchpad.net/ubuntu/+source/socat/1.7.2.3-1/+build/5544762/+files/socat_1.7.2.3-1_armhf.deb -P /srv/nfs/root
curl --user robonect-robot:orO4D6oJxWU2BYSKV0 https://bitbucket.org/denya/robonect-deploy/raw/master/qemu/tun.ko -o /srv/nfs/root/tun.ko

# Modify rc.local script on guest
# Load kernel module fot TUN interface, network env setup
sed -i "s/# Generate.*/insmod \/root\/tun.ko/" /srv/nfs/etc/rc.local
sed -i "s/test.*/\/root\/create_net.sh \&/" /srv/nfs/etc/rc.local

# Script to create network (tunnel) to Zedboard on guest
touch /srv/nfs/root/run_tun_server.sh
chmod +x /srv/nfs/root/run_tun_server.sh
echo '#!/bin/bash
socat -d -d TCP-LISTEN:10000,reuseaddr TUN:192.168.1.2/24,up &
while [[ -d "/sys/class/net/tun0/" ]]; do
	route add default gw 192.168.1.1 tun0
done' > /srv/nfs/root/run_tun_server.sh

# Set DNS server on guest
echo "nameserver 77.88.8.8" > /srv/nfs/etc/resolv.conf

# Install socat, create network (tunnel) to to host, self-deleted
touch /srv/nfs/root/create_net.sh
chmod +x /srv/nfs/root/create_net.sh
echo '#!/bin/bash
sleep 10
dpkg -i /root/libwrap0_7.6.q-25_armhf.deb
dpkg -i /root/socat_1.7.2.3-1_armhf.deb
rm /root/libwrap0_7.6.q-25_armhf.deb /root/socat_1.7.2.3-1_armhf.deb
sed -i "s/\/root\/create_net.sh \&/\/root\/run_tun_server.sh \&/" /etc/rc.local
/root/run_tun_server.sh &
rm $0' > /srv/nfs/root/create_net.sh

# Run script
cd $DIR
touch run_qemu.sh
chmod +x run_qemu.sh
echo '#!/bin/bash' > run_qemu.sh
echo "run_tun_client.sh &
$DIR/qemu_zedboard/qemu/arm-softmmu/qemu-system-arm -M arm-generic-fdt -nographic -serial mon:stdio -dtb $DIR/qemu_zedboard/zynq-14.7/zed/devicetree.dtb -kernel $DIR/qemu_zedboard/zynq-14.7/uImage -machine linux=on -smp 2 -redir tcp:10000::10000 -redir tcp:50080::80" >> run_qemu.sh
echo "Done"
echo "Execute ./run_qemu.sh to run QEMU"
