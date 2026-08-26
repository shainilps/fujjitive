# fujjitive

Fugitive-style [jj](https://jj-vcs.github.io/jj/) change review for Neovim.

`jj log` graph in the **bottom half** of your screen, Vim-native navigation, and the change
you're reading opens in the top half **only when you ask for it**. Until then the top half stays
yours. No new tab, nothing takes over the screen.

```
@  swntmrkz me@example.com 2026-08-25 786fc00a
│  feat B2: theme polish
○  nupyrstz me@example.com 2026-08-25 dda714e2
│  feat B: theme
│ ○  rvmqwvxw me@example.com 2026-08-25 dfd1e5fb
│ │  feat A2: more colors
│ ○  yxksrlls me@example.com 2026-08-25 0755b504
├─╯  feat A: colors
○  yxwwypsm me@example.com 2026-08-25 3d4541b9
│  base: initial file
◆  zzzzzzzz root() 00000000
```

This is deliberately **not** a full jj client. It does one thing: make reviewing jj changes
feel good inside Neovim.

Requires Neovim 0.10+ (for `vim.system`) and `jj` on your `PATH`. Developed against jj 0.36.

---

## Installing it into your Neovim

You're installing from a **local folder**, not from GitHub. The whole trick is one field:
a lazy.nvim plugin spec normally starts with a `"owner/repo"` string, which tells lazy to clone
it. Replacing that with `dir = "<path>"` says *"it's already on disk, just use it."*

No symlink, no copying, no `git push`. You edit the files in place and restart Neovim.

### Step 1 — add one file

Your config loads every file in `~/.config/nvim/lua/plugins/`, one plugin per file. Create a
new one, `~/.config/nvim/lua/plugins/fujjitive.lua`:

```lua
return {
  dir = "/home/codeshaine/focus/fujjitive",
  name = "fujjitive",
  cmd = { "JJ", "Fujjitive" },  -- only loads the first time you run :JJ
  config = function()
    require("fujjitive").setup({})
  end,
}
```

That's the entire installation. `setup({})` is optional — the defaults are fine — but calling
it is where you'd put options later.

### Step 2 — restart Neovim and check it registered

Run `:Lazy`. You should see **fujjitive** in the list, marked as a local/`dir` plugin.

If it isn't there, the file is in the wrong place. Confirm with:

```
ls ~/.config/nvim/lua/plugins/fujjitive.lua
```

### Step 3 — use it

`cd` into any jj repo and run:

```vim
:JJ
```

The graph opens in the bottom half of the window you're already in. Your code keeps the top
half. Press `K` on a change to see what it did.

---

## Using it

`:JJ` gives you the graph in the bottom half:

| key | does |
|-----|------|
| `j` / `k` | next / previous **change** (not line — multi-line entries step once) |
| `<Tab>` / `<S-Tab>` | jump to the next / previous **branch** |
| `K` | **view this change** in the top half |
| `<CR>` | view it and jump into that window |
| `e` | `jj edit` — make this change the working copy |
| `n` | `jj new` on top of this change |
| `s` | `jj squash` into its parent |
| `a` | `jj abandon` (asks first) |
| `cc` | edit the description — **`:w` applies it** |
| `gs` | switch to `jj status` |
| `R` | refresh |
| `q` | close |
| `g?` | show this list |

`<Tab>` cycles the **branch tips** and wraps around at the end. It works off jj's actual parent
topology, not the drawn columns — jj puts sibling branches in the *same* column, so anything
column-based would silently skip branches. With three siblings you get all three.

`K` is the only thing that puts a diff on screen. Moving around the graph costs nothing — no
subprocess, no working-copy snapshot. Press `q` in the change view and the top half goes back to
whatever was there.

### `:JJ status`

`:JJ status` (or `:JJ st`) swaps the bottom half to `jj status` — jj's own output, verbatim:

```
Working copy changes:
M src/ansi.lua
D old.txt
A src/status.lua
Working copy  (@) : tvlmlwnv 8249553c feat: colors
Parent commit (@-): rpkkzytq cc285c3e init files
```

| key | does |
|-----|------|
| `dv` | **side-by-side diff of this file** — a real Vim diff, like Fugitive's `dv` |
| `ds` | same, stacked instead of side by side |
| `<CR>` | open the file itself |
| `X` | discard this file's changes (asks first) |
| `J` / `K` | next / previous file |
| `gl` | back to the graph |
| `R` / `q` | refresh / close |

**It reloads itself.** Write any file in the repo, come back to the window, or refocus Neovim,
and the list updates — you don't re-run `:JJ st` to see what you just changed. Writes outside
the repo are ignored, and a burst of them (`:wall`, a formatter) costs one `jj status`.

`dv` opens two windows in the top half in real Vim diff mode: the file as of `@-` on the left,
your working copy on the right. The right side is the actual file, so you can edit it there and
`:w`. `q` closes both and turns diff mode off.

Fugitive diffs against the git index. jj has no index, so `dv` diffs against `@-`, the parent of
the working copy — which is exactly what `jj status` is reporting on.

### Commands

| command | does |
|---------|------|
| `:JJ` | open the graph |
| `:JJ log` | switch the panel back to the graph |
| `:JJ status` | switch the panel to the file list (`:JJ st` works too) |
| `:JJ new` | new change on top of this one |
| `:JJ edit` | make this change the working copy |
| `:JJ describe` | edit the description on top — **`:w` applies it** |
| `:JJ squash` | squash this change into its parent |
| `:JJ abandon` | abandon it (asks first) |
| `:JJ undo` | undo the last jj operation |

In the graph these act on the change under the cursor; in the status view they act on the
working copy. `<Tab>` completes the names, and extra arguments pass straight through to jj, so
`:JJ new --no-edit` works.

`:JJ undo` is worth remembering while you're finding your feet — jj's undo is why poking at the
graph is safe.

---

## Configuration

All optional. These are the defaults:

```lua
require("fujjitive").setup({
  revset       = nil,                   -- nil = your `revsets.log` setting
  log_template = "builtin_log_compact", -- any jj template expression
  panel_height = 0.5,                   -- bottom panel, as a fraction of the screen
  show_format  = "--color-words",       -- or "--git" for a plain unified diff
  show_template = [[if(description, description, "(no description set)\n")]],
  diff_against = "@-",                  -- what `dv` compares against
  default_keymaps = true,               -- false to define your own
  node_glyphs  = { "@", "○", "◆", "×", "●", "◉", "o", "+", "x", "*" },
})
```

`show_template` is the header above the diff when you press `K`. The default prints the
description and nothing else. Set it to `nil` if you want jj's own header back — commit ID,
change ID, author, committer, timestamps.


To see your whole history rather than jj's default view:

```lua
require("fujjitive").setup({ revset = "::" })
```

---

## Working on the plugin

### Reloading after you edit a file

**This is the one thing that trips everyone up on their first plugin.** Neovim caches `require`d
Lua modules. Editing `lua/fujjitive/graph.lua` changes *nothing* until that cache is dropped —
so it looks like your edit did nothing, and you go hunting for a bug that isn't there.

Either restart Neovim, or:

```vim
:Lazy reload fujjitive
```

If you're iterating hard, restarting is the honest option — module-level state survives a reload.

### Where errors actually show up

The live-diff hook runs inside an autocmd, and errors there scroll past silently. When something
seems dead, check:

```vim
:messages
```

### Isolating a problem

To load the plugin with **none** of your config — no other plugins, no colorscheme, nothing:

```bash
nvim --clean -c "set rtp+=/home/codeshaine/focus/fujjitive" -c "runtime plugin/fujjitive.lua"
```

Then `:JJ`. If it works here but not in your normal config, it's a conflict with another plugin
(most likely a keymap). If it's broken here too, it's the plugin.

### Tests

The ANSI parser and the graph parser are pure functions and have real tests:

```bash
nvim --headless --clean -c "set rtp+=." -c "luafile tests/run.lua" -c "qa!"
```

Worth running after touching `ansi.lua` or `graph.lua`, because a bug in either one shows up in
the UI as a *rendering* problem when it's really a parse problem.

### Uninstalling

Delete `~/.config/nvim/lua/plugins/fujjitive.lua`.

---

## How it works

Two things in here are less obvious than they look.

**Mapping a buffer line back to a change.** jj's graph has multi-line entries, edge-only lines,
and elided-revision nodes, so "line N = change N" is false. The template emits a NUL-wrapped
change ID at the start of each change's first line:

```
jj log -T '"\x00" ++ change_id.short(12) ++ "\x01"
       ++ parents.map(|p| p.change_id().short(12)).join(",") ++ "\x00" ++ builtin_log_compact'
```

A line carrying the sentinel starts a change; a line without one belongs to the change above it.
The whole sentinel is stripped before anything reaches the buffer.

**Telling branches apart.** The payload also carries each change's parents, which is what `<Tab>`
cycles on. The obvious approach — hop between the columns jj draws — is wrong, and quietly so:
jj renders sibling branches in the *same* column at different rows, so a column hop bounces
between two of your three branches and never reaches the third. A branch tip is a change nothing
else in view descends from, and that needs topology, not geometry.

**Colour.** jj also has a `--color=debug` mode that emits `<<label::text>>` markers, which looks
like the easier parse — but the payload isn't escaped, so any diff line containing `>>` (C++
streams, shift operators, conflict markers) corrupts it. So `ansi.lua` parses real ANSI SGR
instead, which source code can't forge. Both panes run through it, which is why the graph gets
jj's own colours without a syntax file.

