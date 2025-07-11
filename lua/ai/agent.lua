local history_path = vim.fn.stdpath("data") .. "/ai/history.json"
local M = {}

local curl = require("plenary.curl")

--- Send prompt to OpenAI API
M.ask_openai = function(prompt, callback)
  local key = os.getenv("OPENAI_API_KEY")
  if not key then
    vim.notify("Missing OPENAI_API_KEY", vim.log.levels.ERROR)
    return
  end

  local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local spinner_idx = 1
  local notify_id = nil
  local spinner_active = true

  -- Start spinner
  local function update_spinner()
    if not spinner_active then return end
    notify_id = vim.notify("Asking OpenAI... " .. spinner_frames[spinner_idx], vim.log.levels.INFO, {
      title = "AI Assistant",
      replace = notify_id,
      hide_from_history = true,
    })
    spinner_idx = (spinner_idx % #spinner_frames) + 1
    vim.defer_fn(update_spinner, 100)
  end
  update_spinner()

  require("plenary.curl").post("https://api.openai.com/v1/chat/completions", {
    headers = {
      ["Content-Type"] = "application/json",
      ["Authorization"] = "Bearer " .. key,
    },
    body = vim.fn.json_encode({
      model = "gpt-4",
      messages = {
        { role = "system", content = "You are a helpful developer assistant inside Neovim." },
        { role = "user", content = prompt },
      },
    }),
    callback = function(response)
      spinner_active = false
      vim.schedule(function()
        local ok, data = pcall(vim.json.decode, response.body)
        if not ok then
          vim.notify("Failed to parse response", vim.log.levels.ERROR)
          return
        end
        local content = data.choices and data.choices[1] and data.choices[1].message.content
        if callback then callback(content) end
      end)
    end,
  })
end

--- Get current buffer or visual selection as context
M.get_context = function()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local _, ls, cs = unpack(vim.fn.getpos("'<"))
    local _, le, ce = unpack(vim.fn.getpos("'>"))
    local lines = vim.api.nvim_buf_get_lines(0, ls - 1, le, false)
    lines[#lines] = string.sub(lines[#lines], 1, ce)
    lines[1] = string.sub(lines[1], cs)
    return table.concat(lines, "\n")
  else
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end
end


local function read_history()
  local ok, data = pcall(vim.fn.readfile, history_path)
  if not ok or vim.tbl_isempty(data) then return {} end
  local joined = table.concat(data, "\n")
  local success, decoded = pcall(vim.json.decode, joined)
  return success and decoded or {}
end

local function write_history(entries)
  local encoded = vim.json.encode(entries or {})
  vim.fn.mkdir(vim.fn.fnamemodify(history_path, ":h"), "p")
  vim.fn.writefile(vim.split(encoded, "\n"), history_path)
end

local function add_to_history(entry)
  local history = read_history()
  table.insert(history, entry)
  write_history(history)
end

local function extract_all_code_blocks(md)
  local results = {}
  for block in md:gmatch("```[%w_]*\n(.-)\n```") do
    table.insert(results, vim.trim(block))
  end
  return table.concat(results, "\n\n")
end

--- Show output in floating window
M.show_output = function(content)
  vim.cmd("vsplit")

  -- Create a new scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  if not content then content = "[no response]" end

  -- Set content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))

  -- Guess filetype from current buffer
  local current_ft = vim.bo.filetype

  -- Try to match fenced code blocks first
  local first_line = vim.split(content, "\n")[1]
  local code_block_ft = first_line:match("^```([%w_]+)")

  -- Decide filetype for syntax highlight
  local guess_ft = code_block_ft or current_ft or "markdown"
  vim.bo[buf].filetype = guess_ft

  -- Open buffer in split
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].bufhidden = "wipe"
end

--- Main command
M.query = function()
  local context = M.get_context()
  vim.ui.input({ prompt = "Ask OpenAI: " }, function(user_input)
    if not user_input or user_input == "" then return end
    local full_prompt = user_input .. "\n\nContext:\n" .. context
    M.ask_openai(full_prompt, M.show_output)
  end)
