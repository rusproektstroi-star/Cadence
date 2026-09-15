# Cadence

> I designed Cadence for myself — to drive production-grade development on a gaming laptop. The
> architecture isn't locked to this scale: the same fleet of lightweight virtual machines can be
> deployed on an enterprise Windows or Linux server. Doing so requires an abstraction layer above
> the hypervisor instead of direct VMware calls, alongside non-interactive agent authentication.
> Both tasks are clear and open for collaboration.
>
> Cadence resolves four fundamental problems that typically force large organizations to maintain
> platform engineering teams: context isolation, environment reproducibility, workflow parallelism,
> and manual resource management. It tackles them not through workarounds, but via an inventory
> file as the single source of truth, profiles instead of branch bloating, and a lease protocol
> instead of manual approvals. All of this runs on a single 16 GB laptop — hardware never
> originally intended for multi-agent execution.
>
> The boundary the project is crossing right now is the shift from "it works on my machine" to "it
> works for anyone who clones the repository." This line is defined by documentation, not code. The
> repository accepts fixes daily; every bug uncovered during installation is resolved in `main` on
> the very same day.
>
> Please forgive the Russian in the repo. If I can read English — you can learn Russian — I'm
> just way too lazy to change something that works perfectly for me personally. Besides, the AI
> agents that will deploy this beauty on your local machine don't care what language the repo is
> written in anyway.
>
> I think the pure satisfaction I get every time I sit down at my computer to start or continue a
> project completely wipes out any sense of pride in having created it.

**Cadence** is a two-tier golden-image system and orchestrator for a fleet of virtual machines
that host and run AI agents (Claude Code) as full-fledged CLI developers: each project gets its
own VM, spun up in minutes instead of hours of manual setup, with role separation, resource
management, and access control built in.

**What this runs on** (the stack, upfront — not a footnote): host is Windows + VMware Workstation
+ PowerShell 7 (run inside Windows Terminal, not a bare console — see `docs/OPERATIONS.md` §2);
guests are headless Ubuntu Server, no GUI.

## Why this exists

When you need several independent AI agents on separate machines — one VM per project — you
either configure each one by hand (slow, error-prone, nothing gets reused) or you build the
system once and clone it from then on. Cadence is the second path.

One command clones the reference image into a new project machine: strips its MAC/hostname/SSH
keys, assigns a static IP, installs a deploy key for the project's private repository, clones the
code, brings up the agent panes — and the machine is ready to work.

## Architecture — two layers

**1. Golden image** (`cli-golden` in the examples) — a reference VM image (Ubuntu, headless, no
GUI). It carries:
- Node.js + Claude Code, ready to work out of the box;
- a `tmux` session called `agents` with two panes — engineer (`agents.0`, left) and bureau
  (`agents.1`, right); the position is guaranteed by the order the panes are created, not by
  choice;
- role-based canon in each pane's `CLAUDE_CONFIG_DIR` — who's who, what's allowed and what isn't;
- its own set of CLI tools (`devctl`, `devpanel`, `devctl-watchdog`), reachable by bare name from
  any kind of login (symlinked into `/usr/local/bin/`, independent of the shell type);
- a login banner listing what's already installed — nothing to remember between sessions.

**2. Orchestrator** (`vmfleet.ps1`) — a PowerShell script on the host (Windows + VMware
Workstation). Manages the whole fleet: cloning, start/stop, status, snapshots, network addresses,
host↔VM code sync, and scoped access to external resources (see below).

## Key mechanisms

- **[E]/[B] role model** — engineer (code, git, infrastructure) and bureau (specs, strategy,
  doesn't write code and doesn't access the machine directly) — the separation isn't just a
  written rule, it's physical: different panes, different Claude Code config directories.
- **Cross-role routing** — the agent panes can't see each other through Claude Code's built-in
  facilities (they're independent CLI processes in different `CLAUDE_CONFIG_DIR`s, not subagents
  of one session). The exchange runs over `tmux send-keys`/`capture-pane` — a documented,
  live-verified mechanism.
- **Dev-server lifecycle, two independent layers:** `devctl` — automatic (TTL-based leases,
  watchdog stops it on idle, systemd) for a single server per machine; `devpanel` — a manual
  visual panel for projects with several servers (frontend+backend+API), no leases or
  auto-shutdown, in its own terminal tab.
- **`vmfleet status`** — a live overview of the fleet as a ready markdown table: which machines
  are up, how much RAM they actually use, IP addresses, pane state, ready-to-paste connection
  commands.
- **Scoped, safe access to external private resources** — git deploy keys (read or read-write, as
  needed) and, separately, access to private reference libraries through `gh api`, with no git
  clone at all: the token is installed on one specific project machine and never ends up in the
  golden image.
- **Publication hygiene** — the golden image is deliberately wiped of any personal
  authentication (git/Claude Code) before it's ever cloned onto a new machine.

## Deployment — done by an AI agent, not by you manually

The core idea of this whole project: **all of this is deployed on your local machine by an AI
agent itself** (Claude Code), not by following a manual instruction line by line. You describe the
task — the agent clones the image, configures the network, sets up the roles, verifies the
result. The docs/roadmap in this repository are what the agent works from, not a checklist for a
human.

