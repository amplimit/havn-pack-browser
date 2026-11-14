# Havn Pack Browser

Browser-automation capability pack for [havn](https://github.com/amplimit/havn) agents — adds the
ability to drive Chromium against SPAs, logged-in pages, and any JS-rendered
content that `web_fetch` can't see.

This is a **pack**, not a feature: havn ships zero skills (spec §1.5 / §11),
and capabilities like browser automation that don't fit havn's
infrastructure-only mandate live in their own repos. Install with two
commands; uninstall by deleting one directory.

## What this is, what it isn't

- ✅ A **bundled skill** (`SKILL.md`) that teaches an agent's LLM how to drive
  Microsoft's [`@playwright/cli`](https://github.com/microsoft/playwright-cli)
  via the `shell` tool the agent already has.
- ✅ A **setup script** that installs Chromium + Node + `playwright-cli` into
  `/opt/havn/` once on the host. All agents on the host share that one
  install — no per-agent download, no 150 MB-per-agent disk waste.
- ❌ **Not** a havn-core change. Nothing in `crates/` of the main repo is
  patched. Browser-aware policy flags / Landlock browser profile / cgroup
  bumps are deferred until a concrete user asks for the easy-button
  experience (see "Future" below).

## Why playwright-cli, not Playwright MCP / computer-use

| Path                            | Token cost (30-step flow) | Loop quality     | Setup |
|---------------------------------|--------------------------:|------------------|-------|
| **playwright-cli (this pack)**  |          ~25 K            | DOM-aware, fast  | one script |
| Playwright MCP                  |          ~115 K           | DOM-aware, slow  | MCP server lifecycle |
| computer-use (screenshot/click) |          5–10× MCP        | Visual, fragile  | needs Xvfb + display server |

DOM-text understanding is well ahead of screenshot understanding in 2026
models, and CLI invocations cost ~4× fewer tokens than MCP wraps. Microsoft
themselves recommend the CLI path in the playwright-cli README.

## Prereqs

- Linux host (Debian/Ubuntu tested; setup.sh has notes for adapting other distros).
- A havn agent whose policy allows `can_use_shell: true` (default).
- ≥ 1 GB free disk for the Chromium download.

## Install

### 1. Run the host installer

```bash
git clone https://github.com/amplimit/havn-pack-browser /tmp/havn-pack-browser
cd /tmp/havn-pack-browser
sudo ./setup.sh                    # installs to /opt/havn/, idempotent
```

### 2. Wire the install into havn config

`setup.sh` only places binaries on the host. To make Chromium actually
work *inside* an agent's namespace you need to declare three things in
your havn gateway config (`~/.config/havn/config.toml` for single-user
installs; `/etc/havn/config.toml` for multi-user). havn provides each
of these as a generic primitive — the gateway never knows it's the
browser pack that needs them.

Append this block to your config and restart the gateway:

```toml
# Make the Chromium / Node / playwright-cli install visible to agents.
# Mirror-bound at the same absolute path on the host and inside the
# agent namespace.
[[extra_mounts]]
path = "/opt/havn/chromium"
mode = "ro"

[[extra_mounts]]
path = "/opt/havn/node"
mode = "ro"

[[extra_mounts]]
path = "/opt/havn/playwright-cli"
mode = "ro"

# Chromium uses POSIX shared memory for renderer-process IPC. The
# default agent namespace has no /dev/shm, and Chromium crashes on
# any non-trivial page without it. 1 GiB matches what havn spec §16
# documents for browser workloads.
[[tmpfs_mounts]]
path = "/dev/shm"
size_mb = 1024

# Chromium's user-namespace sandbox needs `pivot_root` and
# `userfaultfd`, both of which are in havn's default seccomp blocklist,
# and, from havn 0.1.7, `user_namespaces`, which lets agents create user
# namespaces at all. Without them Chromium cannot start its sandbox, and
# running it with --no-sandbox would void havn's per-agent isolation
# guarantee. havn refuses to relax other names from the blocklist
# (mount, ptrace, bpf, etc.), so this list is bounded.
[seccomp]
allow_extra = ["pivot_root", "userfaultfd", "user_namespaces"]
```

On havn 0.1.6 and earlier leave out `user_namespaces`: those versions do
not know the name, and an agent whose list has a name its runtime does not
know gets the full blocklist, so the browser would not start.

Optionally override the agent DNS servers — defaults to public
resolvers; override for internal DNS / Pi-hole / DoH:

```toml
[network]
agent_dns = ["9.9.9.9", "149.112.112.112"]   # Quad9, for example
# agent_pool_cidr = "10.42.0.0/16"           # only override on CIDR conflicts (VPN / Docker / k8s)
```

Then **enable outbound network on the role(s) that should run the
browser**, and raise the per-agent memory ceiling. The browser pack
needs egress to actually reach the internet — havn defaults to no
outbound (spec §6.3 / §1.5 security narrative). Chromium with one tab
sits at ~250 MiB idle and 700–900 MiB on a JS-heavy SPA.

```bash
# Required: open the netns. Without this the agent has only `lo` DOWN
# and Chromium gets `ERR_INTERNET_DISCONNECTED` on every navigate.
havn role set-policy <role-name> network_policy.egress_allowed true

# Required: 1024 minimum; 1536–2048 is comfortable. Below ~1024 will
# OOM-kill the agent on the first big page load.
havn role set-policy <role-name> resource_limits.memory_mb 1536
```

### 3. Drop the skill into agents that should use the browser

```bash
# replace <agent-id> with the UUID of the agent you want to enable browser for
mkdir -p /var/lib/havn/agents/<agent-id>/workspace/skills/browser
cp SKILL.md /var/lib/havn/agents/<agent-id>/workspace/skills/browser/SKILL.md
```

Restart the agent so the runtime indexes the new skill:

```bash
havn agent stop <agent-id> && havn agent start <agent-id>
```

The agent's LLM will now see the `browser` skill in its retrieval set
and pull it into context whenever a user asks for something that needs
a real browser.

### 4. Verify the kernel actually allows nested user namespaces

Chromium's sandbox does `unshare(CLONE_NEWUSER)` from inside the agent's
own user namespace. Some hardened kernel configs reject nesting; if
yours does, the seccomp / tmpfs config above won't help. havn includes
a precheck that runs at the end of `havn setup` and as part of `havn
doctor`:

```bash
havn setup    # prints the kernel capability report at the end
# or
havn doctor   # alongside the rest of the host checks
```

A green `nested user-namespace clone works` line means you're fine.
A warn line means: either fix the kernel sysctl mentioned in the
remediation, or skip this pack on this host. havn does NOT support
running the browser pack with `--no-sandbox` as a fallback.

## Verify

In a webchat session with the enabled agent:

```
You: 请用浏览器去 https://example.com 把页面标题告诉我
Agent: (uses shell to call playwright-cli, snapshots the page, reads the title)
```

If the agent says it can't use a browser, check:

1. The skill file exists at the right path (`workspace/skills/browser/SKILL.md`).
2. The agent's policy has `can_use_shell: true`.
3. `which playwright-cli` returns `/opt/havn/playwright-cli` from a host shell.

## Uninstall

```bash
sudo rm -rf /opt/havn/chromium /opt/havn/node /opt/havn/playwright-cli
# and remove the SKILL.md from any agent workspaces you copied it into
```

## What lives in this repo

```
SKILL.md            content injected into the agent's system prompt — teaches
                    the LLM when to use browser vs web_fetch + the playwright-
                    cli command surface
setup.sh            host-side installer for Chromium + Node + playwright-cli
README.md           you're reading it
LICENSE             Apache-2.0
```

## How this works under havn

havn-core ships **no** browser-aware code. Three generic primitives
in havn-core are what make this pack work; the gateway / spawner /
runtime apply them mechanically without knowing they're for a browser.

| havn primitive | What this pack uses it for |
|----------------|----------------------------|
| `[[extra_mounts]]` (havn spec §4.1) | Bind-mounts `/opt/havn/{chromium,node,playwright-cli}` into the agent namespace so the LLM's `shell` calls find the binaries. |
| `[[tmpfs_mounts]]` (havn spec §16.2) | Mounts a 1 GiB tmpfs at `/dev/shm` so Chromium's renderer-process IPC works on non-trivial pages. |
| `[seccomp.allow_extra]` (havn spec §16.2) | Relaxes the runtime's syscall blocklist for `pivot_root` + `userfaultfd` — the two syscalls Chromium's user-namespace sandbox needs — and, from havn 0.1.7, `user_namespaces`, which lets the agent create the user namespace itself. havn restricts the operator's relaxation menu to a curated list (`OPERATOR_RELAXABLE_SYSCALLS` in `havn-runtime/src/seccomp.rs`); even a hostile pack documentation cannot get an operator to relax `mount` / `ptrace` / `bpf`. |

There is no `can_run_browser` policy bit. There is no per-pack code in
havn-core. Add a different pack later — same mechanism, no havn change.

## Security notes

`playwright-cli` runs Chromium with its own internal sandbox enabled by
default. The havn agent it's launched from is already inside a namespace +
Landlock + seccomp + cgroup envelope (spec §4.1). The composition is fine for
trusted-tenant workloads (the agent's own user driving their own browser);
it is **not** sufficient for adversarial multi-tenant where you'd want the
operator to additionally enforce per-domain allowlists.

If you're driving login-state pages, treat the cookie jar in the agent's
workspace as sensitive — same hygiene as `~/.netrc`.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
