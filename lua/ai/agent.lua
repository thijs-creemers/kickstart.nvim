local M = {}

local curl = require("plenary.curl")

--- Send prompt to OpenAI API
M.ask_openai = function(prompt, callback)
  local key = os.getenv("OPENAI_API_KEY")
  if not key then
    vim.notify("Missing OPENAI_API_KEY", vim.log.levels.ERROR)
    return
  end

  curl.post("https://api.openai.com/v1/chat/completions", {
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
    local ok, data = pcall(vim.json.decode, response.body)
    if not ok then
      vim.schedule(function()
        vim.notify("Failed to parse response: " .. tostring(response.body), vim.log.levels.ERROR)
      end)
      return
    end

    local content = data.choices and data.choices[1] and data.choices[1].message.content
    vim.schedule(function()
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

--- Show output in floating window
M.show_output = function(content)
  vim.cmd("vsplit")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content or "[no response]", "\n"))
  vim.api.nvim_win_set_buf(0, buf)
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

return M
