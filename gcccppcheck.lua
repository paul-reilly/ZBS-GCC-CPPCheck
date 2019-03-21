--
--    GCC-CPPCheck - a package/plugin for Zerobrane Studio
--
--        When editing C or C++ files your code is run through GCC and CPPCheck when you save
--        it, and any issues found are annotated to the releveant lines in your editor window.
--
--
--    Copyright 2019+ Paul Reilly (GitHub user paul-reilly), MIT license
--


local file_types =
{
  gcc = {
    c = "gcc",
    cpp = "g++",
    h = "gcc",
    hpp = "g++",
  }
}

local c_family = {
  c = true,
  cpp = true,
  h = true,
  hpp = true
}

-- we clear annotations when we start typing, but we want to be able to navigate
-- so don't clear when only these keys are used
local ignored_keys = {
  ["27"] = "escape",
  ["306"] = "shift",
  ["307"] = "alt",
  ["308"] = "ctrl",
  ["308"] = "mousewheel",
  ["314"] = "left arrow",
  ["315"] = "up arrow",
  ["316"] = "right arrow",
  ["317"] = "right arrow",
  ["366"] = "page up",
  ["367"] = "page down",
  ["393"] = "windows",
  ["395"] = "menu"
}

-- our marker IDs, used to set and delete
local kMARKER_TYPE_WARNING = 10
local kMARKER_TYPE_ERROR = 11

-- existing style numbers to repurpose
local kSTYLE_WARNING = 9
local kSTYLE_ERROR = 7

--
local function stringLinesIterator(s)
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  return s:gmatch("(.-)\n")
end

