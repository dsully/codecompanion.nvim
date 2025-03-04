local adapters = require("codecompanion.adapters")
local client = require("codecompanion.http")
local config = require("codecompanion.config")

local keymaps = require("codecompanion.utils.keymaps")
local log = require("codecompanion.utils.log")
local msg_utils = require("codecompanion.utils.messages")
local ui = require("codecompanion.utils.ui")
local util = require("codecompanion.utils")

local api = vim.api

local CONSTANTS = {
  AUTOCMD_GROUP = "codecompanion.inline",

  PLACEMENT_PROMPT = [[I would like you to assess a prompt which has been made from within the Neovim text editor. Based on this prompt, I require you to determine where the output from this prompt should be placed. I am calling this determination the "<method>". For example, the user may wish for the output to be placed in one of the following ways:

1. `replace` the current selection
2. `add` after the current cursor position
3. `before` before the current cursor position
4. `new` in a new buffer/file
5. `chat` in a buffer which the user can then interact with

Here are some example prompts and their correct method classification ("<method>") to help you:

- "Can you refactor/fix/amend this code?" would be `replace` as we're changing existing code
- "Can you create a method/function that does XYZ" would be `add` as it requires new code to be added to a buffer
- "Can you add a docstring to this function?" would be `before` as docstrings are typically before the start of a function
- "Can you create a method/function for XYZ and put it in a new buffer?" would be `new` as the user is explicitly asking for a new buffer
- "Can you write unit tests for this code?" would be `new` as tests are commonly written in a new file away from the logic of the code they're testing
- "Why is Neovim so popular?" or "What does this code do?" would be `chat` as the answer does not result in code being written and is a discursive topic leading to additional follow-up questions
- "Write some comments for this code." would be `replace` as we're changing existing code

The user may also provide a prompt which references a conversation you've had with them previously. Just focus on determining the correct method classification.

Please respond to this prompt in the format "<method>", placing the classification in a tag. For example "replace" would be `<replace>`, "add" would be `<add>`, "before" would be `<before>`, "new" would be `<new>` and "chat" would be `<chat>`. If you can't classify the message, reply with `<error>`. Do not provide any other content in your response or you'll break the plugin this is being called from.]],
  CODE_ONLY_PROMPT = [[The following response must contain ONLY raw code that can be directly written to a Neovim buffer:

1. No Markdown formatting or backticks
2. No explanations or prose
3. Use proper indentation for the target language
4. Include language-appropriate comments when needed
5. Use actual line breaks (not \n)
6. Preserve all whitespace
7. Only include relevant code (no full file echoing)

If you cannot provide clean file-ready code, reply with `<error>`]],
}

---Format given lines into a code block alongside a prompt
---@param prompt string
---@param filetype string
---@param lines table
---@return string
local function code_block(prompt, filetype, lines)
  return prompt .. ":\n\n" .. "```" .. filetype .. "\n" .. table.concat(lines, "\n") .. "\n```\n"
end

---Overwrite the given selection in the buffer with an empty string
---@param context table
local function overwrite_selection(context)
  log:trace("Overwriting selection: %s", context)
  if context.start_col > 0 then
    context.start_col = context.start_col - 1
  end

  local line_length = #vim.api.nvim_buf_get_lines(context.bufnr, context.end_line - 1, context.end_line, true)[1]
  if context.end_col > line_length then
    context.end_col = line_length
  end

  api.nvim_buf_set_text(
    context.bufnr,
    context.start_line - 1,
    context.start_col,
    context.end_line - 1,
    context.end_col,
    { "" }
  )
  api.nvim_win_set_cursor(context.winnr, { context.start_line, context.start_col })
end

---@class CodeCompanion.Inline
---@field id integer
---@field aug number The ID for the autocmd group
---@field adapter CodeCompanion.Adapter
---@field chat_context? table Messages from a chat buffer
---@field classification table
---@field context table
---@field current_request? table
---@field diff? table
---@field opts table
---@field prompts table
local Inline = {}

---@class CodeCompanion.InlineArgs
---@field adapter? CodeCompanion.Adapter
---@field chat_context? table Messages from a chat buffer
---@field context table The context of the buffer the inline prompt was initiated from
---@field diff? table The diff provider
---@field lines? table The lines in the buffer before the inline changes
---@field opts? table
---@field pre_hook? fun():number Function to run before the inline prompt is started
---@field prompts table

