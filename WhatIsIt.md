# What is Cadence

I designed Cadence for myself — to drive production-grade development on a gaming laptop. The
architecture isn't locked to this scale: the same fleet of lightweight virtual machines can be
deployed on an enterprise Windows or Linux server. Doing so requires an abstraction layer above the
hypervisor instead of direct VMware calls, alongside non-interactive agent authentication. Both
tasks are clear and open for collaboration.

Cadence resolves four fundamental problems that typically force large organizations to maintain
platform engineering teams: context isolation, environment reproducibility, workflow parallelism,
and manual resource management. It tackles them not through workarounds, but via an inventory file
as the single source of truth, profiles instead of branch bloating, and a lease protocol instead of
manual approvals. All of this runs on a single 16 GB laptop — hardware never originally intended
for multi-agent execution.

The boundary the project is crossing right now is the shift from "it works on my machine" to "it
works for anyone who clones the repository." This line is defined by documentation, not code. The
repository accepts fixes daily; every bug uncovered during installation is resolved in `main` on
the very same day.

---

**Where to go next:** [`HOW_TO_RUN.md`](HOW_TO_RUN.md) — how to actually run it ·
[`PROMPT.md`](PROMPT.md) — deploy from scratch with an AI agent ·
[`README.md`](README.md) — full description (Russian) · [`README_EN.txt`](README_EN.txt) — the same
in English.
