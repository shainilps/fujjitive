# fujjitive

Fugitive-style [jj](https://jj-vcs.github.io/jj/) change review for Neovim.

`jj log` graph on top, live diff below, Vim-native navigation. Move the cursor, the diff follows.

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

You get a new tab: graph on top, diff below.

---

## Using it

Inside the graph:

| key | does |
|-----|------|
| `j` / `k` | next / previous **change** (not line — multi-line entries step once) |
| `h` / `l` | hop to the adjacent graph lane |
| `<CR>` | jump into the diff pane (to scroll it) |
| `d` | toggle the diff pane |
| `R` | refresh |
| `q` | close |
| `g?` | show this list |

`h` and `l` move between the columns you can see. From `swntmrkz` above, `l` jumps to the
`rvmqwvxw` lane; `h` comes back. It picks the nearest occupied column in that direction, then
the nearest change within it.

### Commands

Every one acts on the change **under the cursor**, then refreshes the graph and keeps your place.

| command | does |
|---------|------|
| `:JJ` | open the graph |
| `:JJ new` | new change on top of this one |
| `:JJ edit` | make this change the working copy |
| `:JJ describe` | edit the description in a split — **`:w` applies it** |
| `:JJ squash` | squash this change into its parent |
| `:JJ abandon` | abandon it (asks first) |
| `:JJ undo` | undo the last jj operation |

`<Tab>` completes the subcommand names. Extra arguments pass straight through to jj, so
`:JJ new --no-edit` works.

`:JJ undo` is worth remembering while you're finding your feet: jj's undo is why poking at the
graph is safe.

---

## Configuration

All optional. These are the defaults:

```lua
require("fujjitive").setup({
  revset       = nil,                  -- nil = your `revsets.log` setting
  log_template = "builtin_log_compact",-- any jj template expression
  diff_height  = 0.55,                 -- diff pane, as a fraction of the tab
  diff_debounce = 60,                  -- ms to wait after the cursor stops
  diff_format  = "--color-words",      -- or "--git" for a plain unified diff
  default_keymaps = true,              -- false to define your own
  node_glyphs  = { "@", "○", "◆", "×", "●", "◉", "o", "+", "x", "*" },
})
```

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
jj log -T '"\x00" ++ change_id.short(12) ++ "\x00" ++ builtin_log_compact'
```

A line carrying the sentinel starts a change; a line without one belongs to the change above it.
The sentinel is stripped before anything reaches the buffer.

**Colour.** jj also has a `--color=debug` mode that emits `<<label::text>>` markers, which looks
like the easier parse — but the payload isn't escaped, so any diff line containing `>>` (C++
streams, shift operators, conflict markers) corrupts it. So `ansi.lua` parses real ANSI SGR
instead, which source code can't forge. Both panes run through it, which is why the graph gets
jj's own colours without a syntax file.

One flag carries more weight than it looks: diff loads pass `--ignore-working-copy`. Without it
every `j` keypress snapshots your working copy and writes to the op log.

| file | job |
|------|-----|
| `lua/fujjitive/jj.lua` | async `vim.system` wrapper, repo-root detection |
| `lua/fujjitive/ansi.lua` | ANSI SGR → highlight spans |
| `lua/fujjitive/graph.lua` | graph pane, sentinel parse, `j/k/h/l` |
| `lua/fujjitive/diff.lua` | diff pane, debounce, cache |
| `lua/fujjitive/ops.lua` | `:JJ` subcommands |
| `lua/fujjitive/config.lua` | defaults |

## Not included (yet)

Generic `:JJ <anything>` passthrough, rebase/duplicate, bookmark management, and `<CR>` on a
file in the diff to open it at that revision.
