-- Turns ANSI (SGR) coloured bytes into plain text plus highlight spans.
--
-- We parse ANSI rather than jj's `--color=debug` label syntax on purpose:
-- `--color=debug` emits <<label::text>> markers whose payload is *not* escaped,
-- so any diff line containing ">>" (C++ streams, shift operators, conflict
-- markers) would corrupt the parse. ESC sequences never appear in source code.
--
-- Both the graph and the diff pane run through here, which is why the graph
-- gets jj's real colours without a hand-written syntax file.
local M = {}

M.ns = vim.api.nvim_create_namespace("fujjitive_ansi")

local hl_cache = {}
local hl_counter = 0
local palette

--- xterm's 256-colour palette as hex strings.
local function build_palette()
  if palette then
    return palette
  end
  palette = {
    [0] = "#000000", "#cc0000", "#4e9a06", "#c4a000",
    "#3465a4", "#75507b", "#06989a", "#d3d7cf",
    "#555753", "#ef2929", "#8ae234", "#fce94f",
    "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec",
  }
  local levels = { 0, 95, 135, 175, 215, 255 }
  for r = 0, 5 do
    for g = 0, 5 do
      for b = 0, 5 do
        palette[16 + 36 * r + 6 * g + b] =
          string.format("#%02x%02x%02x", levels[r + 1], levels[g + 1], levels[b + 1])
      end
    end
  end
  for i = 0, 23 do
    local v = 8 + i * 10
    palette[232 + i] = string.format("#%02x%02x%02x", v, v, v)
  end
  return palette
end

--- Highlight groups are created on demand and cached, so a long diff reuses a
--- handful of groups rather than creating one per span.
local function hl_for(attrs)
  if not (attrs.fg or attrs.bg or attrs.bold or attrs.italic or attrs.underline or attrs.reverse) then
    return nil
  end
  local key = table.concat({
    attrs.fg or "-",
    attrs.bg or "-",
    attrs.bold and "b" or "-",
    attrs.italic and "i" or "-",
    attrs.underline and "u" or "-",
    attrs.reverse and "r" or "-",
  }, ":")

  local name = hl_cache[key]
  if name then
    return name
  end

  hl_counter = hl_counter + 1
  name = "FujjitiveAnsi" .. hl_counter
  vim.api.nvim_set_hl(0, name, {
    fg = attrs.fg,
    bg = attrs.bg,
    bold = attrs.bold,
    italic = attrs.italic,
    underline = attrs.underline,
    reverse = attrs.reverse,
  })
  hl_cache[key] = name
  return name
end

local function apply_sgr(attrs, params)
  local pal = build_palette()
  local i = 1
  while i <= #params do
    local p = params[i]
    if p == 0 then
      attrs.fg, attrs.bg = nil, nil
      attrs.bold, attrs.italic, attrs.underline, attrs.reverse = nil, nil, nil, nil
    elseif p == 1 then attrs.bold = true
    elseif p == 3 then attrs.italic = true
    elseif p == 4 then attrs.underline = true
    elseif p == 7 then attrs.reverse = true
    elseif p == 22 then attrs.bold = nil
    elseif p == 23 then attrs.italic = nil
    elseif p == 24 then attrs.underline = nil
    elseif p == 27 then attrs.reverse = nil
    elseif p >= 30 and p <= 37 then attrs.fg = pal[p - 30]
    elseif p == 39 then attrs.fg = nil
    elseif p >= 40 and p <= 47 then attrs.bg = pal[p - 40]
    elseif p == 49 then attrs.bg = nil
    elseif p >= 90 and p <= 97 then attrs.fg = pal[p - 90 + 8]
    elseif p >= 100 and p <= 107 then attrs.bg = pal[p - 100 + 8]
    elseif p == 38 or p == 48 then
      local target = (p == 38) and "fg" or "bg"
      local mode = params[i + 1]
      if mode == 5 then
        attrs[target] = pal[params[i + 2] or 0]
        i = i + 2
      elseif mode == 2 then
        attrs[target] = string.format("#%02x%02x%02x",
          params[i + 2] or 0, params[i + 3] or 0, params[i + 4] or 0)
        i = i + 4
      end
    end
    i = i + 1
  end
end

--- Parse a blob of ANSI-coloured output.
--- Returns `lines` (plain text) and `highlights`, a table mapping a 1-based
--- line number to a list of { start_col, end_col, hl_group } byte ranges.
function M.parse(data)
  local lines, highlights = {}, {}
  local attrs = {}
  local buf, spans = {}, {}
  local col, span_start, span_hl = 0, 0, nil

  local function close_span()
    if span_hl and col > span_start then
      spans[#spans + 1] = { span_start, col, span_hl }
    end
    span_start = col
  end

  local function flush_line()
    close_span()
    local idx = #lines + 1
    lines[idx] = table.concat(buf)
    if #spans > 0 then
      highlights[idx] = spans
    end
    -- `attrs` and `span_hl` deliberately survive: SGR state carries across lines.
    buf, spans = {}, {}
    col, span_start = 0, 0
  end

  local function push(text)
    if #text > 0 then
      buf[#buf + 1] = text
      col = col + #text
    end
  end

  local i, n = 1, #data
  while i <= n do
    local esc = data:find("\27", i, true)
    local chunk_end = esc and (esc - 1) or n

    local j = i
    while j <= chunk_end do
      local nl = data:find("\n", j, true)
      if nl and nl <= chunk_end then
        push(data:sub(j, nl - 1))
        flush_line()
        j = nl + 1
      else
        push(data:sub(j, chunk_end))
        j = chunk_end + 1
      end
    end

    if not esc then
      break
    end

    local params_str, final, after = data:match("^\27%[([%d;]*)([%a])()", esc)
    if params_str then
      if final == "m" then
        close_span()
        local params = {}
        for p in params_str:gmatch("[^;]+") do
          params[#params + 1] = tonumber(p)
        end
        if #params == 0 then
          params = { 0 }
        end
        apply_sgr(attrs, params)
        span_hl = hl_for(attrs)
        span_start = col
      end
      i = after
    else
      -- Not a CSI sequence we recognise; drop the ESC and carry on.
      i = esc + 1
    end
  end

  if #buf > 0 then
    flush_line()
  end

  return lines, highlights
end

--- Write parsed lines and their highlights into a buffer.
function M.render(bufnr, lines, highlights)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  for lnum, spans in pairs(highlights) do
    local len = #(lines[lnum] or "")
    for _, span in ipairs(spans) do
      local s, e = span[1], math.min(span[2], len)
      if e > s then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, s, {
          end_col = e,
          hl_group = span[3],
        })
      end
    end
  end

  vim.bo[bufnr].modifiable = false
end

return M