end

M.refactor = function()
  local original = M.get_context()

  vim.ui.input({ prompt = "What should the AI do?" }, function(user_input)
    if not user_input or user_input == "" then return end

    local full_prompt = user_input .. "\n\nContext:\n" .. original

    M.ask_openai(full_prompt, function(response)
      if not response then
        vim.notify("AI returned no content", vim.log.levels.WARN)
        return
      end
      add_to_history({
        prompt = user_input,
        context = original,
        response = response,
        timestamp = os.time(),
      })
      local code = extract_all_code_blocks(response)
      if code == "" then
        vim.notify("❌ No code blocks found in AI response", vim.log.levels.WARN)
        return
      end
      M.apply_diff(original, code)
    end)
  end)
end

M.get_context = function()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local _, ls, cs = unpack(vim.fn.getpos("'<"))
    local _, le, ce = unpack(vim.fn.getpos("'>"))
    local lines = vim.api.nvim_buf_get_lines(0, ls - 1, le, false)
    lines[#lines] = string.sub(lines[#lines], 1, ce)
    lines[1] = string.sub(lines[1], cs)
    return table.concat(lines, "\n")
  else
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end
end

M.apply_diff = function(original_str, proposed_str)
  local proposed_lines = vim.split(proposed_str, "\n")

  -- Show preview popup
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, proposed_lines)
  vim.bo[buf].filetype = vim.bo.filetype
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.floor(vim.o.columns * 0.6)
  local height = math.min(#proposed_lines + 4, math.floor(vim.o.lines * 0.5))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
  })

  -- Ask for confirmation
  vim.defer_fn(function()
    vim.ui.select({ "Accept", "Decline" }, { prompt = "Apply AI suggestion?" }, function(choice)
      vim.api.nvim_win_close(win, true)
      if choice == "Accept" then
        local mode = vim.fn.mode()
        if mode == "v" or mode == "V" then
          local _, ls, cs = unpack(vim.fn.getpos("'<"))
          local _, le, ce = unpack(vim.fn.getpos("'>"))
          ls = ls - 1
          le = le
          vim.api.nvim_buf_set_lines(0, ls, le, false, proposed_lines)
          vim.notify("✅ AI changes applied to selection", vim.log.levels.INFO)
        else
          vim.api.nvim_buf_set_lines(0, 0, -1, false, proposed_lines)
          vim.notify("✅ AI changes applied to buffer", vim.log.levels.INFO)
        end
      else
        vim.notify("❌ AI changes discarded", vim.log.levels.INFO)
      end
    end)
  end, 100)
end

M.history_picker = function()
  local history = read_history()
  if vim.tbl_isempty(history) then
    vim.notify("No AI history yet.", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local conf = require("telescope.config").values

  pickers.new({}, {
    prompt_title = "AI History",
    finder = finders.new_table {
      results = history,
      entry_maker = function(entry)
        return {
          value = entry,
          ordinal = entry.prompt,
          display = os.date("%Y-%m-%d %H:%M", tonumber(entry.timestamp) or 0) .. " → " .. entry.prompt,
        }
      end,
    },
    previewer = previewers.new_buffer_previewer {
      define_preview = function(self, entry)
        local lines = {}
        table.insert(lines, "Prompt:\n" .. entry.value.prompt)
        table.insert(lines, "\nContext:\n" .. entry.value.context)
        table.insert(lines, "\nResponse:\n" .. entry.value.response)
        table.insert(lines, "\nTime: " .. os.date("%Y-%m-%d %H:%M:%S", tonumber(entry.value.timestamp) or 0))
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(table.concat(lines, "\n"), "\n"))
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      map("i", "<CR>", function(prompt_bufnr)
        local entry = require("telescope.actions.state").get_selected_entry()
        require("telescope.actions").close(prompt_bufnr)
        M.apply_diff(entry.value.context, entry.value.response)
      end)
      return true
    end,
  }):find()
end

return M