**Not snapshotting the working copy.** Everything that only *reads* a change passes
`--ignore-working-copy`. Without it, viewing a change would snapshot your working copy and write
an entry to the op log. `jj status` is the deliberate exception — it's *about* the working copy,
so it snapshots on purpose.

**Giving the top half back.** `K` and `dv` don't open a window, they borrow the one you came
from, remembering which buffer was in it. `q` puts that buffer back. That's why the layout stays
an honest two halves instead of accumulating slivers.

| file | job |
|------|-----|
| `lua/fujjitive/jj.lua` | async `vim.system` wrapper, repo-root detection |
| `lua/fujjitive/ansi.lua` | ANSI SGR → highlight spans |
| `lua/fujjitive/panel.lua` | the bottom panel, and borrowing/returning the top half |
| `lua/fujjitive/graph.lua` | graph view, sentinel parse, `j/k/h/l` |
| `lua/fujjitive/status.lua` | `jj status` view, line → path map, `X` |
| `lua/fujjitive/show.lua` | the change view `K` opens |
| `lua/fujjitive/vdiff.lua` | `dv` — real Vim diff of one file against `@-` |
| `lua/fujjitive/ops.lua` | `:JJ` subcommands |
| `lua/fujjitive/config.lua` | defaults |

## Not included (yet)

Generic `:JJ <anything>` passthrough, rebase/duplicate, bookmark management, and a file list
per change (right now `K` shows the whole change as one buffer; `dv` only works from
`:JJ status`).

`s` is squash because `a` was already abandon. That pair still wants a better answer.
