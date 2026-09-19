# Cadence — FAQ

Answers to the questions that come up most often. If something here is out of date, that's a bug — open an issue.

---

## What problem does Cadence solve?

Running several coding agents in parallel without their contexts bleeding into each other.

Each project gets its own lightweight VM: its own filesystem, its own git identity, its own agent config, its own network name. The agent in one VM cannot see or touch another project. Nothing is shared by accident, because nothing is shared at all.

Four things it removes:

- **Context isolation** — separate VM per project, no shared state
- **Reproducible environments** — a golden image plus an inventory file, not hand-tuned machines
- **Parallel work** — agents run in background tmux sessions, several projects at once
- **Manual resource management** — dev servers start on demand and stop themselves when idle

---

## What do I need to run it?

- Windows host with VMware Workstation
- **PowerShell 7.** Not Windows PowerShell 5.1 — the orchestrator scripts won't run on it
- 16 GB RAM (that's the configuration it was built and tested on)
- Ubuntu Server guests, no desktop environment
- Claude Code installed on the host and in the guests

Everything on the host runs in a terminal. No IDE is required on the host and none is installed in the guests.

---

## How many VMs can I actually run?

On 16 GB: up to 8 powered on, of which **no more than two running dev servers at the same time**.

Those are different numbers. An idle VM whose agent is waiting for work costs roughly 600–800 MB of host RAM. A VM with a dev server under active testing costs 1.3–1.8 GB, and the browser profile you test it with costs another 800–1500 MB on the host.

`memsize` is 3072 per machine and never changed at runtime. Budget is enforced by measuring actual free host RAM, not by adding up allocations.

One caveat worth knowing before you tune anything: leave VMware's memory ballooning **off** for these VMs (`sched.mem.maxmemctl = "0"` in the `.vmx`). With it on, the hypervisor reclaims memory from a perfectly healthy guest and the guest locks up — no OOM, no message, just a frozen VM. Details in `docs/OPERATIONS.md` §7.

---

## Does it have to be VMware?

Right now, yes. The control plane is built directly on `vmrun` — `start nogui`, `getGuestIPAddress -wait`, `revertToSnapshot`. There is no hypervisor abstraction layer yet.

Porting to Hyper-V, Proxmox or libvirt is a real piece of work, not a documentation task. It's one of the two places where help is most useful. See *What needs work*.

---

## Why no GUI in the guests? Where do I edit code?

Because a graphical stack plus an Electron editor costs 2.5–3 GB per VM, and that ends the whole idea at two machines. Memory is the budget, and the budget is the product.

No GUI does not mean no tools. Everything a Linux console offers is available over SSH, and a new terminal tab is a new working session on the guest — instantly, at no memory cost. `mc` ships in the golden image for file management. If you want a code editor in the VM, install Vim or Neovim.

The rule is simple: if it runs in a terminal session, it belongs in the guest. If it needs a graphical stack or a language server of its own, it doesn't. Most of the editing is done by the agent anyway — you're reviewing and steering more often than typing.

---

## How do agents authenticate?

Manually, once per machine, by the operator. There is no browser inside the VM and there isn't meant to be — the browser lives on the host.

When the orchestrator clones and provisions a machine, it drops a browser shortcut into the root of that project's local repository on the host. The profile and the project live in the same folder, so there's never a question of which profile belongs to what — you open the project directory and the right browser is sitting there. The flow is then:

1. A panel on the VM prints an authentication URL on first run.
2. You launch the browser from the project folder on the host and paste the URL in.
3. You authenticate there and copy the resulting code back into the panel.

`gh auth login` works the same way through device flow. One project means one profile, used for both the host-side work and the VM's logins, so the accounts used for one machine never leak into another — the isolation that holds for the VMs holds for the logins too.

Cadence does not store credentials and does not automate this step. That's fine for a handful of machines and wrong for a fleet on a server — see *What needs work*.

---

## How do I actually drive this?

You talk to the orchestrator. It's a Claude Code session on the host, started in the Cadence directory from PowerShell 7 — either a standalone `pwsh` window or a Windows Terminal tab, whichever you prefer. It's the first thing you open.

`status` is the entry point: it lists every VM on the host — running and cold — with their paths, addresses, and how to attach to the panels on each. From there you ask for what you want in plain language. Cloning a machine, bringing one up, attaching to an agent — all of it goes through the orchestrator rather than through `vmrun` by hand.

That's the point of the inventory being the single source of truth: the orchestrator reads it, so you never look up which VM holds which project or what address it ended up on.

---

## How do I see a dev server running inside a VM?

Ask the orchestrator to bring the project up, then open `http://dev-01.test:3000` in a browser on the host.

No port forwarding is involved: in the NAT segment the host reaches guests directly by their static IPs, and the orchestrator writes those names into the hosts file. The name is stable — it doesn't change when the machine is recreated.

Two things that trip everyone up:

- **Your dev server must listen on `0.0.0.0`.** Vite, Next, Django and most others bind to `127.0.0.1` by default, which is unreachable from outside the VM. This is the single most common "it doesn't work".
- **Hot reload needs the right host.** If the bundler hands the browser a `localhost` WebSocket URL, the page loads but stops updating. Set the public host explicitly in the bundler config.

---

## Why does the dev server shut itself down?

Because nobody was using it.

A dev server runs under a lease. Two things can hold that lease: an open browser tab (detected as established TCP connections on the port — the hot reload WebSocket lives exactly as long as the tab does) and an explicit hold taken by an agent before a test run. When neither holds it for longer than the grace period, a watchdog inside the guest stops the server and frees the memory.

There is no negotiation with the agent about this. An agent is a language session — it may be mid-task, slow to answer, or ambiguous. Instead, whoever needs the server declares it in advance and machine-readably. No lease, no server.

If an agent needs the server, it takes a hold with a TTL and renews it. A crashed agent can't hold memory hostage forever.

---

## Can the VMs talk to each other?

Yes — they're in the same NAT segment and reach each other by name. The orchestrator writes the same hosts block into every guest, not just the host machine.

Inter-guest SSH uses per-machine keys, laid out only along the pairs declared in the inventory. There's no "one key everywhere", and no shared network folder between guests — a mounted share creates state that lives outside the inventory and breaks silently.

---

## Why VMs? Why not Docker, devcontainers or WSL?

The honest answer first: because of the machine I had. A Windows host on a laptop with 16 GB, where getting Docker Desktop working would have meant sorting out WSL2 — which in my case pointed at reinstalling Windows. On a Linux host I might well have reached for containers instead.

There's also a plain preference at work. I've been automating VMware since version 5 on Windows ME, and that has never stopped being enjoyable. `vmrun` does what you tell it and gets out of the way.

The engineering argument is real too, and it's the one that would keep me here even on Linux: a VM is a harder boundary than a container. Separate kernel, separate network stack, separate filesystem, snapshot and rollback of the whole machine in one command. When the entire point is that one agent cannot reach another project, that boundary *is* the product.

None of which means containers are wrong. They're lighter, and for some workloads they'd be the better answer. Nobody has built that variant. If you want to, the inventory-and-profiles design should carry over unchanged — it's the layer below it that would need replacing.

---

## Why is it Claude everywhere? Can I use another model?

Because I have a Claude subscription and built this for myself. Treat Claude as the preinstalled package in an MVP, not as an architectural commitment.

Nothing in the design depends on which model sits in the panel. The VM boundary, the inventory, the profiles, the lease protocol — none of it knows or cares what the agent is. What is Claude-specific is the plumbing: install steps, the config directory variable, the authentication flow.

**If you run something else today**, you can adapt the agent configs and rebuild the golden image around your own CLI agent. Everything above that layer keeps working.

**What doesn't exist yet**: a model-agnostic agent layer — picking Gemini, ChatGPT or another CLI agent from a list and having the config generated for you. There's no spec for it yet, let alone an implementation. It's on the roadmap and it's a good place to contribute, especially if you already run one of those day to day.

---

## How do I show an agent a screenshot?

Drop it onto that project's drive on the host.

The orchestrator mounts each active machine's working directory as a drive letter, labelled with the project name — `X:` is one project, `Y:` the next. Drag a file from `Downloads` into `X:\screenshots` and it travels over SSH onto the guest's disk. From the agent's side it's just a local file: `@screenshots/bug.png`.

Why not paste it? Claude Code does accept images by drag-and-drop, by clipboard paste (`Ctrl+V`, or `Alt+V` on Windows and WSL), and by file path. But the first two happen where the CLI process is running — inside the VM. A headless guest has no clipboard, and a screenshot sitting on the Windows host doesn't exist as far as the guest is concerned. The path is the route that works.

A few things worth knowing:

- The `screenshots/` directory is git-ignored on purpose. It's scratch space for context, not source.
- Drives are mounted only for running machines. A drive pointing at a powered-off VM will hang Explorer, which is why mounting is tied to activating a project rather than done once at boot.
- Without the mount, `scp` from PowerShell does exactly the same thing.

### The whole path, concretely

One-time on the host: install [WinFsp](https://github.com/winfsp/winfsp/releases), then
[SSHFS-Win](https://github.com/winfsp/sshfs-win/releases). Both are installers with a UAC prompt, so
a human runs them. Note they land in *different* places — WinFsp is a 32-bit installer and goes to
`Program Files (x86)`, SSHFS-Win to `Program Files`. Until both are there, `vmfleet.ps1 mount` tells
you exactly what is missing and everything else keeps working.

Then, per project:

```powershell
.\vmfleet.ps1 up -Only my-project-vm      # a drive is only mounted for a running machine
.\vmfleet.ps1 mount my-project-vm         # X: appears, labelled with the project name
.\vmfleet.ps1 mounts                      # letter, project, machine, path, state
```

`.\vmfleet.ps1 status` prints the same thing in its tables: a **Диск** column showing each machine's
letter and whether it is mounted, and a **Файлы** column with the ready command — either
`перетащить в X:\screenshots -> агенту: @screenshots/имя.png` when it is mounted, or the `mount`
command when it is not. Nothing to memorize: copy from the table.

**On the host:** drag the file into `X:\screenshots` (Explorer, an ordinary drive). That is a write
over SSH straight onto the guest's disk — no copy stays on the host.

**In the agent's pane:** refer to it by a path relative to the project root —
`@screenshots/bug.png`. The agent's working directory is the project root, which is exactly what the
drive is mounted to, so the relative path lines up. Saying "look at the screenshot" without a name
works too: the block that `mount` writes into the project's `CLAUDE.md` tells the agent to check the
directory for the newest file and confirm which one you meant.

**In git:** nothing appears. `mount` adds the ignore rule where it belongs — `.gitignore` for your
own repository, `.git/info/exclude` for one you don't own (the `github.own_repo` field in the
inventory decides, the orchestrator doesn't guess).

`activate` and `deactivate` mount and unmount for you; `down` unmounts before powering the machine
off, because a drive pointing at a dead VM hangs Explorer. Details: `docs/OPERATIONS.md` §5a,
reasoning in `docs/decisions/mounts.md`.

---

## Is there voice input?

In the CLI, yes — `/voice` turns on push-to-talk dictation, and your speech is transcribed straight into the prompt so you can mix talking and typing in one message. Audio is streamed to Anthropic for transcription rather than processed locally, it requires a Claude.ai account, and it doesn't consume tokens or count against your usage limits. Dictation defaults to English; change it with `/config`.

For Cadence specifically: the microphone is on the host and the agent panels run on the guests, and audio doesn't travel over SSH. So expect dictation to work in the orchestrator session on the host and not in the panels. If you want voice everywhere, a system-wide dictation tool on Windows types into whatever terminal window is focused.

---

## Do I need a paid Claude plan?

You need a working Claude Code installation, authenticated however you normally authenticate it. Cadence doesn't change or manage that — it only keeps each machine's config directory separate.

---

## What needs work

In rough order of how much it would unlock:

1. **Hypervisor abstraction** — replacing direct `vmrun` calls with a driver layer so Hyper-V, Proxmox and libvirt become possible
2. **Non-interactive authentication** — the manual login step is what blocks deployment on a server
3. **Model-agnostic agent layer** — choosing which CLI agent runs in a panel, with the config generated rather than hand-edited; no spec written yet
4. **Name resolution at scale** — the hosts file and drive letters don't survive past a couple of dozen machines; this wants a local DNS resolver and a proxy
5. **Load testing** — everything above is theory until someone runs twenty cells at once

Issues and pull requests are welcome on all five.

---

## Something broke during installation

Please open an issue with: host OS and VMware version, guest Ubuntu version, the command you ran, and what it printed.

Installation bugs get fixed the day they're reported. The project has been installed a small number of times by one person, which means a good share of the remaining bugs are still waiting for someone whose setup differs from the author's. Yours probably does.

---

## Known sharp edges

| Symptom | Cause |
|---|---|
| Dev server unreachable from host | Server bound to `127.0.0.1` instead of `0.0.0.0` |
| Page loads but never hot-reloads | Bundler advertising a `localhost` WebSocket |
| Names resolve slowly or not at all | Using a `.local` suffix — it belongs to mDNS; use `.test` |
| Hosts file changes silently ignored | Not running as administrator |
| Two VMs fighting over an address | Clone identity not reset: same machine-id, same DHCP client id |
| A `vmrun` command "succeeded" but nothing happened | `vmrun` can exit 0 on a failed operation — verify state, not exit codes |
| VM shows as running, Tools alive, but answers neither SSH nor ping | The hypervisor is taking memory back from a live guest: `vmballoon_work` floods the kernel while the guest's journal shows no OOM at all. Disable ballooning in the `.vmx` (`sched.mem.maxmemctl = "0"`, `MemTrimRate = "0"`, `sched.mem.pin = "TRUE"`); adding RAM does not fix it. `docs/OPERATIONS.md` §7 |
| An agent reports "sudo needs a password" and stops | It tested `sudo -n true`. Only specific commands are passwordless — `true` isn't one. Check with `sudo -n -l`; `docs/OPERATIONS.md` §0 |

---

## Fixes you may be missing if you cloned early

The repository went public on 2026-09-13. Everything below was found on real machines and fixed in
`main` the same day — but a clone taken before the fix still carries the bug. A `git pull` gets all
of them; the detail is here in case you would rather patch in place, or you hit the symptom and want
to know what it was.

**`ssh <machine>` fails with "Host key verification failed"** — fixed 2026-09-14 (`3deb7fa`). The
orchestrator's own SSH calls already used `StrictHostKeyChecking=accept-new`, but the `~/.ssh/config`
block generated for *you* never carried that setting. So a plain `ssh <alias>` broke every time an
address got reused (a re-clone, or DHCP handing the same IP to a different machine), while the
orchestrator itself kept working and showed no problem. **Fix:** pull, then re-run
`.\vmfleet.ps1 ssh-config`; or add `StrictHostKeyChecking accept-new` to that host's block by hand.

**`health` reports `claude: НЕТ` on a machine where the agent runs fine** — fixed 2026-09-14
(`043f581`). The check ran a bare `claude --version` over a non-interactive SSH session, where the
npm global bin directory is not on `PATH` — the same class of bug already fixed once in
`start-agents.sh`. A false negative, not a broken machine. **Fix:** pull. To confirm by hand:
`ssh <id> "~/.npm-global/bin/claude --version"`.

**`netplan apply` on a fresh clone: "Cannot find unique matching interface for ens33"** — documented
2026-09-14 (`043f581`, `docs/GOLDEN_IMAGE.md` §8). The Ubuntu installer leaves
`/etc/netplan/00-installer-config.yaml` behind with `match: macaddress:` pinned to the MAC it saw at
install time. Every clone gets a fresh MAC, so that file matches nothing and fights the static-IP
config the orchestrator writes. **Fix — once, on the golden image, not per clone:**

```bash
sudo mv /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.disabled
```

**The guest freezes solid after an hour or two, and adding RAM doesn't help** — fixed 2026-09-19.
The hypervisor reclaims memory from a perfectly healthy guest: the guest's journal shows zero OOM
records while `vmballoon_work` floods the kernel. Three lock-ups before it was pinned down, one of
them after the memory had already been raised. **Fix:** in the `.vmx` of the image (clones inherit)
and of any existing machine — `sched.mem.maxmemctl = "0"`, `MemTrimRate = "0"`,
`sched.mem.pin = "TRUE"`; apply with the VM powered off. Verify with `lsmod | grep balloon` — the
module loads, its use count stays `0`. The profile's baseline memory also moved to 3072.

**Background jobs disabled on the image** — 2026-09-19. `apt-daily`, `apt-daily-upgrade`,
`unattended-upgrades`, `fwupd-refresh`, `motd-news`. Note the timers alone are not enough:
`unattended-upgrades` schedules itself and survived for 50 minutes after its timers were switched
off.

**A deployment checklist now ships with the repo** — 2026-09-19, `docs/NEW_MACHINE_CHECKLIST.md`.
It existed privately from the start and simply wasn't published; every line in it is there because
it was once skipped. It also settles the question that costs the most time per machine — which
steps genuinely need a human and which only look like they do.

**The license files were renamed** — 2026-09-15. `LICENSE.html` became `SESL-CERTIFICATE.html` (plus
a rendered `.pdf`), and a plain-text `LICENSE` was added: GitHub treats every root file starting with
`LICENSE` as its own license tab, and was rendering raw HTML source as the license text. Only matters
if you linked to the old path.

---

## Gotchas that are not bugs, but cost real hours

| Symptom | What is actually going on |
|---|---|
| `Supply values for the following parameters: Command:` | `vmfleet.ps1` is a one-shot command, not a service — it wants a subcommand (`status`, `up`, …). See [`HOW_TO_RUN.md`](HOW_TO_RUN.md) |
| "powershell-yaml is not installed" — but you just installed it | PowerShell modules install **per Windows user**. If a second account opens the terminal (an OEM account, a fast-user-switched session), the module simply isn't there. Check `whoami`; install with `-Scope AllUsers` |
| Output full of `?????` instead of text, or raw ANSI escape codes | Windows PowerShell 5.1 — run `pwsh` (7) instead; see `docs/decisions/orchestrator.md` |
| `clone -Repo https://github.com/...` fails with "could not read Username" | A deploy key only configures SSH. Pass the SSH form: `git@github.com:owner/repo.git` |
| The agent can pull but never push | The deploy key was created read-only. Create it with write access from the start |
| A second repository on the same machine gets 403 on every git call | Credentials are per-repository: the machine-wide `gh` login has no access to it. Give that repo its own deploy key, or a repo-local credential helper reading a token from the project's own `.env` |