The only steps the agent genuinely cannot do itself are the ones that require a secret that
belongs to you personally (a sudo password typed into a real terminal, adding a deploy key in a
GitHub repository's settings, clicking through a UAC dialog) — such moments are explicitly marked
in the docs as "needs a real human," with no attempt to work around them.

## About the IP addresses in the documentation

The docs and screenshots contain concrete private addresses like `192.168.130.x` — this is the
subnet of the **specific host** this system was built on, not something secret or universal.
Anyone deploying Cadence on their own machine will get their own range (VMware Workstation assigns
it itself when you configure the virtual network) — replace the example addresses with your own
when deploying; that's ordinary setup, not a leak.

## Demo

The orchestrator (`vmfleet.ps1`) introduces itself and, per its own canon, shows the live fleet
status as the first action of a session — which machines are up, how much RAM they use, ready
connection commands:

![Orchestrator — self-introduction and fleet status](docs/images/orchestrator-status.jpg)

Cross-role routing — the bureau pane recognizes a question isn't its area and forwards it to the
engineer over `tmux`; the answer is shown in the same pane:

![Cross-role routing between agent panes](docs/images/cross-role-demo.jpg)

`devpanel` — a manual panel for a project's several dev servers, address shown as a single
`IP:port` string ready to paste into a browser:

![devpanel — dev server table](docs/images/devpanel-table.jpg)

`mc` (Midnight Commander) — a file manager in its own tab, for quickly browsing the project tree
without leaving the main work:

![mc — file manager](docs/images/mc-file-browser.jpg)

`gh` — GitHub CLI, already installed on the image and ready to use:

![gh — GitHub CLI](docs/images/gh-cli.jpg)

## License

Cadence is distributed under **SESL (Shared Effort Software License)**, a configuration with
weighted consensus among multiple participants and individual, contribution-based authorship —
full text in [`LICENSE`](LICENSE) and summarized below. A formatted certificate with verifiable
License ID `282-20260913-d0fb6ee2-c5b7-4763-aa7e-e5e5f931edf2` sits in the repo root —
`SESL-CERTIFICATE.pdf`/`.html`. Generated by the SESL configurator — statistics and the
configuration generator itself: **[sesl.cvet.global/stats](https://sesl.cvet.global/stats)**.

**This isn't open source in the classic sense — but it serves the same protective function for
participants' interests.** The product was built for its own use, which is why it's genuinely
convenient: project decisions are made through negotiation among those whose contribution has
already been accepted, not arbitrarily by anyone from outside. Accepting a contribution is at the
same time accepting the person as a participant: a contribution must first be proposed and
approved, and only then does the contributor get a voice in further project decisions (voting
weight is proportional to the size of the contribution). Each participant keeps authorship over
their own specific contribution — anyone else using that piece needs the author's consent.
Commercial use under this configuration is governed by a separate document (SESL Commerce) and is
not covered by the base non-commercial grant.

## Quick start

**Deploy from scratch with an AI agent** — copy [`PROMPT.md`](PROMPT.md) in full into a chat with
Claude Code (or another agent with shell access on your Windows machine running VMware
Workstation) as the first message. The agent will build the golden image, configure the
orchestrator, and, if needed, deploy the first project machine — asking clarifying questions only
where the decision is genuinely yours to make (subnet, SSH user, secrets).

**Manually, step by step** — `docs/GOLDEN_IMAGE.md` (building the image) → edit the "CONFIG" block
in `vmfleet.ps1` for your host → `inventory.yaml.example` → `inventory.yaml` →
`docs/OPERATIONS.md` (day-to-day commands).

## Repository layout

```
vmfleet.ps1              — orchestrator (PowerShell, host)
inventory.yaml.example   — fleet registry template (the real inventory.yaml is gitignored)
PROMPT.md                — prompt for a from-scratch deployment by an AI agent
WhatIsIt.md              — what this is and what problems it solves (English)
FAQ.md                   — questions and answers, incl. bugs already fixed in main
HOW_TO_RUN.md            — how to run it: prerequisites, daily flow, common gotchas
make-shortcut.ps1        — desktop shortcut: fleet status + agent in one click
canon/agent-roles/       — CLAUDE.md for the engineer/bureau panes on the image
canon/TABS_AND_ROLES.md  — role model and physical places of work
golden-image/            — files to build the image (devctl/devpanel/start-agents.sh/systemd/...)
docs/GOLDEN_IMAGE.md     — step-by-step image build recipe
docs/OPERATIONS.md       — operations runbook (day-to-day commands)
docs/ACCEPTANCE.md       — system verification log
docs/decisions/          — write-ups of findings ("what broke and why"), not just a code comment
docs/images/             — demo screenshots
tests/                   — pure-logic tests (PowerShell/Pester + bash), see tests/README.md
```

## Status

Working live on a real project: code gets written and pushed, dev servers come up and shut down
on demand, agents coordinate with each other without a human on every step — all of it from a
single operator machine, through a handful of terminal tabs. The orchestrator's code and canon
have been migrated into this repository, with host-specific details (a particular host's network,
particular project names) generalized into configurable examples.

---

*Note: this file is a full translation of `README.md` for English-reading agents/humans. Every
other document in this repository (comments, `docs/`, `canon/`, `PROMPT.md`) is in Russian —
Claude Code agents read and follow Russian instructions natively, so nothing else is duplicated
here.*
