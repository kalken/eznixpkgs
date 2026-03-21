pcall(vim.cmd.colorscheme, vim.g.ezconf_theme or "default")

local normal_hl = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
local bg = normal_hl.bg and string.format("#%06x", normal_hl.bg) or "NONE"
local fg = normal_hl.fg and string.format("#%06x", normal_hl.fg) or "NONE"

vim.api.nvim_set_hl(0, 'FloatBorder', { fg = fg, bg = bg })
vim.api.nvim_set_hl(0, 'NormalFloat',  { link = 'Normal' })

local api = vim.api
local cmp = require('cmp')
local luasnip = require('luasnip')

vim.opt.guicursor = ''
vim.opt.showcmd = false
vim.opt.ruler = false
vim.opt.updatetime = 200

-- ─── Heading Sidebar ─────────────────────────────────────────────────────────

local sidebar = (function()
  local sidebar_buf, sidebar_win, main_buf, main_win

  local function collect_headings(buf)
    if not buf or not api.nvim_buf_is_loaded(buf) then return {} end
    local headings = {}
    for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local level, title = line:match("^%s*(%#+)!%s+(.-)%s*$")
      if level and title ~= "" then
        table.insert(headings, { level = #level, title = title, line = i })
      end
    end
    return headings
  end

  local function render()
    if not sidebar_buf or not api.nvim_buf_is_valid(sidebar_buf) then return end
    local headings = collect_headings(main_buf)
    local lines = {}
    for _, h in ipairs(headings) do
      table.insert(lines, string.rep("  ", h.level - 1) .. h.title)
    end
    api.nvim_buf_set_option(sidebar_buf, "modifiable", true)
    api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
    api.nvim_buf_set_option(sidebar_buf, "modifiable", false)
    for i, h in ipairs(headings) do
      local hl = h.level == 1 and "Comment" or "Normal"
      api.nvim_buf_add_highlight(sidebar_buf, -1, hl, i - 1, 0, -1)
    end
  end

  local function close()
    if sidebar_win and api.nvim_win_is_valid(sidebar_win) then api.nvim_win_close(sidebar_win, true) end
    if sidebar_buf and api.nvim_buf_is_valid(sidebar_buf) then api.nvim_buf_delete(sidebar_buf, { force = true }) end
    sidebar_buf, sidebar_win, main_buf, main_win = nil, nil, nil, nil
  end

  local function open()
    if vim.fn.expand("%:e") ~= "nix" then print("Sidebar only works on .nix files") return end
    main_buf = api.nvim_get_current_buf()
    main_win = api.nvim_get_current_win()
    sidebar_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(sidebar_buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(sidebar_buf, "filetype", "markdown")
    api.nvim_buf_set_option(sidebar_buf, "modifiable", false)
    sidebar_win = api.nvim_open_win(sidebar_buf, false, {
      relative = "editor",
      width = 30,
      height = vim.o.lines - 2,
      row = 0,
      col = vim.o.columns - 31,
      style = "minimal",
    })
    api.nvim_win_set_option(sidebar_win, "number", false)
    api.nvim_win_set_option(sidebar_win, "relativenumber", false)
    api.nvim_win_set_option(sidebar_win, "signcolumn", "no")

    local normal_hl = api.nvim_get_hl(0, { name = "Normal" })
    local bg = normal_hl.bg and string.format("#%06x", normal_hl.bg) or "NONE"
    api.nvim_command("highlight SidebarNormal guibg=" .. bg .. " ctermbg=NONE")
    api.nvim_win_set_option(sidebar_win, "winhl", "Normal:SidebarNormal")

    render()
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWinEnter" }, {
      buffer = main_buf, callback = render,
    })
    api.nvim_buf_set_keymap(sidebar_buf, "n", "<CR>", "", {
      noremap = true, silent = true,
      callback = function()
        local line = api.nvim_win_get_cursor(sidebar_win)[1]
        local headings = collect_headings(main_buf)
        if headings[line] and main_win and api.nvim_win_is_valid(main_win) then
          api.nvim_set_current_win(main_win)
          api.nvim_win_set_cursor(main_win, { headings[line].line, 0 })
          api.nvim_win_call(main_win, function() vim.cmd("normal! zt") end)
          close()
        end
      end,
    })
    api.nvim_buf_set_keymap(sidebar_buf, "n", "<Esc>", "", {
      noremap = true, silent = true,
      callback = function()
        if main_win and api.nvim_win_is_valid(main_win) then api.nvim_set_current_win(main_win) end
      end,
    })
  end

  local function toggle()
    if sidebar_win and api.nvim_win_is_valid(sidebar_win) then close() else open() end
  end

  api.nvim_create_user_command("HeadingSidebarToggle", toggle, {})

  return {
    open = open, close = close, toggle = toggle,
    get_windows = function() return sidebar_win, main_win end,
  }
end)()

-- ─── Button Panel ─────────────────────────────────────────────────────────────

local button_panel = (function()
  local button_buf, button_win, main_buf, main_win
  local current_index = 1
  local ns = api.nvim_create_namespace("button_panel")

  local function collect_buttons()
    if not main_buf or not api.nvim_buf_is_loaded(main_buf) then return {} end
    local buttons = {}
    for _, line in ipairs(api.nvim_buf_get_lines(main_buf, 0, -1, false)) do
      local name, cmd = line:match("^#!button%s+([^:]+):%s*(.+)$")
      if name and cmd then table.insert(buttons, { name = name, cmd = cmd }) end
    end
    return buttons
  end

  local function render()
    if not button_buf or not api.nvim_buf_is_valid(button_buf) then return end
    local buttons = collect_buttons()
    local line = ""
    for i, btn in ipairs(buttons) do
      line = line .. (i == current_index and string.format(" [%s] ", btn.name) or string.format("  %s  ", btn.name))
    end
    api.nvim_buf_set_option(button_buf, "modifiable", true)
    api.nvim_buf_set_lines(button_buf, 0, -1, false, { line })
    api.nvim_buf_set_option(button_buf, "modifiable", false)
    api.nvim_buf_clear_namespace(button_buf, ns, 0, -1)
    local col = 0
    for i, btn in ipairs(buttons) do
      local block = i == current_index and string.format(" [%s] ", btn.name) or string.format("  %s  ", btn.name)
      api.nvim_buf_add_highlight(button_buf, ns, i == current_index and "Comment" or "Normal", 0, col, col + #block)
      col = col + #block
    end
  end

  local function close()
    if button_win and api.nvim_win_is_valid(button_win) then api.nvim_win_close(button_win, true) end
    if button_buf and api.nvim_buf_is_valid(button_buf) then api.nvim_buf_delete(button_buf, { force = true }) end
    button_buf, button_win, main_buf, main_win = nil, nil, nil, nil
  end

  local function open()
    local sw, smw = sidebar.get_windows()
    main_win = (smw and api.nvim_win_is_valid(smw)) and smw or api.nvim_get_current_win()
    main_buf = api.nvim_win_get_buf(main_win)
    if api.nvim_buf_get_name(main_buf):match("^.+%.(.+)$") ~= "nix" then
      print("Button panel only works on .nix files") return
    end
    button_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(button_buf, "bufhidden", "wipe")
    api.nvim_buf_set_option(button_buf, "modifiable", false)
    api.nvim_buf_set_option(button_buf, "filetype", "markdown")
    button_win = api.nvim_open_win(button_buf, false, {
      relative = "editor",
      width = vim.o.columns,
      height = 1,
      row = vim.o.lines - 3,
      col = 0,
      style = "minimal",
      border = "none",
    })
    api.nvim_win_set_option(button_win, "wrap", false)

    local normal_hl = api.nvim_get_hl(0, { name = "Normal" })
    local bg = normal_hl.bg and string.format("#%06x", normal_hl.bg) or "NONE"
    api.nvim_command("highlight ButtonPanelNormal guibg=" .. bg .. " ctermbg=NONE")
    api.nvim_win_set_option(button_win, "winhl", "Normal:ButtonPanelNormal")

    render()
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
      buffer = main_buf, callback = render,
    })
    api.nvim_buf_set_keymap(button_buf, "n", "<CR>", "", {
      noremap = true, silent = true,
      callback = function()
        local btn = collect_buttons()[current_index]
        if not btn then print("No button selected") return end
        local output_buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_option(output_buf, "buftype", "nofile")
        api.nvim_buf_set_option(output_buf, "bufhidden", "wipe")
        api.nvim_buf_set_option(output_buf, "modifiable", true)
        api.nvim_buf_set_lines(output_buf, 0, -1, false, { "$ " .. btn.cmd })
        vim.cmd("split")
        local output_win = api.nvim_get_current_win()
        api.nvim_win_set_buf(output_win, output_buf)
        local line_count = 1
        local done = false
        api.nvim_buf_set_keymap(output_buf, "n", "<CR>", "", {
          noremap = true, silent = true,
          callback = function()
            if done then
              if api.nvim_win_is_valid(output_win) then api.nvim_win_close(output_win, true) end
              if button_win and api.nvim_win_is_valid(button_win) then api.nvim_set_current_win(button_win) end
            end
          end,
        })
        local function append(data)
          if not data then return end
          vim.schedule(function()
            local lines = vim.split(data, "\n", { plain = true })
            if lines[#lines] == "" then table.remove(lines) end
            if #lines > 0 then
              api.nvim_buf_set_lines(output_buf, line_count, line_count, false, lines)
              line_count = line_count + #lines
              if api.nvim_win_is_valid(output_win) then
                api.nvim_win_set_cursor(output_win, { line_count, 0 })
              end
            end
          end)
        end
        vim.system({ 'sh', '-c', btn.cmd }, { stdout = function(_, d) append(d) end, stderr = function(_, d) append(d) end },
          function()
            vim.schedule(function()
              done = true
              api.nvim_buf_set_option(output_buf, "modifiable", false)
            end)
          end)
      end,
    })
    api.nvim_buf_set_keymap(button_buf, "n", "<Left>", "", {
      noremap = true, silent = true,
      callback = function()
        local btns = collect_buttons()
        if #btns > 0 then current_index = (current_index - 2) % #btns + 1; render() end
      end,
    })
    api.nvim_buf_set_keymap(button_buf, "n", "<Right>", "", {
      noremap = true, silent = true,
      callback = function()
        local btns = collect_buttons()
        if #btns > 0 then current_index = current_index % #btns + 1; render() end
      end,
    })
    api.nvim_buf_set_keymap(button_buf, "n", "<Esc>", "", {
      noremap = true, silent = true,
      callback = function()
        if main_win and api.nvim_win_is_valid(main_win) then api.nvim_set_current_win(main_win) end
      end,
    })
  end

  local function toggle()
    if button_win and api.nvim_win_is_valid(button_win) then close() else open() end
  end

  api.nvim_create_user_command("ButtonPanelToggle", toggle, {})

  return {
    open = open, close = close, toggle = toggle,
    get_windows = function() return button_win, main_win end,
  }
end)()

-- ─── Window Focus Cycle (Tab) ─────────────────────────────────────────────────

local function has_headings()
  for _, line in ipairs(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)) do
    local level, title = line:match("^%s*(%#+)!%s+(.-)%s*$")
    if level and title ~= "" then return true end
  end
  return false
