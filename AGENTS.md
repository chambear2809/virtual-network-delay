# Agent Notes

This repository is a local virtualization skill. Prefer Docker for quick validation unless the user explicitly asks for KVM or VMware.

Do not run KVM or VMware deploys without making the target provider explicit in the command. Use `--dry-run` first when changing those scripts because they create VMs, networks, disks, and seed ISOs.

The intended data path is always client -> router -> private backend. Do not validate delay against a direct backend URL.
