# Project example layout

A **project** is a repository-independent organisational unit owning a tree
of issues. Tasks attach to issues; worker agents claim issues; reviewer
agents approve or reject; a built-in `merger` backend lands the PR.

This directory shows the on-disk shape under `~/.agent/projects/`. You
normally never hand-edit these files — use `orchestra project` /
`orchestra issue` or the MCP tools (`manage_issues`, `work_issues`,
`review_issues`) — but the layout is documented here for inspection and
backup.

```
~/.agent/projects/
  <project-id>.json              # Project record
  <project-id>/
    issues/<issue-id>.json       # Issue record (parentId, attached PRs, status, …)
    claims/<issue-id>.json       # Per-issue lock; presence == "claimed"
```

Files in this directory:

- `sample-project.json` — a project with a default target plus an optional
  reviewer template (F1 auto-enqueue).
- `sample-issue-root.json` — a top-level issue.
- `sample-issue-child.json` — a sub-issue (`parent_id` set).

CLI cheat sheet:

```sh
# Create a multi-org project (no default target — every issue must specify)
orchestra project create "Mono-repo cleanup"

# Create a project bound to one repo
orchestra project create "API v2" --default-repo myorg/api --default-branch main

# List
orchestra project list
orchestra issue list <project-id>
orchestra issue list <project-id> --status open

# Add issues
orchestra issue add <project-id> --title "Top-level task"
orchestra issue add <project-id> --title "Subtask" --parent <issue-id>
orchestra issue add <project-id> --title "Cross-org" \
  --target-repo other/repo --target-branch dev

orchestra issue show <issue-id>
orchestra issue close <issue-id>      # marks abandoned (review flow handles completed)
```

Tool permission groups (set via the task config's `tools` list):

- `manage_issues` — plan agents: list / create / update issues + sub-issues.
- `work_issues` — worker agents: list open issues, claim, attach PR, release, split into sub-issues.
- `review_issues` — reviewer agents: list in-review, approve / reject.

## Roles

A *role* is a reusable task template — backend, prompt template, the
permission set the agent gets, and an optional auto-dispatch policy.
Role names are user-defined; only the dispatcher's set of triggers is
fixed (`has_open_issues` | `has_in_review_issues` | `idle`).

Files (project overrides global by name):

```
~/.agent/roles/<name>.json                       -- global
~/.agent/projects/<pid>/roles/<name>.json        -- per-project override
```

Examples in `roles/`: `implementor.json`, `reviewer.json`, `planner.json`.
Each ships with `dispatch.max: 0` so auto-spawn is opt-in — set caps in a
dispatcher listener config (see `examples/listeners/auto-dispatcher.json`)
to enable.

Manual spawning:

```sh
orchestra roles list <project-id>                       # see what's available
orchestra spawn <role-name> <project-id> [--prompt ...]  # ad-hoc spawn
orchestra spawn implementor <project-id> --issue <iid>   # pre-claims via daemon
```

Auto-dispatch listener:

```json
{
  "source": {
    "type": "project-dispatcher",
    "project_id": "<pid>",
    "caps": { "implementor": 2, "reviewer": 1, "planner": 1 }
  },
  "interval_seconds": 30
}
```

Each tick the dispatcher counts queue entries `(status ∈ {pending, running}) ∧ projectId == this ∧ role == X`, and if `count < cap` and the role's trigger holds, enqueues exactly one new entry per role.
