---
name: browser
description: Drive a real Chromium browser via Microsoft's playwright-cli. Use when web_fetch can't see the page (SPA, login required, JS-rendered content, click/fill/scroll needed). Otherwise prefer web_fetch.
metadata:
  havn:
    source: pack
    pack: havn-pack-browser
    pack_version: "0.1.0"
  requires:
    bins: [playwright-cli]
    install: "see https://github.com/amplimit/havn-pack-browser"
---

# Browser automation (havn-pack-browser)

You can drive a real Chromium browser by calling the `playwright-cli` binary
through your `shell` tool. This skill covers **when to reach for the
browser** and **havn-specific hygiene**. The full command surface is
maintained by Microsoft and lives bundled with the binary — read it on
demand:

```bash
file_read /opt/havn/playwright-cli/node_modules/playwright-core/lib/tools/cli-client/skill/SKILL.md
```

Reading it once at the start of a browser-heavy task is cheaper than guessing
commands and burning iterations on `unknown command` errors.

## Decide first: web_fetch or browser?

`web_fetch` is faster, cheaper, leaves no session state. Use the browser only
when web_fetch demonstrably can't help.

| Situation                                       | Use         |
|-------------------------------------------------|-------------|
| Static HTML, server-rendered, REST/JSON API     | `web_fetch` |
| OG metadata, RSS, sitemap, robots.txt           | `web_fetch` |
| Body looks like `<div id="root"></div>` + script tag (React shell) | browser |
| Need to click / fill a form / scroll / hover    | browser     |
| Page requires login state (cookies / auth)      | browser     |
| Data rendered after a `fetch()` in JS           | browser     |
| Infinite-scroll feed                            | browser     |
| File download triggered by a button             | browser     |

If you're unsure, try `web_fetch` first; switching costs almost nothing.
Switching the other way (browser → web_fetch) is cheaper than re-running a
multi-step browser flow.

## Mental model

`playwright-cli` is **stateful**: the browser persists across invocations.
You issue one shell command per action.

The interaction loop is:

1. `playwright-cli open <url>` (or `goto`)
2. `playwright-cli snapshot` → CLI prints a YAML file path
3. `file_read` that path to see the accessibility tree
4. Use the `e<n>` / `f0e<n>` element refs from the snapshot in subsequent
   commands (`click e15`, `fill e7 "..."`, etc.)
5. **Re-snapshot after any state change** (navigation, click that re-renders,
   modal). Refs are valid only against the most recent snapshot.

## Minimal example

```bash
shell: playwright-cli open https://example.com
shell: playwright-cli snapshot
# → /tmp/playwright-cli-snap-2026-05-05T03-42-11.yaml
file_read: /tmp/playwright-cli-snap-2026-05-05T03-42-11.yaml
# pick the ref of what you want, e.g. e3 for "More information…" link
shell: playwright-cli click e3
shell: playwright-cli snapshot --filename=after-click.yaml
file_read: after-click.yaml
shell: playwright-cli close
```

For anything beyond this — keyboard, drag, network mocking, multiple tabs,
cookies, evaluating JS expressions, recording video, etc. — `file_read` the
canonical SKILL.md (path above). It's ~400 lines of accurate, vendor-
maintained command docs.

## havn-specific hygiene

- **Workspace is the right place to write.** `playwright-cli` lets you
  pick where snapshots / screenshots / PDFs / state.json land — keep them
  inside your agent workspace (current directory by default). Don't write
  to `/tmp` for anything you want again later.
- **Login state is sensitive.** When you `state-save auth.json`, treat
  that file like a credential. Don't read its contents back to the user
  unless asked. Don't copy the contents into typed memory via
  `memory_remember`. The path can go in memory ("login state for site X
  saved at workspace/.playwright-cli/auth.json"), the value can't.
- **Close when done.** `playwright-cli close` ends the browser session.
  Leaving sessions open doesn't break anything — they share the agent's
  cgroup memory cap — but a hung browser eating ~300 MB is noisy and
  visible in `havn status`.
- **Don't loop forever.** If a page is hostile / flaky after 2-3
  attempts, stop. Take a `screenshot --full-page`, share it with the
  user, and decide together. Your iteration cap will end the loop with
  nothing to show otherwise.
- **Re-snapshot rule, redux.** Every time the page state changes
  (navigation completes, a click triggers re-render, a modal opens or
  closes), re-snapshot before using new refs. The most common error mode
  is "ref e21 not found" because you tried to use a stale ref.

## Errors specific to this pack

| Error                                              | Likely cause                                | Fix |
|----------------------------------------------------|---------------------------------------------|-----|
| `playwright-cli: command not found`                | Pack isn't installed on this host          | Tell the user to run havn-pack-browser's `setup.sh` |
| `Browser closed unexpectedly` immediately on open  | Chromium sandbox conflict with the agent's namespace seccomp profile | Operator may need to enable Chromium sandbox syscalls in policy — see havn-pack-browser README "Future" section |
| `executable doesn't exist at .../chromium`         | `setup.sh`'s `playwright install chromium` step didn't finish | Re-run setup.sh with PLAYWRIGHT_BROWSERS_PATH unset |

For everything else, the canonical SKILL.md's error table covers more.

## Don't use the browser as a fancy curl

If your task is "fetch this REST endpoint and parse the JSON", that's
`web_fetch`. Spinning up Chromium for it costs ~300 MB of memory and 1-2 s of
startup vs `web_fetch`'s ~50 ms and zero RAM. The user is paying tokens for
both your decisions and the browser's screenshots; pick the cheap path when
it works.