---@param args CodeCompanion.InlineArgs
---@return CodeCompanion.Inline|nil
function Inline.new(args)
  log:trace("Initiating Inline with args: %s", args)

  if args.opts and type(args.opts.pre_hook) == "function" then
    local bufnr = args.opts.pre_hook()

    if type(bufnr) == "number" then
      args.context.bufnr = bufnr
      args.context.start_line = 1
      args.context.start_col = 1
    end
  end

  if not args.chat_context then
    local last_chat = require("codecompanion").last_chat()
    if last_chat then
      args.chat_context = last_chat:get_messages()
    end
  end

  local id = math.random(10000000)

  local self = setmetatable({
    id = id,
    aug = api.nvim_create_augroup(CONSTANTS.AUTOCMD_GROUP .. ":" .. id, {
      clear = false,
    }),
    adapter = args.adapter or config.adapters[config.strategies.inline.adapter],
    chat_context = args.chat_context or {},
    classification = {
      placement = "",
      pos = {},
      prompts = {},
    },
    context = args.context,
    diff = args.diff or {},
    lines = {},
    opts = args.opts or {},
    prompts = vim.deepcopy(args.prompts),
  }, { __index = Inline })

  self.adapter = adapters.resolve(self.adapter)
  if not self.adapter then
    return log:error("No adapter found")
  end

  -- Check if the user has manually overridden the adapter
  if vim.g.codecompanion_adapter and self.adapter.name ~= vim.g.codecompanion_adapter then
    self.adapter = adapters.resolve(config.adapters[vim.g.codecompanion_adapter])
  end

  log:debug("Inline instance created with ID %d", self.id)
  return self
end

---Start the classification of the user's prompt
---@param opts? table
function Inline:start(opts)
  log:trace("Starting Inline with opts: %s", opts)

  if opts and opts[1] then
    self.opts = opts[1]
  end
  if opts and opts.args then
    return self:classify(opts.args)
  end

  if self.opts and self.opts.user_prompt then
    if type(self.opts.user_prompt) == "string" then
      return self:classify(self.opts.user_prompt)
    end

    local title
    if self.context.buftype == "terminal" then
      title = "Terminal"
    else
      title = string.gsub(self.context.filetype, "^%l", string.upper)
    end

    vim.ui.input({ prompt = title .. " " .. config.display.action_palette.prompt }, function(input)
      if not input then
        return
      end

      log:info("User input received: %s", input)
      return self:classify(input)
    end)
  else
    return self:classify()
  end
end

---Stop the current request
---@return nil
function Inline:stop()
  if self.current_request then
    self.current_request:shutdown()
    self.current_request = nil
  end
end

---Initially, we ask the LLM to classify the prompt, with the outcome being
---a judgement on the placement of the response.
---@param user_input? string
function Inline:classify(user_input)
  self.classification.prompts = self:form_prompt()

  if user_input then
    table.insert(self.classification.prompts, {
      role = config.constants.USER_ROLE,
      content = "<question>" .. user_input .. "</question>",
      opts = {
        tag = "user_prompt",
        visible = true,
      },
    })
  end

  local prompt = msg_utils.merge_messages(msg_utils.pluck_messages(vim.deepcopy(self.classification.prompts), "user"))
  log:debug("Prompt to classify: %s", prompt)

  if not self.opts.placement then
    log:info("Inline classification request started")
    util.fire("InlineStarted")

    ---Callback function to be called during the stream
    ---@param err string
    ---@param data table
    local cb = function(err, data)
      if err then
        return log:error("Error during inline classification: %s", err)
      end

      if data then
        self.classification.placement = self.classification.placement
          .. (self.adapter.handlers.inline_output(self.adapter, data) or "")
      end
    end

    ---Callback function to be called when the stream is done
    local done = function()
      log:info('Placement: "%s"', self.classification.placement)

      local ok, parts = pcall(function()
        return self.classification.placement:match("<(.-)>")
      end)
      if not ok or parts == "error" then
        return log:error("Could not determine where to place the output from the prompt")
      end

      self.classification.placement = parts
      if self.classification.placement == "chat" then
        log:info("Sending inline prompt to the chat buffer")
        return self:send_to_chat()
      end

      return self:submit()
    end

    client.new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineClassify" } }):request(
      self.adapter:map_roles({
        {
          role = config.constants.SYSTEM_ROLE,
          content = CONSTANTS.PLACEMENT_PROMPT,
        },
        {
          role = config.constants.USER_ROLE,
          content = 'The prompt to assess is: "' .. prompt[1].content .. '"',
        },
      }),
      { callback = cb, done = done },
      { bufnr = self.context.bufnr }
    )
  else
    self.classification.placement = self.opts.placement
    return self:submit()
  end