end

local function has_buttons()
  for _, line in ipairs(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)) do
    if line:match("^#!button%s+([^:]+):%s*(.+)$") then return true end
  end
  return false
end

api.nvim_set_keymap("n", "<Tab>", "", {
  noremap = true, silent = true,
  callback = function()
    local sidebar_win, sidebar_main_win = sidebar.get_windows()
    local button_win, button_main_win = button_panel.get_windows()
    local main_win = sidebar_main_win or button_main_win or api.nvim_get_current_win()
    local current_win = api.nvim_get_current_win()
    local sidebar_open = sidebar_win and api.nvim_win_is_valid(sidebar_win)
    local button_open = button_win and api.nvim_win_is_valid(button_win)

    if current_win == main_win then
      if not sidebar_open and not button_open then
        if has_headings() then
          sidebar.open()
          vim.schedule(function()
            local w = sidebar.get_windows()
            if w and api.nvim_win_is_valid(w) then api.nvim_set_current_win(w) end
          end)
        elseif has_buttons() then
          button_panel.open()
          vim.schedule(function()
            local w = button_panel.get_windows()
            if w and api.nvim_win_is_valid(w) then api.nvim_set_current_win(w) end
          end)
        end
      elseif sidebar_open then
        api.nvim_set_current_win(sidebar_win)
      elseif button_open then
        api.nvim_set_current_win(button_win)
      end
    elseif current_win == sidebar_win then
      sidebar.close()
      if has_buttons() then
        button_panel.open()
        vim.schedule(function()
          local w = button_panel.get_windows()
          if w and api.nvim_win_is_valid(w) then api.nvim_set_current_win(w) end
        end)
      else
        if main_win and api.nvim_win_is_valid(main_win) then api.nvim_set_current_win(main_win) end
      end
    elseif current_win == button_win then
      button_panel.close()
      if main_win and api.nvim_win_is_valid(main_win) then api.nvim_set_current_win(main_win) end
    end
  end,
})

