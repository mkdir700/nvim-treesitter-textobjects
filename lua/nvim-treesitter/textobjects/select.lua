local api = vim.api
local configs = require "nvim-treesitter.configs"
local parsers = require "nvim-treesitter.parsers"
local queries = require "nvim-treesitter.query"

local shared = require "nvim-treesitter.textobjects.shared"
local ts_utils = require "nvim-treesitter.ts_utils"

local M = {}

local function get_char_after_position(bufnr, row, col)
  if row == nil then
    return nil
  end
  local ok, char = pcall(vim.api.nvim_buf_get_text, bufnr, row, col, row, col + 1, {})
  if ok then
    return char[1]
  end
end

local function is_whitespace_after(bufnr, row, col)
  local char = get_char_after_position(bufnr, row, col)
  if char == nil then
    return false
  end
  if char == "" then
    if row == vim.api.nvim_buf_line_count(bufnr) - 1 then
      return false
    else
      return true
    end
  end
  return string.match(char, "%s")
end

local function get_line(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
end

local function next_position(bufnr, row, col, forward)
  local max_col = #get_line(bufnr, row)
  local max_row = vim.api.nvim_buf_line_count(bufnr)
  if forward then
    if col == max_col then
      if row == max_row then
        return nil
      end
      row = row + 1
      col = 0
    else
      col = col + 1
    end
  else
    if col == 0 then
      if row == 0 then
        return nil
      end
      row = row - 1
      col = #get_line(bufnr, row)
    else
      col = col - 1
    end
  end
  return row, col
end

local function include_surrounding_whitespace(bufnr, textobject, selection_mode)
  local start_row, start_col, end_row, end_col = unpack(textobject)
  local extended = false
  while is_whitespace_after(bufnr, end_row, end_col) do
    extended = true
    end_row, end_col = next_position(bufnr, end_row, end_col, true)
  end
  if extended then
    -- don't extend in both directions
    return { start_row, start_col, end_row, end_col }
  end
  local next_row, next_col = next_position(bufnr, start_row, start_col, false)
  while is_whitespace_after(bufnr, next_row, next_col) do
    start_row = next_row
    start_col = next_col
    next_row, next_col = next_position(bufnr, start_row, start_col, false)
  end
  if selection_mode == "linewise" then
    start_row, start_col = next_position(bufnr, start_row, start_col, true)
  end
  return { start_row, start_col, end_row, end_col }
end

local val_or_return = function(val, opts)
  if type(val) == "function" then
    return val(opts)
  else
    return val
  end
end

function M.select_textobject(query_string, keymap_mode)
  local lookahead = configs.get_module("textobjects.select").lookahead
  local lookbehind = configs.get_module("textobjects.select").lookbehind
  local surrounding_whitespace = configs.get_module("textobjects.select").include_surrounding_whitespace
  local bufnr, textobject =
    shared.textobject_at_point(query_string, nil, nil, { lookahead = lookahead, lookbehind = lookbehind })
  if textobject then
    local selection_mode = M.detect_selection_mode(query_string, keymap_mode)
    if
      val_or_return(surrounding_whitespace, {
        query_string = query_string,
        selection_mode = selection_mode,
      })
    then
      textobject = include_surrounding_whitespace(bufnr, textobject, selection_mode)
    end
    ts_utils.update_selection(bufnr, textobject, selection_mode)
  end
end

function M.detect_selection_mode(query_string, keymap_mode)
  -- Update selection mode with different methods based on keymapping mode
  local keymap_to_method = {
    o = "operator-pending",
    s = "visual",
    v = "visual",
    x = "visual",
  }
  local method = keymap_to_method[keymap_mode]

  local config = configs.get_module "textobjects.select"
  local selection_modes = val_or_return(config.selection_modes, { query_string = query_string, method = method })
  local selection_mode
  if type(selection_modes) == "table" then
    selection_mode = selection_modes[query_string] or "v"
  else
    selection_mode = selection_modes or "v"
  end

  -- According to "mode()" mapping, if we are in operator pending mode or visual mode,
  -- then last char is {v,V,<C-v>}, exept for "no", which is "o", in which case we honor
  -- last set `selection_mode`
  local visual_mode = vim.fn.mode(1)
  visual_mode = visual_mode:sub(#visual_mode)
  selection_mode = visual_mode == "o" and selection_mode or visual_mode

  return selection_mode
end

function M.attach(bufnr, lang)
  local buf = bufnr or api.nvim_get_current_buf()
  local config = configs.get_module "textobjects.select"
  lang = lang or parsers.get_buf_lang(buf)

  for mapping, query in pairs(config.keymaps) do
    local desc
    if type(query) == "table" then
      desc = query.desc
      query = query.query
    end
    if not desc then
      desc = "Select textobject " .. query
    end
    if not queries.get_query(lang, "textobjects") then
      query = nil
    end
    if query then
      local cmd_o = "<cmd>lua require'nvim-treesitter.textobjects.select'.select_textobject('" .. query .. "', 'o')<CR>"
      local cmd_x = "<cmd>lua require'nvim-treesitter.textobjects.select'.select_textobject('" .. query .. "', 'x')<CR>"
      vim.keymap.set({ "o" }, mapping, cmd_o, { buffer = buf, silent = true, remap = false, desc = desc })
      vim.keymap.set({ "x" }, mapping, cmd_x, { buffer = buf, silent = true, remap = false, desc = desc })
    end
  end
end

function M.detach(bufnr)
  local buf = bufnr or api.nvim_get_current_buf()
  local config = configs.get_module "textobjects.select"
  local lang = parsers.get_buf_lang(bufnr)

  for mapping, query in pairs(config.keymaps) do
    if not queries.get_query(lang, "textobjects") then
      query = nil
    end
    if type(query) == "table" then
      query = query.query
    end
    if query then
      vim.keymap.del({ "o", "x" }, mapping, { buffer = buf })
    end
  end
end

M.commands = {
  TSTextobjectSelect = {
    run = M.select_textobject,
    args = {
      "-nargs=1",
      "-complete=custom,nvim_treesitter_textobjects#available_textobjects",
    },
  },
}

return M
