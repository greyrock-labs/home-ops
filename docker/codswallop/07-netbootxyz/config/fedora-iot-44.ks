# The ISO's osbuild.ks, pointed at the extracted tree over HTTP instead of the disc.
ostreesetup --osname=fedora-iot --url=http://10.1.25.22/fedora-iot/44/ostree/repo --ref=fedora/stable/x86_64/iot --remote=fedora-iot --nogpg
