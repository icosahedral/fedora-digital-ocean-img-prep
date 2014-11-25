# This script will download a fedora image and then modify it 
# to prepare it for Digital Ocean's infrastructure. It uses 
# Docker to hopefully guarantee the behavior is consistent across 
# different machines.

set -eux 
mkdir -p /tmp/doimg/

docker run -i --rm --privileged -v /tmp/doimg:/tmp/doimg fedora:20 bash << 'EOF'
set -eux
WORKDIR=/tmp/tmp
TMPMNT=/tmp/tmp/mnt

# Vars for the image
XZIMGURL='http://download.fedoraproject.org/pub/fedora/linux/releases/test/21-Beta/Cloud/Images/x86_64/Fedora-Cloud-Base-20141029-21_Beta.x86_64.raw.xz'
XZIMG=$(basename $XZIMGURL) # Just the file name
IMG=${XZIMG:0:-3}           # Pull .xz off of the end

# URL for upstream DO data source file.
export DODATASOURCEURL='http://bazaar.launchpad.net/~cloud-init-dev/cloud-init/trunk/download/head:/datasourcedigitaloce-20141016153006-gm8n01q6la3stalt-1/DataSourceDigitalOcean.py'

# Create workdir and cd to it
mkdir -p $TMPMNT && cd $WORKDIR

# Get any additional rpms that we need
yum install -y gdisk wget e2fsprogs

# Get the xz image and decompress it
wget $XZIMGURL && unxz $XZIMG

# Convert to GPT
sgdisk -g -p $IMG

# Find what loop device will be used
# Create a new loop device to be used
LOOPDEV=$(losetup -f)
#LOOPDEV=/dev/loop8
LOOPDEVPART1=$LOOPDEV
#mknod -m660 /dev/loop8 b 7 8

# Find the starting byte and the total bytes in the 1st partition
PAIRS=$(partx --pairs $IMG)
eval `echo "$PAIRS" | head -n 1 | sed 's/ /\n/g'`
STARTBYTES=$((512*START))   # 512 bytes * the number of the start sector
TOTALBYTES=$((512*SECTORS)) # 512 bytes * the number of sectors in the partition

# Loopmount the first partition of the device
losetup -v --offset $STARTBYTES --sizelimit $TOTALBYTES $LOOPDEV $IMG

# Add in DOROOT label to the root partition
e2label $LOOPDEVPART1 DOROOT

# Mount it on $TMPMNT
mount $LOOPDEVPART1 $TMPMNT

# Get the DO datasource and store in the right place
# NOTE: wget doesn't work inside chroot so doing it here
pushd $TMPMNT/usr/lib/python2.7/site-packages/cloudinit/sources/
wget $DODATASOURCEURL
popd

# chroot into disk Image
chroot $TMPMNT

# Put in place the config from Digital Ocean
cat << END > /etc/cloud/cloud.cfg.d/01_digitalocean.cfg 
datasource_list: [ DigitalOcean, None ]
datasource:
 DigitalOcean:
   retries: 5
   timeout: 10
vendor_data:
   enabled: False
END

# TODO: restore selinux permissions
# For now set selinux to permissive
sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/sysconfig/selinux

# Exit the chroot
exit

# umount and tear down loop device
umount $TMPMNT
losetup -d $LOOPDEV

# finally, cp $IMG into /tmp/doimg/ on the host
cp -a $IMG /tmp/doimg/ 

EOF