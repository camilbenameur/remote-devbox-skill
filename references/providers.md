# Choosing a server

Prices and stock change often: always check the provider's page before recommending a plan, and
quote the price with taxes and the commitment period.

## What to look for

| Need | Minimum | Comfortable |
|---|---|---|
| RAM | 8 GB: one or two sessions and Chrome | 16 to 24 GB: several sessions, Chrome tabs, test suites |
| CPU | 2 vCPU | 4 to 8 vCPU |
| Disk | 80 GB | 200 GB or more (projects, worktrees, caches) |
| OS | Ubuntu 24.04 LTS | |
| Architecture | x86_64 | x86_64 (arm64: no Google Chrome, Playwright's Chromium is used instead, not tested end to end) |
| Rescue | a web console (VNC/KVM) from the provider | |
| Location | close to the user, for a snappy interface | |

A Claude Code session with a few MCP servers uses about 300 to 600 MB; Chrome with a few tabs 1 to
2 GB; test runs and language servers the rest. Prefer more RAM over more CPU.

## Options seen in November 2026

| Provider | Plan seen | Notes |
|---|---|---|
| Contabo | Cloud VPS with 8 vCPU / 24 GB / 200+ GB, about 15 to 20 EUR a month, monthly | Used for the reference setup. Large RAM for the price; slower disks and support; the kernel has no zram module (the script skips it). Initial user `root`. |
| Hetzner | Shared vCPU cloud servers (x86 or Arm), hourly billing | Fast, simple, good network in Europe and the US. Check the current RAM per price. |
| OVHcloud | VPS range | Was out of stock on the whole range when the reference setup was ordered. Initial user `ubuntu`. |
| Oracle Cloud | Always Free: Ampere A1 Arm, **2 OCPU and 12 GB** in total (1,500 OCPU hours and 9,000 GB hours a month), 200 GB of block storage including boot volumes | Free but: arm64 (see above); "out of capacity" errors are common in popular regions; idle instances may be reclaimed (over 7 days, CPU 95th percentile, network and, for A1, memory all under 20 %), which an upgraded pay-as-you-go account avoids while staying inside the free amounts; a card is required to sign up. The allowance was 4 OCPU / 24 GB before 2026: check Oracle's "Always Free Resources" page. Initial user `ubuntu`. |

Any other KVM provider works if it meets the table above. Avoid OpenVZ/LXC containers: systemd user
services, swap and Tailscale may not work there.

## At order time

- Pick Ubuntu 24.04. If an SSH key field exists, paste the key from `setup-devbox --show-key`.
- Note the public IP, the initial user and the root password (shown or emailed by the provider).
- Upgrading RAM later is usually possible in place; downgrading usually means a new server.