-- ─── Autocompletion ───────────────────────────────────────────────────────────

cmp.setup({
  enabled = function()
    local context = require('cmp.config.context')
    return not context.in_syntax_group('Comment')
  end,
  snippet = {
    expand = function(args)
      luasnip.lsp_expand(args.body)
    end,
  },
  window = {
    completion = cmp.config.window.bordered({ border = 'single' }),
    documentation = cmp.config.window.bordered({ border = 'single' }),
  },
  mapping = cmp.mapping.preset.insert({
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>']     = cmp.mapping.abort(),
    ['<CR>'] = cmp.mapping(function(fallback)
      if cmp.visible() and cmp.get_selected_entry() then
        cmp.confirm({ select = false })
      else
        fallback()
      end
    end),
    ['<Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()
      else
        fallback()
      end
    end, { 'i', 's' }),
    ['<S-Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      elseif luasnip.jumpable(-1) then
        luasnip.jump(-1)
      else
        fallback()
      end
    end, { 'i', 's' }),
  }),
  sources = cmp.config.sources({
    { name = 'nvim_lsp' },
    { name = 'luasnip' },
    { name = 'buffer' },
    { name = 'path' },
  }),
})

-- ─── LSP (nixd) ───────────────────────────────────────────────────────────────

local capabilities = require('cmp_nvim_lsp').default_capabilities()
local hostname = vim.fn.hostname()

vim.lsp.config('nixd', {
  capabilities = capabilities,
  cmd = { 'nixd' },
  filetypes = { 'nix' },
  settings = {
    nixd = {
      nixpkgs = {
        expr = string.format(
          '(builtins.getFlake "/etc/nixos").nixosConfigurations.%s.pkgs',
          hostname
        ),
      },
      formatting = {
        command = { "alejandra" },
      },
      options = {
        nixos = {
          expr = string.format(
            '(builtins.getFlake "/etc/nixos").nixosConfigurations.%s.options',
            hostname
          ),
        },
      },
    },
  },
})

vim.lsp.enable('nixd')

vim.keymap.set('n', 'K', function()
  vim.lsp.buf.hover({ border = 'single' })
end)

vim.api.nvim_create_autocmd('BufWritePre', {
  pattern = '*.nix',
  callback = function()
    vim.lsp.buf.format({ async = false })
  end,
})

-- ─── Re-request LSP completions after pause in typing ────────────────────────

vim.api.nvim_create_autocmd('CursorHoldI', {
  pattern = '*.nix',
  callback = function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before_cursor = line:sub(1, col)
    if before_cursor:match('[%.%w]$') then
      cmp.complete({ reason = cmp.ContextReason.Manual })
    end
  end,
})
