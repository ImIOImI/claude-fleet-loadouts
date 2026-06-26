---
description: Author a claude-fleet "loadout" — a reusable bundle of skills, rules, slash commands and setup that installs into a workspace. Use when asked to create, write, or scaffold a loadout.
---

# Writing a claude-fleet loadout

A loadout is a folder that claude-fleet installs into a workspace's project
.claude/ directory. It bundles reusable Claude config (skills, slash commands,
subagents, rules, a CLAUDE.md block) plus optional setup (scripts, prompts).
Installing copies its files in; uninstalling removes exactly what it added.

## Folder layout

A loadout is one folder; its name is the loadout id.

    <loadout-id>/
      loadout.md               (required: metadata + instructions)
      CLAUDE.md                (optional: appended to the workspace CLAUDE.md)
      skills/<name>/SKILL.md    (optional)
      commands/<name>.md        (optional)
      agents/<name>.md          (optional)
      rules/<name>.md           (optional)
      output-styles/<name>.md   (optional)
      scripts/                  (optional: referenced from loadout.md)

Everything under skills/, commands/, agents/, rules/, output-styles/ plus a
root CLAUDE.md is copied into the workspace's .claude/ by convention — you do
not list those files anywhere, just put them in the folder. On install they
land at .claude/skills/<name>/SKILL.md, .claude/commands/<name>.md, etc.; the
root CLAUDE.md is appended to the workspace CLAUDE.md inside a marked block.

## loadout.md

YAML frontmatter followed by a markdown body (the body is human- and
agent-readable install instructions).

    ---
    title: Rust Pro
    version: 1.0.0
    description: Idiomatic Rust — clippy discipline, error handling. Use on a Cargo workspace.
    tags: [skill, rules, rust]
    dependencies:
      loadouts:
        - { id: base-dev, version: "^1.0.0" }
      tools:
        - { cmd: cargo, version: ">=1.75" }
    scripts:
      - label: install cargo tools
        run: cargo install cargo-nextest
        unless: command -v cargo-nextest
    prompts:
      - label: index the crate
        send: Read Cargo.toml and src/, then summarize the modules.
    ---

    What this loadout does, in prose.

Frontmatter fields:

- title — display name.
- description — the most important field: how a Claude instance decides whether
  the loadout is relevant. Say what it does AND when to use it.
- tags — for search and filtering in the library.
- version — semver; bump it when the loadout changes.
- dependencies.loadouts — other loadouts to install first (optional semver ranges).
- dependencies.tools — host commands the loadout expects; checked before install.
- scripts — shell commands run at install, inside the container sandbox. Add
  "unless: <check command>" to skip a script when it is already satisfied.
- prompts — messages sent to Claude after install.

## Skills, commands, agents, rules

A skill is skills/<skill-name>/SKILL.md with its own frontmatter:

    ---
    description: When Claude should use this skill.
    ---

    Instructions for the model.

Slash commands go in commands/<name>.md, subagents in agents/<name>.md, rules
in rules/<name>.md — each a markdown file in the format Claude Code expects.

## Rules of thumb

- One capability per loadout; keep it focused.
- Write a precise description — it is the relevance signal.
- The runner container is non-root (no apt / sudo). To provide a runtime, use a
  user-space installer (rustup, uv, nvm) in a scripts entry guarded by "unless".
- Loadouts install into a workspace's project .claude/ and load on the next
  Claude session in that workspace.
- Keep secrets out of loadouts — they are reusable across workspaces.

## A minimal rules-only loadout

    my-conventions/
      loadout.md      (title, description, tags)
      CLAUDE.md       (the rules to append)

No skills or scripts — just a CLAUDE.md block the loadout appends.
