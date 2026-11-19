# Security policy

This repo exists to keep your main SSH agent and keys out of Docker Sandboxes, while letting
sandboxes sign git commits with a dedicated key. A flaw in it is worth reporting even if it seems
minor.

## Reporting a vulnerability

Please **don't open a public issue.** Report it privately through GitHub instead:

1. Open this repo's **Security** tab.
2. Choose **Report a vulnerability**.
3. Fill in the form.

Only the maintainer sees the report. We can discuss it and work on a fix there, then publish an
advisory once it's fixed.

Please include:

- what an attacker or a sandboxed agent can get or do, and what it needs first;
- steps to reproduce;
- your sbx version (`sbx version`), OS, and OpenSSH version (`ssh -V`).

## Supported versions

There are no releases yet. Only the latest commit on `main` is supported, so please check that
the problem still happens there.

## Scope

**In scope:** anything in this repo that weakens the isolation it's meant to provide. For example:

- a sandbox gets an SSH key or agent other than the agent signing key, such as your main agent;
- `sbx-signing-agent` loads the key into the wrong agent, kills an agent it didn't start, keeps
  the key loaded past its lifetime, or falls back to your main agent instead of failing closed;
- the `sbx-signing-agent` kit lets the key be used for anything other than git signatures;
- the documentation recommends something unsafe.

**Out of scope here:** please report these to the project concerned.

| Problem in | Report to |
|---|---|
| Docker Sandboxes (`sbx`) itself, including its SSH agent forwarding and kit capabilities | Docker |
| OpenSSH (`ssh-agent`, `ssh-add`) | OpenSSH |
| Your coding agent (e.g. Claude Code), including its permission modes | That agent's vendor (e.g. Anthropic) |

If you're unsure whether the cause is here or upstream, report it here and we'll work it out.

**Known limitations, not vulnerabilities:** the README's
[What it doesn't cover](README.md#what-it-doesnt-cover) section lists gaps this
tool doesn't try to close. One example: while the key is unlocked, any sandbox created with the
`sbx-signing-agent` kit can make commits GitHub shows as "Verified". A report that gets around a
documented limitation in a new way is still welcome.

## What to expect

This is a small project with one maintainer, so responses are best effort:

- an acknowledgement, usually within a week;
- an assessment and, if confirmed, a fix and a published advisory, credited to you unless you'd
  rather stay anonymous.

Please give us time to fix the problem before you disclose it publicly: up to 90 days from your
report, or sooner once a fix is published.
