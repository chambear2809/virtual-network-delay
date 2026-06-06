# Research Notes

Use these notes when changing provider assumptions. Prefer official docs over examples or forum posts.

## Linux `tc netem`

Primary references:

- `tc-netem(8)`: https://man7.org/linux/man-pages/man8/tc-netem.8.html
- `tc(8)`: https://man7.org/linux/man-pages/man8/tc.8.html

Relevant constraints:

- Netem delays packets before sending and accepts delay, jitter, loss, duplicate, reorder, corruption, rate, and slot options.
- The basic examples use `tc qdisc add/change dev eth0 root netem delay 100ms` and random packet loss percentages.
- `tc qdisc replace` is appropriate for idempotent enablement because it creates or replaces a qdisc.
- `tc qdisc del dev DEV root` removes the root qdisc.
- Kernel timer granularity and TCP behavior can affect measured results; validate with medians, not one sample.

## Docker

Primary references:

- Docker run capabilities: https://docs.docker.com/engine/containers/run/
- Compose services `cap_add` and `sysctls`: https://docs.docker.com/reference/compose-file/services/
- Compose networking and internal networks: https://docs.docker.com/compose/how-tos/networking/
- Compose network IPAM/internal docs: https://docs.docker.com/reference/compose-file/networks/

Relevant constraints:

- Docker recommends `--cap-add=NET_ADMIN` for modifying network interfaces instead of using broad `--privileged`.
- Compose supports `cap_add` and namespaced `sysctls`; Docker rejects sysctls that would modify the host.
- Compose service names are stable DNS names inside the project network even when container IPs change.
- `internal: true` creates a network without external connectivity, which fits the private backend side.

## Ubuntu Cloud Images And Cloud-Init

Primary references:

- Ubuntu cloud images: https://cloud-images.ubuntu.com/
- Noble current image directory: https://cloud-images.ubuntu.com/noble/current/
- Ubuntu public images libvirt guide: https://documentation.ubuntu.com/public-images/public-images-how-to/launch-with-libvirt/
- cloud-init NoCloud datasource: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
- Ubuntu cloud-init overview: https://ubuntu.com/server/docs/explanation/intro-to/cloud-init/

Relevant constraints:

- Ubuntu cloud images are official preinstalled server images for clouds and local virtualization.
- Ubuntu documents launching QCOW images with libvirt and `virt-install --import`.
- NoCloud accepts `user-data`, `meta-data`, `vendor-data`, and `network-config`.
- A local ISO9660 or vfat seed filesystem must be labelled `CIDATA`.
- `meta-data` needs an `instance-id`; `network-config` can use cloud-init network config v2.

## KVM/libvirt

Primary references:

- libvirt network XML: https://libvirt.org/formatnetwork.html
- Ubuntu libvirt QCOW launch guide: https://documentation.ubuntu.com/public-images/public-images-how-to/launch-with-libvirt/

Relevant constraints:

- `<forward mode='nat'/>` connects a libvirt virtual network outward through host NAT.
- Omitting `<forward>` creates an isolated virtual network where guests can talk to each other and the host bridge, but not the physical LAN.
- Libvirt-managed networks create Linux bridges and can be defined, started, and autostarted with `virsh`.
- Ubuntu's guide uses `virt-install --import`, `--disk`, `--network`, and cloud-init user data for cloud images.

## VMware Fusion/Workstation

Primary references:

- Broadcom VMware Fusion networking types: https://knowledge.broadcom.com/external/article/303393/understanding-networking-types-in-vmware.html
- VMware Fusion Pro 13 manual: https://techdocs2-prod.adobecqms.net/content/dam/broadcom/techdocs/us/en/pdf/vmware/desktop-hypervisors/fusion/vmware-fusion-pro-13.pdf
- QEMU `qemu-img` utility: https://www.qemu.org/docs/master/tools/qemu-img.html

Relevant constraints:

- Fusion networking names: bridged is `vmnet0`, host-only is `vmnet1`, and NAT is `vmnet8`.
- NAT gives the guest outbound connectivity through the Mac and generally cannot be contacted directly by systems other than the Mac unless the VM initiates the connection.
- `vmrun -T fusion start <vmx> nogui` is the documented command-line power path for Fusion.
- `vmrun` and newer `vmcli` can operate on `.vmx` paths.
- `qemu-img convert` supports VMDK output; QEMU positions VMDK primarily as an interchange format.

## ESXi / vCenter

Primary references:

- govmomi/govc: https://github.com/vmware/govmomi
- govc usage reference: https://raw.githubusercontent.com/vmware/govmomi/main/govc/USAGE.md
- cloud-init VMware datasource: https://docs.cloud-init.io/en/latest/reference/datasources/vmware.html
- QEMU `qemu-img` utility: https://www.qemu.org/docs/master/tools/qemu-img.html

Relevant constraints:

- `govc import.vmdk` requires local VMDK files in `streamOptimized` format.
- `govc` accepts standard environment variables for URL, credentials, TLS behavior, datacenter, datastore, host, resource pool, and inventory folder placement.
- `govc vm.create` supports existing datastore disks, ISO attachment, EFI firmware, guest OS IDs, vmxnet3 adapters, and static NIC MAC addresses.
- `govc vm.network.add` supports adding the router private NIC after VM creation.
- `govc vm.ip -a -v4 -n <mac>` filters IP discovery to the router public NIC and depends on VMware Tools reporting guest networking.
- NoCloud seed ISOs avoid relying on vSphere guest customization or VMware guestinfo transport during first boot.
