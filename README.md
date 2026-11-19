# sbx-signing-agent

Let coding agents in [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) **sign their git commits** with a dedicated
agent-only SSH key, without giving them your main SSH agent or any key that can
log in to GitHub.

It's a hardened replacement for the `start-isolated-ssh.sh` script from Micah Lee's post
[Sandboxing coding agents](https://micahflee.com/sandboxing-coding-agents/) (27 Aug 2026). See
[Background](#background-building-on-the-original-setup-script) for an overview of what was 
changed and why.

> **Status: experimental.** Developed and checked on Linux (Pop!_OS) with sbx v0.51.0 and
> v0.54.0. macOS should work but hasn't been tested. Windows isn't supported natively. See
> [Testing status and limitations](#testing-status-and-limitations). Test reports from other
> setups are welcome; see [Contributing](#contributing).

## How it works

Two parts, one on each side of the sandbox boundary, plus tests:

| File | Runs on | What it does |
|---|---|---|
| `sbx-signing-agent` | Host | Runs a separate `ssh-agent` holding **only** the agent signing key, on a fixed socket that sbx is pinned to. Every sandbox gets that agent, whichever terminal starts it. When the agent is stopped, signing **fails closed**: sandboxes never fall back to your main agent. The key is loaded with a lifetime (8h by default). |
| `kits/sbx-signing-agent/spec.yaml` | Sandbox | An sbx mixin kit that requests the agent for **git signatures only**, so the key can't log in anywhere. It also sets git's signing defaults and copies your git identity into the sandbox. Current sbx forwards no agent at all without a kit like this. See [Why the kit is needed](#why-the-sbx-signing-agent-kit-is-needed). |
| `tests/` | Your machine | Automated tests against a stand-in `sbx`; run `tests/run.sh`. See [Testing status](#testing-status-and-limitations). |

An optional add-on for JetBrains remote development is a separate repo,
[sbx-jetbrains-remote-dev](https://github.com/sean-reed/sbx-jetbrains-remote-dev). It works with or without the signing agent.

---

## Quickstart

### Prerequisites

- `bash` (it must be installed, but doesn't have to be the shell you use), `git`, OpenSSH
  (`ssh-agent`, `ssh-add`, `ssh-keygen`) and `sbx`.
- An agent signing key with a passphrase at `~/.ssh/agent-signing-key`. To create one:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/agent-signing-key -C "sbx agent signing key"
  ```
  **Creates `~/.ssh/agent-signing-key` and `.pub`.** Set a passphrase when asked.
- That key registered on GitHub as a **Signing Key only**, not an authentication key: Settings →
  SSH and GPG keys → New SSH key → Key type: *Signing Key*, then paste the contents of
  `~/.ssh/agent-signing-key.pub` (one line starting `ssh-ed25519`) into the Key field. Print it
  with `cat ~/.ssh/agent-signing-key.pub`. Use the `.pub` file, never the private key.
- `user.name` and `user.email` set in your host's global git config. The `sbx-signing-agent` kit copies
  them into sandboxes. The email must be a verified email on the GitHub account that holds the
  signing key, or GitHub won't show commits as "Verified". Check with
  `git config --global --get-regexp '^user\.'`.
- For pushing and pulling: a fine-grained GitHub token for each repo you use with a sandbox. See
  [Create a GitHub token for the repo](#create-a-github-token-for-the-repo). Signing works
  without one.

### Install

```bash
git clone https://github.com/sean-reed/sbx-signing-agent.git
cd sbx-signing-agent
install -m 0755 sbx-signing-agent ~/.local/bin/
```
Copies the script onto your `PATH`. **Creates `~/.local/bin/sbx-signing-agent`.** Undo by
deleting that file. Keep the clone: sandboxes are created with the kit folder from it.

On macOS, `~/.local/bin` isn't on `PATH` by default. Add it (e.g. `export PATH="$HOME/.local/bin:$PATH"`
in `~/.zshrc`), or install the script into a folder that already is, such as `/opt/homebrew/bin`.

In the commands below, `<kit>` means the full path to the `kits/sbx-signing-agent` folder inside
the `sbx-signing-agent` folder you just cloned, for example
`~/src/sbx-signing-agent/kits/sbx-signing-agent`. To print it, run this from that folder:

```bash
echo "$PWD/kits/sbx-signing-agent"
```

### One-time setup

```bash
sbx-signing-agent setup
```
Starts the agent and asks for the key's passphrase. Then it sets sbx's `ssh.agentSocketPath` to
the agent's socket and restarts the sbx daemon. **Changes sbx settings and interrupts running
sandboxes.** Undo with `sbx settings set ssh.agentSocketPath ""` followed by `sbx daemon restart`.

### Create a GitHub token for the repo

The sandbox needs a token to push, pull and (with `gh`) open pull requests. It **isn't needed
for signing**: without one, the agent can still make signed commits, it just can't push them. The
token and the signing key are separate: the token gives access to the repo, and the key only
signs.

On GitHub: Settings → Credentials → Fine-grained personal access tokens → Generate new token.

Suggested settings, to adjust for what you want the agent to do in this sandbox:

| Setting | Suggestion |
|---|---|
| Expiration | Short, e.g. 30 days, so a leaked token stops working soon |
| Repository access | **Only select repositories** and pick just this repo |

Under **Permissions → Repository permissions**:

| Permission | Suggestion |
|---|---|
| Contents | Read and write, so the agent can push |
| Pull requests | Read and write, only if the agent should open PRs |
| Metadata | Read (added automatically) |
| Workflows and everything else | Leave out unless the agent needs it. Without Workflows, it can't change `.github/workflows` |

Leave **Account permissions** empty.

Give only what the work needs: an agent that only reviews code might need just Contents: Read.
Which permissions sbx itself needs beyond these hasn't been checked. For a repo owned by an
organisation, the organisation may have to approve the token before it works.

Copy the token when GitHub shows it; you'll paste it into `sbx secret set` below. The token's
permissions define what the agent can do on GitHub; see [What it doesn't cover](#what-it-doesnt-cover).

### Create a sandbox that can sign

Start the agent before you work in a sandbox that uses the kit. sbx doesn't check: it creates
and starts the sandbox even when the agent is stopped (sbx v0.54.0). The sandbox then can't sign,
and because the kit turns on `commit.gpgsign`, git refuses to commit at all rather than making
unsigned commits. A running sandbox picks the agent up as soon as you run
`sbx-signing-agent start`, without a restart.

Run the commands from the repo's main checkout, not a git worktree, because clone mode needs it:

```bash
sbx-signing-agent start
cd ~/path/to/repo
sbx create --clone --name <name> --kit <kit> <agent> .
sbx secret set github --sandbox <name>
sbx run --name <name>
```
- `<name>` is a name you choose for the sandbox, e.g. `myrepo-agent`.
- `<kit>` is the full path to the `kits/sbx-signing-agent` folder in your copy of this repo
  (see [Install](#install)), e.g. `~/src/sbx-signing-agent/kits/sbx-signing-agent`. It must be a
  full path, not a relative one, because the commands first `cd` into the repo you're working on.
- `<agent>` is the coding agent the sandbox runs, the same name you'd normally pass to
  `sbx create`, e.g. `claude`. The signing kit is a mixin, so it adds to whichever agent's kit
  you choose. All of sbx v0.54.0's built-in agents have been checked (see
  [Testing status](#testing-status-and-limitations)).
- `sbx create` makes a clone-mode sandbox for this repo with the signing kit. **Creates a sandbox.**
  Leave out `--clone` to share the folder read-write instead; see
  [Clone mode and IDEs](#clone-mode-and-ides) for why clone mode is safer.

  **If you leave out `--clone`**, the sandbox shares your host repo's `.git/config`, so two more
  things apply:
  - Your host repo's settings override the kit's signing defaults and the identity it copies in.
    So in this mode, if your host repo sets `user.signingkey`, `gpg.format`, `user.name` or
    `user.email`, signing in the sandbox may fail or use the wrong identity. Check on the host,
    in the repo:
    ```bash
    git config --local --list | grep -E '^(user|gpg|commit|tag)\.'
    ```
    No output means nothing will interfere.
  - Your host repo's remotes are shared too, so an SSH remote URL needs the HTTPS rewrite in
    [Troubleshooting](#troubleshooting).
- `sbx secret set` stores the fine-grained GitHub token from
  [the step above](#create-a-github-token-for-the-repo) for **this sandbox only**; paste it when
  asked. **Stores a secret.** Skip it if `sbx secret ls` already lists `github` for `<name>`.
- `sbx run --name <name>` starts the sandbox and attaches you to the agent. (The older
  `sbx run <name>` is deprecated in sbx v0.51.0.)

**Don't leave out the `.`** (or another path). Without one, the sandbox has no workspace
(`Workspace: -` in `sbx inspect`). The agent then starts in an empty `/home/agent/workspace` and
reports that it isn't in a git repo.

**To add the kit to an existing sandbox, recreate it.** Don't use `sbx kit add`: with sbx
v0.54.0 it lists the kit and sets `SSH_AUTH_SOCK`, but never connects the agent, in direct mode,
clone mode or without a workspace. `ssh-add -L` in the sandbox then says
`Error connecting to agent: No such file or directory`, even after a restart.
Removing a clone-mode sandbox deletes its clone, so push or fetch any work first, then:

```bash
sbx rm <name>
```
and run the commands above again. **Removes the sandbox.**

### Check inside a sandbox

From a sandbox shell (TUI: select the sandbox and press `x`), from
`sbx exec -it -e TERM="$TERM" <name> bash` or through your agent if it can run shell commands
(in Claude Code, with a `!` prefix):

```bash
echo "$SSH_AUTH_SOCK"; ssh-add -L
```
Lists the keys the sandbox can use. It should show a socket path and **only** the
agent signing key.
- If any other key appears, the pinning isn't working: run `sbx-signing-agent status` on the host.
- If you get `Could not open a connection to your authentication agent`, see
  [Troubleshooting](#troubleshooting).

Then, in the sandbox's repo, check which git settings apply and where each comes from:

```bash
git --no-pager config --show-scope --show-origin --get-regexp '^(user|gpg|commit|tag)\.'
```
`--no-pager` is needed because the sandbox has no pager installed; without it, git fails with
`unable to execute pager`. Expect `gpg.format ssh` and `commit.gpgsign true` from the kit's file under
`~/.config/git/` and your host name and email in `global` scope. A `local` line for any of these
overrides them. In direct mode that line comes from your host repo's `.git/config`, which the
sandbox shares, so remove it there if it gets in the way. **Removing it changes your host repo's
config.** Pinning `user.signingkey` with `--global`, as below, doesn't override a `local` setting.

The kit sets git's signing defaults, so no manual git configuration is needed. It is still
harmless if you prefer to pin the key explicitly:

```bash
git config --global user.signingkey "key::$(ssh-add -L | head -n 1)"
```
Sets git to sign with the forwarded agent key. **Changes the sandbox's `~/.gitconfig`.**

To confirm that a commit made in the sandbox is signed:

```bash
git cat-file -p HEAD | grep -c gpgsig
```
`1` means it's signed, `0` means it isn't. Don't use `git log --show-signature` for this in the
sandbox. There's no allowed-signers file there, so it prints `No signature` even for a signed
commit. And because the agent controls the sandbox's git config, a "Good signature" there wouldn't
prove anything. Check signatures on GitHub or on the host instead (see below).

### Verify agent commits on the host

Two checks are real, because the agent can't change them:

- **On GitHub:** the commit shows **Verified**. Click the badge: its SSH key fingerprint should
  match the one `sbx-signing-agent status` prints.
- **On the host,** after you fetch or pull: `git log --show-signature` checks signatures against
  the file in your **host's** `gpg.ssh.allowedSignersFile`. Until the agent key is in that file,
  agent commits show `Good "git" signature … No principal matched`. To get the line to add:

  ```bash
  sbx-signing-agent allowed-signers
  ```
  It prints `<email> namespaces="git" <key>`, using your `git config --global user.email` (or an
  email you pass as an argument) and the key the agent holds, or `<key>.pub` if the agent isn't
  running. It also says which file to add it to. Paste the line into that file once; agent
  commits then show `Good "git" signature for <email>`. If you haven't set an allowed-signers
  file yet, create one and run `git config --global gpg.ssh.allowedSignersFile <file>`.
  **Changes your host's git config** (only that last command).

### Optional: use a different name or email

The kit copies your host's `user.name` and `user.email` as they are when the sandbox is created.
To change them for one sandbox, run these in a shell inside it. Both are optional.

To add an "(agent)" suffix to the name like in the original post:

```bash
git config --global user.name "$(git config --global user.name) (agent)"
```
Appends " (agent)" to the sandbox's git author name. **Changes the sandbox's `~/.gitconfig`.**
Running it again adds a second suffix.

To use a different name or email:

```bash
git config --global user.name "<name>"
git config --global user.email "<email>"
```
Sets the sandbox's git author name and email. **Changes the sandbox's `~/.gitconfig`.**

Undo either by setting the values back to your host's, shown on the host by
`git config --global --get-regexp '^user\.'`.

- **The email must be verified on the GitHub account that holds the signing key**, or commits
  lose the "Verified" badge. Your GitHub noreply address
  (`<id>+<username>@users.noreply.github.com`, under Settings → Emails) qualifies and keeps your
  real email out of commits. The name doesn't affect the badge.
- The change applies to **that sandbox only**, so repeat it for each sandbox. New sandboxes start
  from your host identity again.
- In direct mode, a `local` `user.name` or `user.email` in your host repo overrides these. The
  `git config --show-scope …` check above shows it.
- The name and email are only labels: the agent can change them. The real proof of origin is the
  agent signing key's fingerprint on the badge (see [What it doesn't cover](#what-it-doesnt-cover)).
- Whether sbx keeps the changed values after the sandbox restarts hasn't been tested. sbx fixes
  the identity when the sandbox is created, so it probably does.

---

## Daily use

```bash
sbx-signing-agent start
```
Starts the agent, or reuses it if it's running, and loads the key for the configured lifetime.
**Starts a background process.** It doesn't touch sbx. Run it again after the lifetime runs out.

```bash
sbx-signing-agent status
```
Shows whether the agent is running, which key it holds and whether sbx is pinned to its
socket.

```bash
sbx-signing-agent stop
```
Kills the agent and removes its socket and PID file. Sandboxes can no longer sign until you run
`start` again. **Stops a process and deletes those two files.**

`sbx-signing-agent allowed-signers` prints a line for your host's git allowed-signers file; see
[Verify agent commits on the host](#verify-agent-commits-on-the-host).

`sbx-signing-agent --help` prints a summary of the commands.

### Settings

All optional: without them, the script uses the defaults below. To change a default, set the
variable when running the script. If you change `SBX_SIGNING_KEY` or `SBX_SIGNING_SOCK`, set it
the same way every time you run the script, or it will look for a different key or socket.

| Variable | Default | Purpose |
|---|---|---|
| `SBX_SIGNING_KEY` | `~/.ssh/agent-signing-key` | Private key to load. If `<key>.pub` exists, its fingerprint is used for the isolation check. An encrypted older PEM-format key (`BEGIN RSA PRIVATE KEY` or `BEGIN EC PRIVATE KEY`) needs the `.pub`; `start` says how to create it. |
| `SBX_SIGNING_SOCK` | `~/.ssh/sbx-signing-agent.sock` | Agent socket path. Keep it short because Unix sockets are limited to about 104 characters. If you change it, run `setup` again. |
| `SBX_SIGNING_LIFETIME` | `8h` | How long the key stays loaded, in `ssh-add -t` format (`30m`, `8h`, `1d`) |

For example, `SBX_SIGNING_LIFETIME=2h sbx-signing-agent start`.

---

## Troubleshooting

`SSH_AUTH_SOCK` is empty inside the sandbox. Check these in order:

1. **The kit:** `sbx inspect <name>` must list the `sbx-signing-agent` kit next to your agent's
   kit (e.g. `docker.io/sbx/claude`).
   If it doesn't, recreate the sandbox with `--kit` (see [above](#create-a-sandbox-that-can-sign)).
   This is the most common cause. A kit added later with `sbx kit add` is listed but doesn't get
   the agent; `ssh-add -L` then says `Error connecting to agent: No such file or directory`.
   Recreate the sandbox in that case too.
2. **The agent:** `sbx-signing-agent status` must show the agent running, the key loaded and
   `ssh.agentSocketPath … (pinned)`.
3. **The order:** the sandbox must have started after the daemon picked up the pinned socket,
   which happens when `setup` restarts it. In `sbx inspect <name>`, the sandbox's running time
   (`State: running (…)`) should be **shorter** than the daemon's uptime (`Daemon: … uptime …`).
   If not, run `sbx stop <name>` and then `sbx run --name <name>`. The agent itself can start
   later: a sandbox started while it was stopped picks it up once you run `start` (sbx v0.54.0).
4. **Local kits:** if sbx rejects the kit directory, check `sbx settings get kit.allowLocalKits`.

`ssh-add -L` inside the sandbox says `The agent has no identities`: the socket and forwarding
work, but the agent holds no key, usually because the lifetime (8h by default) has run out. Run
`sbx-signing-agent start` on the host. A running sandbox sees the key straight away, without a
restart.

`git commit` in the sandbox fails with `gpg.ssh.defaultKeyCommand failed: error fetching
identities: communication with agent failed` and `user.signingKey needs to be set for ssh
signing`, or `ssh-add -L` says `communication with agent failed`: the signing agent isn't running.
Run `sbx-signing-agent start` on the host; a running sandbox picks it up without a restart.

`git pull` or `git push` in the sandbox fails with `Connection closed by … port 22`: the clone
copied your host's SSH remote URL, and the PAT only works over HTTPS. Rewrite GitHub URLs in the
sandbox with `git config --global url.https://github.com/.insteadOf git@github.com:`.

---

## What it doesn't cover

These gaps in the overall approach are outside this tool:

- **Shared workspace:** sbx mounts the workspace **read-write** by default. An agent can write
  `.git/hooks/*` or `.git/config` (e.g. `core.fsmonitor`), and that code runs on the **host** the
  next time you run `git` or open the folder in an IDE. Use sbx clone mode (`--clone`), where the
  host repo is mounted read-only, or review only through PRs on GitHub and never run git on the
  host in agent folders. See [Clone mode and IDEs](#clone-mode-and-ides) below.
- **What the PAT can do:** the token's permissions define what the agent can do on GitHub.
  Give it only what the agent needs, and use GitHub's branch rules to protect branches
  it shouldn't change.
- **What the signing key can do:** while the key is unlocked, any sandbox **created with the
  `sbx-signing-agent` kit** can produce commits that GitHub shows as "Verified" with your email, for any
  repo. The kit stops it using the key for anything else. Agent commits carry **your own name and
  email**, and the agent can change those anyway. The **key** is the only real proof of origin: on
  GitHub, the "Verified" badge of an agent commit shows the agent signing key's fingerprint.
- **What the agent does unchecked:** sbx's `claude` kit starts Claude Code in bypass-permissions
  mode, so the agent runs every action without a check, including pushing with the PAT and making
  commits GitHub shows as "Verified". A signature doesn't mean anyone reviewed the work. To turn
  bypass mode off, add `{"permissions": {"disableBypassPermissionsMode": "disable"}}` to the
  project's `.claude/settings.json`, or to `.claude/settings.local.json` inside the sandbox's
  workspace. Claude Code then starts in its normal default, auto mode (checked with sbx v0.54.0;
  see Claude Code's [permission modes](https://code.claude.com/docs/en/permission-modes)). Other
  agents may have similar settings.
- **Agent forwarding over SSH:** after `sbx setup ssh`, each sandbox is reachable as
  `ssh <name>.sbx` (see the sbx [integrations docs](https://docs.docker.com/ai/sandboxes/integrations/)).
  The block sbx writes into your SSH config sets `IdentityAgent none`, but that only stops `ssh`
  using your agent to log in. It doesn't set `ForwardAgent`, so a `Host *` block with
  `ForwardAgent yes` in your config still applies and offers your **main** agent to the sandbox,
  without asking. The docs don't say whether sbx accepts the forwarded agent, so don't rely on it
  refusing. Put this above any `Host *` block, because `ssh` uses the first value it finds:

  ```
  Host *.sbx
      ForwardAgent no
  ```
- **Templates:** `sbx template save` snapshots the sandbox's filesystem into an image that new
  sandboxes start from (see
  [Saving a sandbox as a template](https://docs.docker.com/ai/sandboxes/usage/#saving-a-sandbox-as-a-template)).
  Mounted folders such as a host workspace aren't included, but anything written inside the
  sandbox is, for example a token from `gh auth login` or a git credential helper, and possibly
  the agent's history or a clone-mode clone. Every sandbox made from the template, and anyone you
  give an exported template to, gets a copy. Secrets stored with `sbx secret set`, like the PAT in
  [Create a sandbox that can sign](#create-a-sandbox-that-can-sign), stay on the host and are
  injected by the sbx proxy, so they aren't captured. Save templates from a fresh sandbox that has
  only had tools installed.

---

## Clone mode and IDEs

This section isn't about the script. It covers how to review and work on agent output safely.

### Clone mode

From the sbx [usage docs](https://docs.docker.com/ai/sandboxes/usage/):

- `sbx create --clone --name <name> <agent> .` mounts the host repo **read-only** (at
  `/run/sandbox/source`) and gives the agent a **private clone** inside the sandbox. Run it from
  the main checkout, not a git worktree.
- The clone starts from the ref checked out on the host at creation time. No branch is created
  automatically. The docs don't say whether uncommitted host changes are copied, so commit first.
- It **does not stay in sync** with the host folder. Changes stay in the sandbox "until you fetch
  them or the agent pushes them".
- **Removing the sandbox deletes the clone**, so push or fetch any work you want to keep first.
- Clone mode can only be chosen when the sandbox is created. To switch, remove the sandbox and
  create it again.
- Several clone-mode sandboxes can start from one host checkout, so you don't need a separate
  clone of the repo per sandbox.

**For parallel tasks, the sbx docs use one clone-mode sandbox** (`sbx run --clone claude .`),
with each task in a separate background session. To keep the tasks apart, they suggest a project
instruction that tells the agent to create a separate git worktree and branch for each task. When
the agents finish, you `git fetch sandbox-<name>` on the host and review each branch.

All the worktrees in that sandbox share one `.git`, one filesystem and the same credentials (the
PAT and the signing agent), so a session working on one task can read or rewrite another task's
branches. That's fine when the tasks are equally trusted. Use a separate clone-mode sandbox per
task when you want them isolated from each other, for example to give each one its own narrowly
scoped PAT, or because one task handles untrusted input. That costs more VM resources and disk,
and each sandbox needs the signing setup from
[Create a sandbox that can sign](#create-a-sandbox-that-can-sign).

With the PR workflow, the agent pushes a branch with its PAT, you review the PR on GitHub and
then you `git pull` on the host.

### Why clone mode still helps if you pull to the host

Pulling still brings the agent's code to the host, but in a much more controlled way than direct mode:

| | Direct mode (shared folder) | Clone mode + `git pull` |
|---|---|---|
| `.git/hooks`, `.git/config` (`core.fsmonitor`, aliases, `core.sshCommand`) | The agent can write them, and they run on the host at your next `git status` | **Never transferred.** Git doesn't send them on fetch or pull |
| Ignored and untracked files (`.env`, build output, anything in `.gitignore`) | Appear on the host, and `git diff` doesn't show them | **Never transferred.** Only committed files arrive |
| When agent changes reach you | Immediately, as files change | **Only when you pull**, after you've had a chance to review |
| Seeing what changed | Partial, because hooks and ignored files are hidden | **Everything that arrives is in the commit diff** |

**Pulled code is still code.** Many IDEs run code from the repo as soon as you open it:

- Build scripts and build-tool plugins run when the IDE imports or indexes the project.
- Dependency restore can run install scripts from packages.
- Analyzers, code generators and language-server plugins configured by the project run inside
  the IDE.
- Run configurations and tasks checked into the repo can run commands.

Review the PR before opening or building it on the host. Watch especially for changes to build
files, package manifests and lockfiles, dependency source settings, toolchain version files, and
IDE settings folders such as `.idea/` and `.vscode/`. When your IDE asks whether to trust a
project, don't trust an agent-touched folder until you've reviewed it; an untrusted project opens
in a restricted mode. What that mode blocks in your IDE hasn't been checked.

### What to avoid

- **Mounting the sandbox's files onto the host** (e.g. with `sshfs`) and opening them in an IDE on
  the host. That runs the agent's build scripts and analyzers on the host, which removes the
  protection.
- **Direct mode with an IDE on the host.** IDEs run `git status` and builds in the background,
  so a planted hook or target can run without you doing anything.

To work on the agent's code on the host, use the PR workflow: review the diff on GitHub, then
pull and open it in your IDE. Treat that pull as the moment you decide to trust the code.

---

## Why the `sbx-signing-agent` kit is needed

### Symptom

Inside a sandbox, `ssh-add -L` says `Could not open a connection to your authentication agent`,
and `echo "$SSH_AUTH_SOCK"` is empty. This happens even though `sbx-signing-agent status` shows
the agent running and sbx pinned to its socket, and even after `sbx daemon restart` and restarting
the sandbox. Nothing about the agent appears in the daemon log
(`~/.local/state/sandboxes/sandboxes/sandboxd/daemon.log`).

### Cause

In current sbx (seen with v0.51.0 and v0.54.0), the sandbox side has its own gate. A sandbox gets an SSH agent
only if one of its **kits requests the capability `com.docker.sandbox/ssh-agent@1`**. The
[capability spec](https://github.com/docker/sandbox-kit-spec/blob/main/docs/spec/capabilities/com.docker.sandbox/ssh-agent@1.md)
says the runtime "MUST NOT give a sandbox that was not granted this capability any path to the
backing agent". Docker's
[credentials docs](https://docs.docker.com/ai/sandboxes/configuration/credentials/) say the same:
"V3 kits must also request `ssh-agent@1` … Without that request, no agent socket is forwarded".

A sandbox created with `sbx create claude` uses only the built-in `docker.io/sbx/claude` kit
(`sbx inspect <name>` lists its kits). In testing, that kit **did not get an agent**, so it
evidently doesn't request one. The same is true of every other built-in agent kit in sbx v0.54.0
(`codex`, `copilot`, `cursor`, `devin`, `docker-agent`, `droid`, `kiro`, `opencode` and `shell`).
`sbx kit inspect` doesn't list a kit's capabilities, so to check an agent kit yourself, create a
sandbox with it alone and look for an agent:

```bash
sbx create --name probe <agent>
sbx exec probe ssh-add -L     # "Could not open a connection…" = the kit doesn't request one
sbx rm --force probe
```
Adding the `sbx-signing-agent` kit is the right choice either way: it limits the agent to git
signatures, which an agent kit's own request might not do.

The post's flow worked when it was written (27 Aug 2026, sbx version not stated). The likely
explanation is that the built-in kit was older then, since only v3 kits have to request the
agent. Either way, the post's steps now fail without an error: sandboxes simply can't sign. That
fails closed, so it is safe, but it is confusing.

### What the kit does

`kits/sbx-signing-agent/spec.yaml` is adapted from Docker's own
[example mixin](https://github.com/docker/sandbox-kit-spec/tree/main/examples/git-signing). It:

- requests the agent for the **runtime** phase, **bounded to git signatures**
  (`unrestricted: false`, `sign: [git]`). The sandbox can't use the key to log in to any server or
  to sign anything other than git commits and tags;
- adds missing git signing defaults (`gpg.format ssh`,
  `gpg.ssh.defaultKeyCommand 'ssh-add -L'`, `commit.gpgsign`, `tag.gpgsign`) to the XDG git
  config. Settings in the sandbox's `~/.gitconfig` still take precedence;
- requests `com.docker.sandbox/git-identity@1` (added to Docker's example). sbx copies
  `user.name` and `user.email` from your **host's `git config --global`** into the sandbox's
  global git config. Without this, sandboxes have no author identity at all. The identity is
  **fixed when the sandbox is created**: changing your host config later only affects new
  sandboxes. sbx refuses to create the sandbox if either value is missing on the host. Only those
  two values are copied, never the rest of your git config. The name is used **as is**: unlike
  the post, this kit doesn't add an "(agent)" suffix;
- tells the agent that its commits are signed and what to do if signing is unavailable.

The request is **required**, not optional, but sbx v0.54.0 still creates and starts the sandbox
when no agent is reachable. Signing then fails, and so does every commit, because the kit turns
on `commit.gpgsign`.

This also narrows what the signing key can do (see [What it doesn't cover](#what-it-doesnt-cover)).
Sandboxes without the kit get no agent at all, and sandboxes with it can only make git signatures.

---

## Background: building on the original setup script

Micah Lee's post [Sandboxing coding agents](https://micahflee.com/sandboxing-coding-agents/)
sets up agent commit signing in four steps, the second being a script called
`start-isolated-ssh.sh`:

1. Create an agent-only SSH key with a passphrase and register it on GitHub as a **signing key only**
   (not an authentication key).
2. Run `start-isolated-ssh.sh` (sourced): it starts a new `ssh-agent`, loads only the agent key,
   points the shell's `SSH_AUTH_SOCK` at it and restarts the `sbx` daemon so sandboxes are
   meant to get that agent instead of your normal one.
3. Give each sandbox a fine-grained GitHub PAT scoped to one repo, with
   `sbx secret set github --sandbox <name>` (not the global secret).
4. Inside the sandbox, configure git to sign with the forwarded key and an "(agent)" author name.

Steps 1 and 3 are sound, and this repo keeps them as they are. `sbx-signing-agent` replaces
step 2. The `sbx-signing-agent` kit replaces step 4: it sets up signing automatically and copies
your host identity unchanged, without the "(agent)" suffix. You can
[add the suffix yourself](#optional-use-a-different-name-or-email). The original script is published
in [the post](https://micahflee.com/sandboxing-coding-agents/).

### Limitations of the original script

Limitations 1–3 were reproduced by running the script in bash, sh and dash against a fake `sbx`.
The rest come from reading the script and Docker's sbx documentation.

#### P1: The agent a sandbox gets depends on the terminal you start it from

The script assumes restarting the `sbx` daemon from the isolated shell makes it forward the
isolated agent. Docker's
[credentials documentation](https://docs.docker.com/ai/sandboxes/configuration/credentials/)
says otherwise:

> When `SSH_AUTH_SOCK` is set, Docker Sandboxes uses the value from the client that creates,
> starts, or joins each sandbox.

So the script only protects sandboxes started from the shell that sourced it. Start or join a
sandbox from another terminal, tmux window or IDE, where `SSH_AUTH_SOCK` still points at your main
agent, and that sandbox gets your main agent with all its keys. The setup **fails open** without
any warning.

#### P2: The "was I sourced?" check doesn't work in dash

The guard `if ! (return 0 2>/dev/null)` works in bash and zsh, but not in dash. On Debian, Ubuntu
and Pop!_OS, `/bin/sh` is dash, and the script's shebang is `#!/bin/sh`. Running it as
`sh start-isolated-ssh.sh` or `./start-isolated-ssh.sh` therefore runs the whole script in a
subshell. That leaves an **orphaned `ssh-agent` with the key unlocked indefinitely** and no
`stop_isolated_ssh` function to clean it up.

#### P3: No check that `ssh-agent` actually started

`eval "$(ssh-agent -s)"` isn't checked. If `ssh-agent` fails, `SSH_AUTH_SOCK` and `SSH_AGENT_PID`
still point at your **previous** agent, and then:

- the agent key is loaded into your previous (main) agent,
- the script reports the agent as isolated, although it isn't,
- `stop_isolated_ssh` later **kills your previous agent** because it saved that agent's PID as the
  "isolated" one.

#### P4: It aborts if `sbx daemon stop` fails

`if ! sbx daemon stop; then … return 1`. If `sbx daemon stop` returns an error when no daemon is
running, for example after a fresh boot, the script refuses to start.

#### P5: Stopping leaves the daemon down

Both `stop_isolated_ssh` and the script's error paths run `sbx daemon stop` but never restart it.
The next `sbx` command starts the daemon from whatever shell runs it, which feeds into P1.

#### P6: The key never expires

`ssh-add` is called without `-t`. Until you remember to run `stop_isolated_ssh` or reboot, any
sandbox can request signatures. With P2, nothing may be left that can stop it.

#### P7: It assumes the agent is clean

The script trusts that the new agent holds only the agent key and never checks. Nothing stops
another key from being added to that socket later.

#### P8: The paths don't match

The script's comments say `~/.local/bin/start-isolated-ssh.sh`, while the post says to save it as
`~/code/start-isolated-ssh.sh`.

### How `sbx-signing-agent` fixes them

| Limitation | Change | Why it fixes it |
|---|---|---|
| **P1** fails open | The agent listens on a **fixed socket** (`~/.ssh/sbx-signing-agent.sock`), and `setup` pins sbx to it with `sbx settings set ssh.agentSocketPath`. | Every sandbox gets this socket whichever terminal starts or joins it. When the agent isn't running, sandboxes get a dead socket: signing **fails closed** instead of falling back to your main agent. |
| **P1, P2** sourcing | The script is **run, not sourced**, and never changes your shell's environment. It refuses to run if sourced or started by a non-bash shell, using `return 1 2>/dev/null \|\| exit 1` so the calling shell stays open. | Nothing depends on which shell you're in, and the dash problem disappears. Your shell's `SSH_AUTH_SOCK` stays on your main agent, which is where it belongs. |
| **P3** unchecked agent start | It checks the result of `ssh-agent -a <sock>`, reads the PID from its output and confirms the socket answers. Every `ssh-add` call explicitly sets `SSH_AUTH_SOCK=<our socket>` and clears `SSH_AGENT_PID`. | The key can't end up in your main agent, and `stop` can't kill an agent this script didn't start. |
| **P4, P5** daemon handling | Daily `start` and `stop` don't touch the sbx daemon. Only the one-time `setup` restarts it to apply the pinned socket. | Because the socket path never changes, sbx doesn't need restarting each session, and stopping the agent doesn't leave sbx in a confused state. |
| **P6** no expiry | The key is loaded with a lifetime (`ssh-agent -t` and `ssh-add -t`), **8h by default**. | A forgotten agent stops being useful after the lifetime. `status` tells you when the key has expired. |
| **P7** agent not checked | Every `start` clears the agent (`ssh-add -D`), loads the key and checks the agent holds **exactly one key with the expected fingerprint**. Otherwise it stops the agent. | Isolation is checked on every start, not assumed. |
| Other edge cases | A stale socket or PID file left after a crash or reboot is cleaned up. An agent on the socket that this script didn't start is neither used nor killed. If the key fails to load (e.g. wrong passphrase), the agent is stopped. `set -euo pipefail`, `umask 077`. | No orphaned agents holding the key, and no blind `kill`. |
| **P8** paths | A single command that lives on your `PATH`. | Nothing to keep in sync. |

---

## Testing status and limitations

- **Platforms:**
  - **Linux:** developed and checked on Pop!_OS with sbx v0.51.0 and v0.54.0.
  - **macOS:** expected to work but untested. The script avoids Linux-only tools and bash 4
    features, so it should run with macOS's bash 3.2 and OpenSSH. Whether sbx on macOS honours
    `ssh.agentSocketPath` the same way is the part that needs checking. `~/.local/bin` isn't on
    `PATH` by default (see [Install](#install)), and `tests/run.sh` skips its dash test because
    macOS has no dash.
  - **Windows:** not supported natively. The script needs bash and a Unix socket
    (`ssh-agent -a`), and Windows' OpenSSH agent uses a named pipe instead. WSL2 is untested and
    could only work if `sbx` and its daemon also run inside the same WSL2 distro.
- **Automated tests:** `tests/run.sh` runs the script against a stand-in `sbx`
  (`tests/fake-bin/sbx`), with throwaway keys and its own agents in a temporary folder. It never
  touches your SSH agent, `~/.ssh` or your sbx settings. Run `tests/run.sh --list` to see the
  cases: start, reuse, setup, status and stop; cleanup after a crash; refusing an agent it
  didn't start; not killing an unrelated process or another ssh-agent named in a stale PID file;
  removing an extra key; right and wrong passphrases; a `.pub` that doesn't match; PEM-format
  keys without a `.pub` (unencrypted works, encrypted is refused before any agent starts); the
  key lifetime running out; refusing to be sourced, piped into bash, or run by sh, dash or zsh;
  an sbx without `settings get`; a socket path with spaces; and the `allowed-signers` line (from
  our agent or the `.pub`, never a foreign agent, with no email, and refusing pattern
  characters). Needs OpenSSH 8.4 or later and git 2.32 or later.
- **Checked against real sbx:**
  - `sbx settings get ssh.agentSocketPath` exists, and `setup` pinned the socket successfully
    (`source: user`). (v0.51.0)
  - With the built-in `claude` kit alone, the sandbox got **no agent** despite the pinned socket, a
    daemon restart and a sandbox restart. This is the reason for the kit. (v0.51.0)
  - The `sbx-signing-agent` kit works end to end in a clone-mode (`--clone`) sandbox:
    `ssh-add -L` shows only the agent key, commits carry your host name and email and are signed,
    a push with the PAT works (the clone inherited the host's SSH remote URL, so this used the
    HTTPS rewrite from [Troubleshooting](#troubleshooting)), and GitHub shows the commit as "Verified" with the agent key's
    fingerprint. In the sandbox, `git log --show-signature` reports a good signature only when
    given an allowed-signers file that lists the agent key; without one it says `No signature`.
    (v0.54.0)
  - `sbx kit add` on an existing sandbox lists the kit but **doesn't connect the agent**:
    `SSH_AUTH_SOCK` points at `/run/ssh-agent.sock`, which doesn't exist. This happens in direct
    mode, in clone mode and without a workspace, and in the last case even after `sbx stop` and
    a restart. Without a workspace, files in `/home/agent/workspace` and elsewhere in the home
    directory survive. The same kit given to `sbx create --kit` works. (v0.54.0)
  - Local kits are allowed by default: `sbx settings ls` shows `kit.allowLocalKits` as `true`
    with source `default`. (v0.54.0)
  - A running sandbox follows the agent across a restart of the agent **process**: after
    `sbx-signing-agent stop`, `ssh-add -L` in the sandbox fails (`communication with agent
    failed`); after `start` (a new PID at the same socket), the same shell sees the key again and
    makes a signed commit, without restarting the sandbox. (v0.54.0)
  - Every built-in agent (`claude`, `codex`, `copilot`, `cursor`, `devin`, `docker-agent`,
    `droid`, `kiro`, `opencode`, `shell`): without the kit, the sandbox gets **no agent**; with
    it, the sandbox sees only the agent key, can sign in the `git` namespace, and is **refused**
    signing in another namespace (`ssh-keygen -Y sign -n file`). Checked in sandboxes without a
    workspace. (v0.54.0)
  - **Terminal independence and no leaks:** with a decoy key in the agent of the terminal that
    created, started and joined the sandbox, `ssh-add -l` in the sandbox showed only the signing
    key, never the decoy. (v0.54.0)
  - **Signing only:** `ssh-add -T` in the sandbox, which asks for the kind of signature an SSH
    login uses, gets `agent refused operation`. (`ssh -T git@github.com` can't test this: the
    sandbox's network policy closes SSH connections to GitHub before authentication.) (v0.54.0)
  - **Fails closed:** after `sbx-signing-agent stop`, `git commit` in a running sandbox fails
    rather than making an unsigned commit. sbx still creates and starts sandboxes with the kit
    while the agent is stopped; they can't sign or commit. (v0.54.0)
  - **Lifetime:** with `SBX_SIGNING_LIFETIME=2m`, the running sandbox showed `The agent has no
    identities` and couldn't commit after expiry; `start` brought the key back without a sandbox
    restart. (v0.54.0)
  - A sandbox **started while the agent was stopped** picks the agent up once it's started: the
    same shell, and a new `sbx exec` session, then see the key and make signed commits. (v0.54.0)
- **Not yet tested:**
  1. macOS and WSL2 (see Platforms above).
  2. Whether newer sbx versions fix `sbx kit add` (see above).

---

## Contributing

Contributions are welcome: bug reports, test results, documentation fixes and code. The most
useful right now is trying an item from the [Not yet tested](#testing-status-and-limitations)
list on your setup and opening a **Test report** issue. See [CONTRIBUTING.md](CONTRIBUTING.md)
for how to run the tests and the rules for changes, and [SECURITY.md](SECURITY.md) for reporting
security problems privately.

## Credits

- The approach and the original `start-isolated-ssh.sh` this replaces come from Micah Lee's post
  [Sandboxing coding agents](https://micahflee.com/sandboxing-coding-agents/).
- `kits/sbx-signing-agent/spec.yaml` is adapted from the `git-signing` example in Docker's
  [sandbox-kit-spec](https://github.com/docker/sandbox-kit-spec/tree/main/examples/git-signing),
  licensed under Apache-2.0. The changes are listed in the file's header comment.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
