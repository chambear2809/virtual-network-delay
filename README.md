# Virtual Network Delay

A standalone Codex skill and script set for Ubuntu-based latency labs across Docker, KVM/libvirt, local VMware Fusion/Workstation, and ESXi/vCenter.

The lab shape is the same on every provider:

- Router node with HAProxy and `tc netem`
- Private backend HTTP target
- Delay, jitter, and packet loss controls on the router
- Validation that compares baseline and delayed probe medians
- Provider-specific cleanup

## Quick Start: Docker

```bash
cp example.env .env
bash scripts/check-prerequisites.sh --provider docker
bash scripts/docker-lab.sh deploy
bash scripts/validate-router-delay.sh validate --provider docker --delay-ms 150
```

Or run the guided single command:

```bash
bash scripts/demo-latency.sh --provider docker --delay-ms 150
```

Then control delay directly:

```bash
bash scripts/router-delay.sh status --provider docker
bash scripts/router-delay.sh enable --provider docker --delay-ms 150 --jitter-ms 20
bash scripts/router-delay.sh disable --provider docker
```

The default Docker URL is `http://127.0.0.1:8080/`.

Deploy and status commands print `router_url`, plus copy-ready status, enable, disable, and validation commands. If you use `--lab-name`, those next commands include it.

Validation leaves the requested delay enabled so you can immediately inspect the delayed path. Add `--restore-delay` to disable delay after validation:

```bash
bash scripts/validate-router-delay.sh validate --provider docker --delay-ms 150 --restore-delay
```

## KVM

```bash
bash scripts/check-prerequisites.sh --provider kvm
bash scripts/kvm-lab.sh deploy --dry-run
bash scripts/kvm-lab.sh deploy
bash scripts/validate-router-delay.sh validate --provider kvm --delay-ms 150
```

KVM creates two libvirt networks: a NAT public network and an isolated private network. The router has one NIC on each. The backend only has the private NIC.

## VMware Fusion/Workstation

```bash
bash scripts/check-prerequisites.sh --provider vmware
bash scripts/vmware-lab.sh deploy --dry-run
bash scripts/vmware-lab.sh deploy
bash scripts/validate-router-delay.sh validate --provider vmware --delay-ms 150
```

VMware uses vmnet8/NAT for the router public side and vmnet1/host-only for private router-backend traffic. `vmrun getGuestIPAddress` is used after `open-vm-tools` comes up.

## ESXi / vCenter

ESXi uses `govc` and standard govc environment variables for auth and placement:

```bash
export GOVC_URL='https://esxi-or-vcenter/sdk'
export GOVC_USERNAME='...'
export GOVC_PASSWORD='...'
export GOVC_INSECURE=1
export GOVC_DATASTORE='datastore1'
export ESXI_PUBLIC_NETWORK='VM Network'
export ESXI_PRIVATE_NETWORK='vnd-private'

bash scripts/check-prerequisites.sh --provider esxi
bash scripts/esxi-lab.sh deploy --dry-run
bash scripts/esxi-lab.sh deploy
bash scripts/validate-router-delay.sh validate --provider esxi --delay-ms 150
```

Default ESXi networking reuses existing port groups. To create lab-scoped standard vSwitches and port groups, set `ESXI_NETWORK_MODE=create` or pass `--create-networks`, plus `ESXI_PUBLIC_VSWITCH` and `ESXI_PRIVATE_VSWITCH`. Keep credentials out of committed `.env` files.

## Cleanup

```bash
bash scripts/destroy-virtual-network-delay.sh --provider docker --yes
bash scripts/destroy-virtual-network-delay.sh --provider kvm --yes
bash scripts/destroy-virtual-network-delay.sh --provider vmware --yes
bash scripts/destroy-virtual-network-delay.sh --provider esxi --yes
```

Generated files live under `.generated/`.

## Custom Lab Names

Use `--lab-name <name>` on deploy, status, delay, validation, and destroy commands when running multiple labs:

```bash
bash scripts/docker-lab.sh deploy --lab-name demo-a --public-port 18080
bash scripts/router-delay.sh enable --provider docker --lab-name demo-a --delay-ms 150
bash scripts/destroy-virtual-network-delay.sh --provider docker --lab-name demo-a --yes
```
