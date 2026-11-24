local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.check_for_updates = false
config.use_ime = true
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.font = wezterm.font_with_fallback { 'Cascadia Mono', 'Consolas', 'Microsoft YaHei UI' }
config.font_size = 14
config.line_height = 1.12
config.freetype_load_target = 'Light'
config.freetype_render_target = 'HorizontalLcd'
config.text_min_contrast_ratio = 4.5
config.colors = {
  background = '#1E1E1E',
  foreground = '#D4D4D4',
  cursor_bg = '#BDBDBD',
  cursor_fg = '#1E1E1E',
  selection_bg = '#3A4655',
  selection_fg = '#E0E0E0',
}
config.initial_cols = 112
config.initial_rows = 30
config.default_prog = { 'powershell.exe', '-NoProfile' }
config.window_close_confirmation = 'AlwaysPrompt'
config.keys = {
  { key = 'Tab', mods = 'CTRL', action = wezterm.action.ActivateTabRelative(1) },
  { key = 'Tab', mods = 'CTRL|SHIFT', action = wezterm.action.ActivateTabRelative(-1) },
}

wezterm.on('gui-startup', function()
  local plan_path = assert(os.getenv('RESUME_WEZTERM_PLAN'), 'Missing launcher plan')
  local file = assert(io.open(plan_path, 'r'))
  local plan = wezterm.json_parse(file:read('*a'))
  file:close()
  local report = { ok = false, groups = {} }
  local ok, err = xpcall(function()
    assert(plan.schema == 1, 'Unsupported launcher plan')
    -- Windows shares the default IME context within a GUI thread. The launcher
    -- must give each window its own process, even when several groups open.
    assert(#plan.groups == 1, 'Each process must own exactly one window group')
    for _, group in ipairs(plan.groups) do
      assert(#group.tabs > 0, 'Empty tab group')
      local first = group.tabs[1]
      local tab, _, window = wezterm.mux.spawn_window {
        args = first.args,
        cwd = first.cwd,
      }
      tab:set_title(first.title)
      for index = 2, #group.tabs do
        local item = group.tabs[index]
        local next_tab = window:spawn_tab { args = item.args, cwd = item.cwd }
        next_tab:set_title(item.title)
      end
      tab:activate()
      window:set_title((plan.provider or 'Codex') .. ' - ' .. group.name)
      table.insert(report.groups, {
        name = group.name,
        window_id = window:window_id(),
        tab_count = #window:tabs(),
      })
    end
  end, function(err) return tostring(err) end)
  report.ok = ok
  if not ok then report.error = tostring(err) end
  local temporary_report = plan.report .. '.tmp'
  local output = assert(io.open(temporary_report, 'w'))
  output:write(wezterm.json_encode(report))
  output:close()
  assert(os.rename(temporary_report, plan.report))
  if not ok then error(err) end
end)

return config
