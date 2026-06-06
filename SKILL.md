---
name: virtual-network-delay
description: Build and operate local Ubuntu-based virtual network-delay labs for Docker, KVM/libvirt, and VMware Fusion/Workstation. Use when Codex needs to create a router-and-backend environment where HAProxy forwards traffic through a controlled path and Linux tc netem injects delay, jitter, or loss for latency demos, protocol testing, validation, or cleanup on local virtualization platforms.
---

# Virtual Network Delay

Use this skill when the user wants a local, reproducible network-delay lab without AWS. The lab always keeps one symptom path: host or client traffic enters a router, HAProxy forwards to a private backend, and `tc netem` is applied on the router interface that carries responses back to the client.

## Workflow

1. Choose the provider.
   - Prefer `docker` for fast local validation and CI-style tests.
   - Use `kvm` on Linux hosts with libvirt and hardware virtualization.
   - Use `vmware` on hosts with VMware Fusion or Workstation and `vmrun`.
   - Default Ubuntu base is `ubuntu:24.04` for Docker and Ubuntu Noble 24.04 cloud images for VM providers. Override with `.env` only when the platform has been checked.

2. Check prerequisites.
   - Entry point: `scripts/check-prerequisites.sh --provider <docker|kvm|vmware|all>`
   - Docker requires Docker Compose and uses `cap_add: NET_ADMIN` so the router can manage `tc`.
   - KVM requires `virsh`, `virt-install`, `qemu-img`, SSH tools, and a NoCloud seed ISO tool.
   - VMware requires `vmrun`, `qemu-img`, SSH tools, and a NoCloud seed ISO tool.

3. Deploy a lab.
   - Docker: `scripts/docker-lab.sh deploy`
   - KVM: `scripts/kvm-lab.sh deploy`
   - VMware: `scripts/vmware-lab.sh deploy`
   - One-command demo: `scripts/demo-latency.sh --provider docker --delay-ms 150`
   - All deploy scripts accept `--dry-run` to render files and show commands without creating VMs or containers.
   - Generated state is written under `.generated/<provider>/<lab>.env`.
   - Deploy and status commands print the router URL and copy-ready next commands.

4. Wire or rewire a backend.
   - Render only: `scripts/backend-wire.sh render --provider <provider> --backend-host <host> --backend-port <port>`
   - Apply: `scripts/backend-wire.sh apply --provider <provider> --backend-host <host> --backend-port <port>`
   - Supported protocols are `http`, `https`, `rtsp`, and generic `tcp`; HTTPS and RTSP use TCP passthrough.

5. Toggle delay.
   - `scripts/router-delay.sh status --provider <provider>`
   - `scripts/router-delay.sh enable --provider <provider> --delay-ms 150 --jitter-ms 20 --loss-pct 1`
   - `scripts/router-delay.sh disable --provider <provider>`
   - By default the router resolves its default-route interface at runtime. Pass `--interface <name>` only when intentionally delaying a non-default path.

6. Validate the effect.
   - `scripts/validate-router-delay.sh validate --provider <provider> --probe-url <url> --delay-ms 150`
   - Prefer validation that disables delay, measures baseline, enables delay, measures again, and compares medians.
   - Docker state provides `ROUTER_PUBLIC_URL=http://127.0.0.1:<port>/` by default.
   - Validation leaves delay enabled for inspection; add `--restore-delay` when the user wants validation to return the lab to baseline.

7. Destroy only when the user asks.
   - `scripts/destroy-virtual-network-delay.sh --provider <provider> --yes`
   - Pass `--lab-name <name>` to deploy, delay, validate, and destroy when multiple labs exist.
   - Provider scripts also support `destroy --yes`.

## Reference

Read `references/platform-contract.md` before changing topology, routing, HAProxy listener behavior, state-file fields, or validation assumptions.

Read `references/research-notes.md` when changing provider-specific implementation details such as NoCloud media, libvirt network XML, Docker capabilities, VMware networking, Ubuntu image selection, or `tc netem` semantics.
