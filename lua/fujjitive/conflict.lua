-- Reading jj's materialized conflict markers.
--
-- This module is deliberately READ-ONLY. It reconstructs what each side of a
-- conflict looks like so we can show them; it never rewrites your file. Taking
-- a side is done by Vim's own |diffget| (per hunk) or by jj's `resolve --tool`
-- (whole file), so no custom marker surgery ever touches your source.
--
-- jj's format is not git's, and the trap is that it is asymmetric AND the order
-- varies. One side is written as a diff from base, the other as literal
-- content, and which is which differs between a merge conflict:
--
--     <<<<<<< Conflict 1 of 1
--     %%%%%%% Changes from base to side #1     <- diff
--     -SHARED
--     +AAA
--      context
--     +++++++ Contents of side #2              <- literal
--     BBB
--     >>>>>>> Conflict 1 of 1 ends
--
-- ...and a rebase conflict, where those two sections swap places. So we key off
-- the section headers and never off position: assuming position silently swaps
-- the sides, which is the worst thing a merge tool can do quietly.
local M = {}

M.START = "^<<<<<<< Conflict"
M.FINISH = "^>>>>>>> Conflict"
-- `%` and `+` are Lua pattern metacharacters; build the runs rather than
-- writing fourteen escapes by hand and miscounting them.
M.SIDE_DIFF = "^" .. string.rep("%%", 7) .. " Changes from base to side #(%d+)"
M.SIDE_LITERAL = "^" .. string.rep("%+", 7) .. " Contents of side #(%d+)"

--- Split a materialized conflict into per-side whole-file reconstructions.
---
--- Returns { conflicted, max_side, hunks, sides = { [n] = lines }, base }.
--- `hunks[i]` carries `first`/`last`, the 1-based line range of the marker
--- block in the file as given.
function M.parse(lines)
  local segments = {}
  local common, hunk, section = nil, nil, nil
  local max_side = 0

  local function flush_common()
    if common then
      segments[#segments + 1] = { kind = "common", lines = common }
      common = nil
    end
  end

  for i, line in ipairs(lines) do
    if not hunk then
      if line:match(M.START) then
        flush_common()
        hunk = { kind = "conflict", first = i, sides = {}, base = {} }
        section = nil
      else
        common = common or {}
        common[#common + 1] = line
      end
    else
      local diff_side = line:match(M.SIDE_DIFF)
      local literal_side = line:match(M.SIDE_LITERAL)

      if diff_side or literal_side then
        local n = tonumber(diff_side or literal_side)
        section = { side = n, diff = diff_side ~= nil }
        hunk.sides[n] = hunk.sides[n] or {}
        max_side = math.max(max_side, n)
        -- A 3+-sided conflict can carry several diff sections. Base is shared,
        -- so only the first of them may fill it.
        if section.diff and not hunk.base_from then
          hunk.base_from = n
        end
      elseif line:match(M.FINISH) then
        hunk.last = i
        segments[#segments + 1] = hunk
        hunk, section = nil, nil
      elseif section then
        local side = hunk.sides[section.side]
        if not section.diff then
          side[#side + 1] = line
        else
          local mark, rest = line:sub(1, 1), line:sub(2)
          local owns_base = hunk.base_from == section.side
          if mark == "-" then
            -- base only
            if owns_base then
              hunk.base[#hunk.base + 1] = rest
            end
          elseif mark == "+" then
            side[#side + 1] = rest
          else
            -- context: shared by base and this side
            if owns_base then
              hunk.base[#hunk.base + 1] = rest
            end
            side[#side + 1] = rest
          end
        end
      end
    end
  end
  flush_common()

  local sides, base, hunks = {}, {}, {}
  for n = 1, max_side do
    sides[n] = {}
  end

  for _, seg in ipairs(segments) do
    if seg.kind == "common" then
      for _, l in ipairs(seg.lines) do
        for n = 1, max_side do
          sides[n][#sides[n] + 1] = l
        end
        base[#base + 1] = l
      end
    else
      -- Per-hunk sides too: taking a side means replacing exactly this
      -- marker block, so the caller needs the block's own content, not just
      -- the whole-file reconstruction.
      hunks[#hunks + 1] = {
        first = seg.first,
        last = seg.last,
        sides = seg.sides,
        base = seg.base,
      }
      for n = 1, max_side do
        -- A side that says nothing about this hunk keeps the base text.
        for _, l in ipairs(seg.sides[n] or seg.base) do
          sides[n][#sides[n] + 1] = l
        end
      end
      for _, l in ipairs(seg.base) do
        base[#base + 1] = l
      end
    end
  end

  return {
    conflicted = #hunks > 0,
    max_side = max_side,
    hunks = hunks,
    sides = sides,
    base = base,
  }
end

--- Per-line roles, for painting the conflict in place.
---
--- Returns { [lnum] = { role, side, mark } } where role is one of
--- "start" / "finish" / "header" / "content", `side` is which side the line
--- belongs to, and `mark` is the diff prefix ("-", "+" or " ") for content
--- inside a `%%%%%%%` section.
function M.regions(lines)
  local out = {}
  local inside, section = false, nil

  for i, line in ipairs(lines) do
    if not inside then
      if line:match(M.START) then
        inside, section = true, nil
        out[i] = { role = "start" }
      end
    elseif line:match(M.FINISH) then
      inside, section = false, nil
      out[i] = { role = "finish" }
    else
      local diff_side = line:match(M.SIDE_DIFF)
      local literal_side = line:match(M.SIDE_LITERAL)
      if diff_side or literal_side then
        section = { side = tonumber(diff_side or literal_side), diff = diff_side ~= nil }
        out[i] = { role = "header", side = section.side, diff = section.diff }
      elseif section then
        local mark = section.diff and line:sub(1, 1) or nil
        if mark ~= "-" and mark ~= "+" then
          mark = section.diff and " " or nil
        end
        out[i] = { role = "content", side = section.side, mark = mark }
      end
    end
  end
  return out
end

--- True if this file still has markers in it.
function M.is_conflicted(lines)
  for _, line in ipairs(lines) do
    if line:match(M.START) then
      return true
    end
  end
  return false
end

return M