--
local function getArrayOfIssuesFromTextOutput(parse_patterns, file_path, output)
  local issues = {}
  local file_name = wx.wxFileName(file_path):GetFullName()
  if type(parse_patterns) == "string" then
    parse_patterns = { parse_patterns }
  end

  -- CPPCheck can return errors that span several, sepaate lines - for example tracing an uninitialized pointer that
  -- gets deferenced. Give these errors an ID number to group them in case more than one of these errors exists, so
  -- that it's obvious what error relates to which incidence.
  local group_id = 1

  for current_line in stringLinesIterator(output) do
    for _, parse_pattern in pairs(parse_patterns) do
      for fn, line, column, warning in current_line:gmatch("(" .. EscapeMagic(file_name) .. ")" .. parse_pattern) do
        if warning then
          local trace = ""
          -- CPPCheck's multiple line issues are reported on the same line of output text separated by ' -> '. So gather
          --- them up and give them their id and a label
          local count = 0
          for line_number in current_line:gmatch(":(%d-)%] %->") do
            count = count + 1
            trace = count == 1 and ("  [origin] (group ID: " .. group_id .. ")") or ("  [trace] (group ID: " .. group_id .. ")")
            issues[#issues + 1] = { file_name = fn, line_number = line_number, column = column, warning = warning .. trace }
          end

          trace = count > 0 and ("  [action] (group ID: " .. group_id .. ")") or ""
          issues[#issues + 1] = { file_name = fn, line_number = line, column = column, warning = warning .. trace }
          if count > 0 then group_id = group_id + 1 end
        end
      end
    end
  end
  return issues
end

--
local function getDocFromEditorAndCheckExt(config, editor)
  local document = ide:GetDocument(editor)
  local file_ext = document:GetFileExt()
  if not file_types[config.compiler][file_ext] then
    return false
  else
    return true, document
  end
end

--
local function clearAnnotationsAndMarkers(editor)
  editor:AnnotationClearAll()
  editor:MarkerDeleteAll(kMARKER_TYPE_WARNING)
  editor:MarkerDeleteAll(kMARKER_TYPE_ERROR)
end

--
local function parseIssuesAndAddAnnotationsAndMarkers(file_path, editor, issues)
local file_name = wx.wxFileName(file_path):GetFullName()
  for _, issue in ipairs(issues) do
    if issue.file_name == file_name then
      -- lines are off by one re wx editor and CPPCheck can give a file warning on line 0
      local line_number = tonumber(issue.line_number) > 0 and issue.line_number - 1 or 0
      local current_line_text = editor:AnnotationGetText(line_number)
      local delim = current_line_text == "" and "" or "\n"
      current_line_text = current_line_text .. delim .. issue.warning

      editor:AnnotationSetText(line_number, current_line_text)
      editor:AnnotationSetVisible(wxstc.wxSTC_ANNOTATION_BOXED)
      local is_error = editor:AnnotationGetText(line_number):match("[Ee]rror")
      if is_error then
        editor:AnnotationSetStyle(line_number, kSTYLE_ERROR)
        editor:MarkerAdd(line_number, kMARKER_TYPE_ERROR)
      else
        editor:AnnotationSetStyle(line_number, kSTYLE_WARNING)
        editor:MarkerAdd(line_number, kMARKER_TYPE_WARNING)
      end
    end
  end
end

--
local function runToolsOnCurrentFile(config, document, editor)
  local file_path = document:GetFilePath()
  local file_ext = document:GetFileExt()
  -- enclose in quotes for command line in case of spaces in path
  local file_path_enclosed = "\"" .. file_path .. "\""
  local contents = editor:GetText()
  local compiler = file_types[config.compiler][file_ext]
  local compiler_string = compiler .. " -c "
  local compiler_parse_pattern = config.compiler_parse_pattern
  if c_family[file_ext] then
    compiler_string = compiler_string .. " " .. config.compiler_options
      .. " " .. config.include_dirs .. " " .. config.libraries .. " "
  end
  compiler_string = compiler_string .. file_path_enclosed

  -- first entry in table we concat to display total output in final callback from
  -- Execute Command since it's async and we are running two tools we don't want
  -- to print live as we get results
  local compiler_total_output = { "\nExecuting GCC: \n", compiler_string }
  ide:Print(compiler_string)
  -- clearAnnotationsAndMarkers(editor)
  ide:ExecuteCommand(
    compiler_string,
    ide:GetProject()
    ,
    function(compiler_output)
      compiler_total_output[#compiler_total_output + 1] = compiler_output
      local issues = getArrayOfIssuesFromTextOutput(compiler_parse_pattern, file_path, compiler_output)
      parseIssuesAndAddAnnotationsAndMarkers(file_path, editor, issues)
    end
    ,
    function()
      table.insert(compiler_total_output, "\n")
      ide:Print(table.concat(compiler_total_output, "\n"))
    end
  )
  -- run cppcheck
  if file_ext == "c" or file_ext == "cpp" then
    local cppcheck_string = "cppcheck --inline-suppr --force --enable=warning --enable=information --enable=performance "
        ..  " " .. config.include_dirs .. file_path_enclosed
    local cppcheck_total_output = { "\nExecuting CPPCheck: \n", cppcheck_string }

    ide:ExecuteCommand(
      cppcheck_string
      ,
      ide:GetProject()
      ,
      function(cppcheck_output)
        cppcheck_total_output[#cppcheck_total_output + 1] = cppcheck_output
        local issues = getArrayOfIssuesFromTextOutput(config.cppcheck_parse_pattern, file_path, cppcheck_output)
        parseIssuesAndAddAnnotationsAndMarkers(file_path, editor, issues)
      end
      ,
      function()
        table.insert(cppcheck_total_output, "\n")
        ide:Print(table.concat(cppcheck_total_output, "\n"))
      end
    )
  end
end

--
local function setConfig(self)
  self.config = {}
  if self:GetConfig() then
    self.config = self:GetConfig()
  end
  if not self.config then ide:Print("GCC-CPPCheck Package: Config not found - using defaults") end
  self.config.compiler = self.config.compiler or "gcc"
  if self.config.include_dirs and #self.config.include_dirs > 0 then
    self.config.include_dirs = "-I " .. table.concat(self.config.include_dirs, " -I ") .. " "
  else
    self.config.include_dirs = " "
  end
  ide:Print("Include dirs: " .. self.config.include_dirs)
  if self.config.libraries and #self.config.libraries > 0 then
    self.config.libraries = "-L " .. table.concat(self.config.libraries, " -L ") .. " "
  else
    self.config.libraries = " "
  end
  ide:Print("Libraries: " .. self.config.libraries)

  self.config.compiler_options = self.config.compiler_options or "-Wall -Woverflow -Wextra -fpermissive -fmax-errors=100 "
  self.config.compiler_options = " -O " .. self.config.compiler_options
  -- patterns that returns line number, column (not used) and warning/error
  -- we can have more than one pattern per tool if we put them in a table
  self.config.compiler_parse_pattern = self.config.compiler_parse_pattern or ":(%d-):(%d-):(.-)[\n\r]"
  self.config.cppcheck_parse_pattern = self.config.cppcheck_parse_pattern or ":(%d-)%]():(.-)[\n\r]"
end

--
local package =  {
  name = "GCC-CPPCheck",
  description = "Annotates C and C++ files with compiler and static analyzer errors/warnings on save.",
  author = "Paul Reilly",
  version = 0.10,
  dependencies = "1.0",

  onRegister = function(self)
    -- reading config done in onProjectLoad to ensure that Project Settings package
    -- config option can be used
  end
  ,
  onUnRegister = function(self)
    --
  end
  ,
  onEditorKeyDown = function(self, editor, event)
    local key =  tostring(event:GetKeyCode())
    if not ignored_keys[key] then
      clearAnnotationsAndMarkers(editor)
    end
  end
  ,
  onEditorSave = function(self, editor)
    editor:MarkerDefine(kMARKER_TYPE_WARNING, 1, wx.wxColour(0xcc, 0xcc, 0x00), wx.wxColour(0xcc, 0xcc, 0x00))
    editor:MarkerDefine(kMARKER_TYPE_ERROR, 1, wx.wxColour(0xcc, 0x00, 0x00), wx.wxColour(0xcc, 0x00, 0x00))
    local ok, doc = getDocFromEditorAndCheckExt(self.config, editor)
    if ok then runToolsOnCurrentFile(self.config, doc, editor) end
  end
  ,
  onIdleOnce = function(self, event)
    --
  end
  ,
  onIdle = function(self, event)
    -- TODO: maybe do it liveish here?
  end
  ,
  onEditorFocusLost = function(self, editor)
    --
  end
  ,
  onEditorClose = function(self, editor)
    clearAnnotationsAndMarkers(editor)
  end
  ,
  onProjectLoad = function(self, _)
    setConfig(self)
  end
}

return package