end

---Submit the prompts to the LLM to process
---@return nil
function Inline:submit()
  self:place(self.classification.placement)
  log:debug("Determined position for output: %s", self.classification.pos)

  local bufnr = self.classification.pos.bufnr

  -- Remind the LLM to respond with code only
  table.insert(self.classification.prompts, {
    role = config.constants.SYSTEM_ROLE,
    content = CONSTANTS.CODE_ONLY_PROMPT,
    opts = {
      tag = "system_tag",
      visible = false,
    },
  })

  -- Add the context from the chat buffer
  if not vim.tbl_isempty(self.chat_context) then
    local messages = msg_utils.pluck_messages(self.chat_context, config.constants.LLM_ROLE)

    if #messages > 0 then
      table.insert(self.classification.prompts, {
        role = config.constants.USER_ROLE,
        content = "Here is the chat history from a conversation we had earlier. To answer my question, you _may_ need to use it:\n\n"
          .. messages[#messages].content,
        opts = {
          tag = "chat_context",
          visible = false,
        },
      })
    end
  end

  -- log:debug("Prompts to submit: %s", self.classification.prompts)
  log:info("Inline request started")

  -- Add a keymap to cancel the request
  api.nvim_buf_set_keymap(bufnr, "n", "q", "", {
    desc = "Stop the request",
    callback = function()
      log:trace("Cancelling the inline request")
      if self.current_request then
        self:stop()
      end
    end,
  })

  if vim.tbl_contains({ "replace", "add", "before" }, self.classification.placement) then
    self:start_diff()
    keymaps
      .new({
        bufnr = bufnr,
        callbacks = require("codecompanion.strategies.inline.keymaps"),
        data = self,
        keymaps = config.strategies.inline.keymaps,
      })
      :set()
  end

  ---Callback function to be called during the stream
  ---@param err string
  ---@param data table
  local cb = function(err, data)
    if err then
      return log:error("Error during stream: %s", err)
    end

    if data then
      local content = self.adapter.handlers.inline_output(self.adapter, data, self.context)

      if content then
        vim.schedule(function()
          vim.cmd.undojoin()
          self:add_buf_message(content)
          if self.classification.placement == "new" and api.nvim_get_current_buf() == bufnr then
            ui.buf_scroll_to_end(bufnr)
          end
        end)
      end
    end
  end

  ---Callback function to be called when the stream is done
  local done = function()
    log:info("Inline request finished")

    self.current_request = nil
    api.nvim_buf_del_keymap(self.classification.pos.bufnr, "n", "q")
    api.nvim_clear_autocmds({ group = self.aug })

    vim.schedule(function()
      util.fire("InlineFinished", { placement = self.classification.placement })
    end)
  end

  self.current_request = client
    .new({ adapter = self.adapter:map_schema_to_params(), user_args = { event = "InlineSubmit" } })
    :request(self.adapter:map_roles(self.classification.prompts), { callback = cb, done = done }, { bufnr = bufnr })
end

---When a defined prompt is sent alongside the user's input, we need to do some
---additional processing such as evaluating conditions and determining if
---the prompt contains code which can be sent to the LLM.
---@return table
function Inline:form_prompt()
  local output = {}

  for _, prompt in ipairs(self.prompts) do
    if prompt.opts and prompt.opts.contains_code and not config.can_send_code() then
      goto continue
    end
    if prompt.condition and not prompt.condition(self.context) then
      goto continue
    end

    if type(prompt.content) == "function" then
      prompt.content = prompt.content(self.context)
    end

    table.insert(output, {
      role = prompt.role,
      content = prompt.content,
      opts = prompt.opts or {},
    })

    ::continue::
  end

  -- Add any visual selection to the prompt
  if config.can_send_code() then
    if self.context.is_visual and not self.opts.stop_context_insertion then
      log:trace("Sending visual selection")
      table.insert(output, {
        role = config.constants.USER_ROLE,
        content = code_block(
          "For context, this is the code that I've selected in the buffer",
          self.context.filetype,
          self.context.lines
        ),
        opts = {
          tag = "visual",
          visible = true,
        },
      })
    end
  end

  return output
end

---With the placement determined, we can now place the output from the inline prompt
---@param placement string
---@return CodeCompanion.Inline
function Inline:place(placement)
  local pos = { line = self.context.start_line, col = 0, bufnr = 0 }

  if placement == "replace" then
    self.lines = api.nvim_buf_get_lines(self.context.bufnr, 0, -1, true)
    overwrite_selection(self.context)
    local cursor_pos = api.nvim_win_get_cursor(self.context.winnr)
    pos.line = cursor_pos[1]
    pos.col = cursor_pos[2]
    pos.bufnr = self.context.bufnr
  elseif placement == "add" then
    self.lines = api.nvim_buf_get_lines(self.context.bufnr, 0, -1, true)
    api.nvim_buf_set_lines(self.context.bufnr, self.context.end_line, self.context.end_line, false, { "" })
    pos.line = self.context.end_line + 1
    pos.col = 0
    pos.bufnr = self.context.bufnr
  elseif placement == "before" then
    self.lines = api.nvim_buf_get_lines(self.context.bufnr, 0, -1, true)
    api.nvim_buf_set_lines(self.context.bufnr, self.context.start_line - 1, self.context.start_line - 1, false, { "" })
    self.context.start_line = self.context.start_line + 1
    pos.line = self.context.start_line - 1
    pos.col = math.max(0, self.context.start_col - 1)
  elseif placement == "new" then
    local bufnr = api.nvim_create_buf(true, false)
    util.set_option(bufnr, "filetype", self.context.filetype)

    -- TODO: This is duplicated from the chat strategy
    if config.display.inline.layout == "vertical" then
      local cmd = "vsplit"
      local window_width = config.display.chat.window.width
      local width = window_width > 1 and window_width or math.floor(vim.o.columns * window_width)
      if width ~= 0 then
        cmd = width .. cmd
      end
      vim.cmd(cmd)
    elseif config.display.inline.layout == "horizontal" then
      local cmd = "split"
      local window_height = config.display.chat.window.height
      local height = window_height > 1 and window_height or math.floor(vim.o.lines * window_height)
      if height ~= 0 then
        cmd = height .. cmd
      end
      vim.cmd(cmd)
    end

    api.nvim_win_set_buf(api.nvim_get_current_win(), bufnr)
    pos.line = 1
    pos.col = 0
    pos.bufnr = bufnr
  end

  self.classification.pos = {
    line = pos.line,
    col = pos.col,
    bufnr = pos.bufnr,
  }

  return self
end

---A user's inline prompt may need to be converted into a chat
---@return CodeCompanion.Chat
function Inline:send_to_chat()
  local prompt = self.classification.prompts

  for i = #prompt, 1, -1 do
    -- Remove all of the system prompts
    if prompt[i].opts and prompt[i].opts.tag == "system_tag" then
      table.remove(prompt, i)
    end
    -- Remove any visual selections as the chat buffer adds these from the context
    if self.context.is_visual and (prompt[i].opts and prompt[i].opts.tag == "visual") then
      table.remove(prompt, i)
    end
  end

  api.nvim_clear_autocmds({ group = self.aug })

  return require("codecompanion.strategies.chat").new({
    context = self.context,
    adapter = self.adapter,
    messages = prompt,
    auto_submit = true,
  })
end

---Write the given text to the buffer
---@param content string
---@return nil
function Inline:add_buf_message(content)
  local line = self.classification.pos.line - 1
  local col = self.classification.pos.col
  local bufnr = self.classification.pos.bufnr

  local index = 1
  while index <= #content do
    local newline = content:find("\n", index) or (#content + 1)
    local substring = content:sub(index, newline - 1)

    if #substring > 0 then
      api.nvim_buf_set_text(bufnr, line, col, line, col, { substring })
      col = col + #substring
    end

    if newline <= #content then
      api.nvim_buf_set_lines(bufnr, line + 1, line + 1, false, { "" })
      line = line + 1
      col = 0
    end

    index = newline + 1
  end

  self.classification.pos.line = line + 1
  self.classification.pos.col = col
end

---Start the diff process
---@return nil
function Inline:start_diff()
  if config.display.diff.enabled == false then
    return
  end

  local provider = config.display.diff.provider
  local ok, diff = pcall(require, "codecompanion.providers.diff." .. provider)
  if not ok then
    return log:error("Diff provider not found: %s", provider)
  end

  ---@type CodeCompanion.Diff
  self.diff = diff.new({
    bufnr = self.context.bufnr,
    cursor_pos = self.context.cursor_pos,
    filetype = self.context.filetype,
    contents = self.lines,
    winnr = self.context.winnr,
  })
end

return Inline
