# Platform Contract

## Topology

Short form: client -> router -> private backend.

Every provider must preserve this path:

1. A client connects to the router public listener.
2. HAProxy on the router forwards to one selected backend.
3. The backend is private to the lab network.
4. `tc netem` is applied on the router interface that carries responses toward the client.
5. Validation probes the router URL, never the direct backend URL.

## Provider Shapes

Docker:

- Router container joins `public` and `private` bridge networks.
- Backend container joins only `private`.
- Router has `NET_ADMIN` and namespaced `net.ipv4.ip_forward=1`.
- Host access is through a published router port, default `127.0.0.1:8080`.

KVM/libvirt:

- Router VM has one NIC on a dedicated NAT public libvirt network and one NIC on a dedicated isolated private network.
- Backend VM has one NIC on the isolated private network.
- Ubuntu cloud images are configured through NoCloud `user-data`, `meta-data`, and `network-config`.
- Static MAC matches are used so cloud-init can set stable interface names.

VMware:

- Router VM has a NAT public NIC and a host-only private NIC.
- Backend VM has only the host-only private NIC.
- Ubuntu cloud images are converted to VMDK and configured with NoCloud seed ISOs.
- `open-vm-tools` is installed so `vmrun getGuestIPAddress` can discover the router public address.

## State Contract

Provider scripts write `.generated/<provider>/<lab>.env`. Operational scripts rely on these fields when present:

- `LAB_NAME`
- `PROVIDER`
- `ROUTER_HOST`
- `ROUTER_PUBLIC_URL`
- `ROUTER_SSH_USER`
- `SSH_PRIVATE_KEY_FILE`
- `BACKEND_HOST`
- `BACKEND_PORT`
- `PUBLIC_PORT`
- Docker-specific: `DOCKER_COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`
- VMware-specific: `VMWARE_ROUTER_VMX`, `VMWARE_BACKEND_VMX`, `VMWARE_VMRUN_TYPE`

## HAProxy Contract

`backend-wire.sh apply` replaces the active HAProxy config with one frontend/backend pair. This keeps the lab intentionally single-symptom. Add multi-backend support only if the validation contract is updated to make the probed route explicit.

Supported protocol modes:

- `http`: HAProxy HTTP mode.
- `https`, `rtsp`, `tcp`: HAProxy TCP passthrough mode.

## Delay Contract

Delay controls use:

- Enable: `tc qdisc replace dev "$iface" root netem delay ...`
- Disable: `tc qdisc del dev "$iface" root`
- Status: `tc qdisc show dev "$iface"`

The default interface expression is `ip route show default | awk '{print $5; exit}'`. This should remain the default because provider NIC names differ (`eth0`, `ens*`, `public0`, VMware predictable names, Docker veth names).

## Known Limits

- This is a lab, not a production router.
- Docker delay reflects container and Docker Desktop networking behavior; on macOS/Windows Docker Desktop adds a VM layer.
- KVM default CIDRs are dedicated /24s and may need overriding if they collide with local routes.
- VMware vmnet1/vmnet8 subnets are host-managed. The private side uses static addressing on the host-only L2 and does not require the host vmnet1 address to be in the same subnet.
- `tc netem` delay is egress-oriented. For strict receiver-ingress TCP experiments, place delay at the receiver ingress path or use IFB/mirred; this skill intentionally keeps a simpler router-egress symptom path.
