-- llm.lua
local config = import("micro/config")
local shell = import("micro/shell")
local micro = import("micro")
local buffer_pkg = import("micro/buffer")
local go_math = import("math") -- Standard Lua math library
local util = import("micro/util")
local os = import("os")
local path = import("path/filepath")
local ioutil = import("io/ioutil")

-- Define the prefix for plugin options globally or consistently
local PLUGIN_OPT_PREFIX = "llm."

-- Default system prompts guiding the LLM's behavior.
-- These are used if no custom prompt, template, or default template is specified.
local system_prompts = {
    modify = "You are a text editing assistant for modifying text in the micro text editor cli. The user will provide text they have selected, a specific request for how to modify that selected text, and surrounding context from the document. Modify ONLY the 'SELECTED TEXT TO MODIFY' based on the user's request and the context. IMPORTANT: Output _only_ the raw, modified code or text. Do not wrap your output in Markdown code blocks (for example, using triple-backtick fences before and after the code, optionally with a language specifier like 'python'). Do not include any explanatory text before or after the modified code/text unless explicitly asked to.",
    generate = "You are a text generation assistant for the micro CLI text editor. Based on the USER_REQUEST, and only if the USER_REQUEST explicitly refers to the EDITOR_CONTEXT, use that context. Otherwise, generate new text based ONLY on the USER_REQUEST, ignoring any editor context. IMPORTANT: Output _only_ the raw, generated text or code. Do NOT include any explanatory text before or after the generated text, unless the request specifically asks for explanation. If the USER_REQUEST is about the EDITOR_CONTEXT (e.g. 'summarize this', 'add comments for this code'), your output must be a NEW, SEPARATE block of text (e.g. just the summary, just the comments) and NOT the original context modified."
}

-- Global state for the currently active LLM job.
local job_state = {
    stdout_data = {},
    stderr_data = {},
    exit_code = nil,
    bp = nil, -- BufPane where the command was initiated
    command_type = nil, -- "generate" or "modify"
    insertion_loc_ptr = nil, -- Where to insert generated/modified text
    selection_to_remove_start_loc_ptr = nil, -- For 'modify', start of text to replace
    selection_to_remove_end_loc_ptr = nil,   -- For 'modify', end of text to replace
    temp_file_path = nil, -- Path to the temporary file holding the full prompt
    original_command = "" -- The full llm CLI command executed
}

-- Function: parseLLMCommandArgs
-- Description: Parses arguments for llm_generate/llm_modify commands.
--   Separates the user's main textual request from -s (custom system prompt)
--   and -t (template name) flags.
-- Parameters:
--   - args_table: table, array of string arguments from Micro's command line.
-- Returns: A table with fields:
--   - user_request: string, the core prompt text from the user.
--   - custom_system_prompt: string or nil, the system prompt text if -s was used.
--   - template_name: string or nil, the template name if -t was used.
local function parseLLMCommandArgs(args_table)
    local user_request_parts = {}
    local custom_system_prompt = nil
    local template_name = nil
    if args_table then
        local i = 1
        while i <= #args_table do
            if (args_table[i] == "-s" or args_table[i] == "--system") and args_table[i+1] then -- FIXED
                custom_system_prompt = args_table[i+1]
                i = i + 2
            elseif (args_table[i] == "-t" or args_table[i] == "--template") and args_table[i+1] then -- FIXED
                template_name = args_table[i+1]
                i = i + 2
            else
                if args_table[i] ~= nil then
                    table.insert(user_request_parts, tostring(args_table[i]))
                end
                i = i + 1
            end
        end
    end
    return {
        user_request = table.concat(user_request_parts, " "),
        custom_system_prompt = custom_system_prompt,
        template_name = template_name
    }
end

-- Function: getLLMTemplatesPath
-- Description: Retrieves the filesystem path to LLM CLI's templates directory.
-- Returns: string path to templates directory, or nil if an error occurs.
local function getLLMTemplatesPath()
    local cmd_str = "llm templates path"
    local output, err_obj = shell.RunCommand(cmd_str)
    if err_obj ~= nil then
        micro.Log("LLM_ERROR: Could not get LLM templates path. Command: " .. cmd_str ..
                  " Error: " .. tostring(err_obj))
        return nil
    end
    if output then
        local processed_path = string.gsub(output, "[\n\r]+%s*$", "")
        processed_path = string.gsub(processed_path, "^%s*", "")
        if #processed_path > 0 then
             micro.Log("LLM_DEBUG: LLM templates path received: [" .. processed_path .. "]")
             return processed_path
        end
    end
    micro.Log("LLM_WARNING: 'llm templates path' returned no valid output. Raw: [" .. (output or "nil") .. "]")
    return nil
end

-- Function: getLLMTemplateContent
-- Description: Reads an LLM template's system prompt content from its YAML file IF IT EXISTS.
-- Parameters:
--   - name: string, the name of the LLM template.
-- Returns: string containing the system prompt if template exists and prompt is found.
--          Returns "" (empty string) if template file exists but 'system:' key is not found or empty.
--          Returns nil if template file does not exist or another read error occurs.
local function getLLMTemplateContent(name)
    local templates_dir_path = getLLMTemplatesPath()
    if not templates_dir_path then
        return nil
    end
    local template_file_name = name .. ".yaml"
    local specific_template_file_path = path.Join(templates_dir_path, template_file_name)
    micro.Log("LLM_DEBUG: getLLMTemplateContent: Checking for template file: " .. specific_template_file_path)
    local file_bytes, err_read = ioutil.ReadFile(specific_template_file_path)
    if err_read ~= nil then
        micro.Log("LLM_INFO: getLLMTemplateContent: Could not read template file '" .. specific_template_file_path .. "' (may not exist or unreadable). Error: " .. tostring(err_read))
        return nil
    end
    local file_content_string = util.String(file_bytes)
    micro.Log("LLM_DEBUG: getLLMTemplateContent: Successfully read existing template '" .. specific_template_file_path .. "'.")
    local final_system_prompt = nil
    local block_indicator_full_line_match, block_char_match = string.match(file_content_string, "^(system:%s*([|>]).*)\n")
    if block_indicator_full_line_match then
        local _, system_line_end_pos = string.find(file_content_string, block_indicator_full_line_match, 1, true)
        if system_line_end_pos then
            local rest_of_file_content = string.sub(file_content_string, system_line_end_pos + 1)
            local block_lines_array = {}
            local determined_initial_indent_len = -1
            for current_line_str in string.gmatch(rest_of_file_content, "([^\n]*)\n?") do
                local indent_str, text_content_part = string.match(current_line_str, "^(%s*)(.*)$")
                if determined_initial_indent_len == -1 then
                    determined_initial_indent_len = #indent_str
                    table.insert(block_lines_array, text_content_part)
                else
                    if #indent_str >= determined_initial_indent_len then
                        table.insert(block_lines_array, string.sub(current_line_str, determined_initial_indent_len + 1))
                    elseif #text_content_part > 0 then break
                    else break
                    end
                end
            end
            local assembled_block_content
            if block_char_match == ">" then
                local temp_folded_content = ""
                local prev_line_was_empty_in_block = true
                for _, line_text_in_block in ipairs(block_lines_array) do
                    local current_line_is_empty = (#string.gsub(line_text_in_block, "%s", "") == 0)
                    local trimmed_line_text = string.gsub(line_text_in_block, "^%s+", "")
                    if current_line_is_empty then
                        if not prev_line_was_empty_in_block then temp_folded_content = temp_folded_content .. "\n" end
                        prev_line_was_empty_in_block = true
                    else
                        if not prev_line_was_empty_in_block then temp_folded_content = temp_folded_content .. " " end
                        temp_folded_content = temp_folded_content .. trimmed_line_text
                        prev_line_was_empty_in_block = false
                    end
                end
                assembled_block_content = temp_folded_content
            else assembled_block_content = table.concat(block_lines_array, "\n") end
            final_system_prompt = string.gsub(assembled_block_content, "\n?$", "")
        end
    end
    if final_system_prompt == nil then
        local single_line_match_text = string.match(file_content_string, "^system:%s*(.+)$")
        if single_line_match_text then
            local extracted_prompt = single_line_match_text
            extracted_prompt = string.gsub(extracted_prompt, "^%s*", "")
            extracted_prompt = string.gsub(extracted_prompt, "%s*$", "")
            if (string.sub(extracted_prompt, 1, 1) == "'" and string.sub(extracted_prompt, -1, -1) == "'") or
               (string.sub(extracted_prompt, 1, 1) == "\"" and string.sub(extracted_prompt, -1, -1) == "\"") then -- FIXED
                extracted_prompt = string.sub(extracted_prompt, 2, -2)
            end
            final_system_prompt = extracted_prompt
        end
    end
    if final_system_prompt ~= nil then
        micro.Log("LLM_DEBUG: getLLMTemplateContent: Returning system prompt: [" .. final_system_prompt .. "]")
        return final_system_prompt
    else
        micro.Log("LLM_INFO: getLLMTemplateContent: 'system:' key not found in file: " .. specific_template_file_path .. ". Returning empty string as indicator.")
        return ""
    end
end

-- Function: escapeShellArg
-- Description: Escapes a string for safe inclusion as a double-quoted argument in a shell command.
-- Parameters:
--   - s: string, the string to escape.
-- Returns: string, the escaped and quoted string.
local function escapeShellArg(s)
    if not s then
        return ""
    end
    return "\"" .. string.gsub(s, "\"", "\\\"") .. "\""
end

function handleJobStdout(output, userargs)
    table.insert(job_state.stdout_data, output)
end

function handleJobStderr(output, userargs)
    table.insert(job_state.stderr_data, output)
end

function handleJobExit(exit_status_or_output, userargs)
    micro.Log("LLM_DEBUG: Job exited (" .. (job_state.command_type or "unknown") .. "). Exit code/status: [" .. tostring(exit_status_or_output) .. "]")
    job_state.exit_code = tostring(exit_status_or_output)
    if job_state.temp_file_path then
        local temp_path_to_remove = job_state.temp_file_path -- Store before nilling
        job_state.temp_file_path = nil
        pcall(os.Remove, temp_path_to_remove)
        micro.Log("LLM_DEBUG: Temp file removed: " .. temp_path_to_remove)
    end
    local final_stdout = table.concat(job_state.stdout_data, "")
    local final_stderr = table.concat(job_state.stderr_data, "")
    micro.Log("LLM_DEBUG: Final STDOUT (len " .. string.len(final_stdout) .. "): [" .. final_stdout .. "]")
    micro.Log("LLM_DEBUG: Final STDERR (len " .. string.len(final_stderr) .. "): [" .. final_stderr .. "]")
    if job_state.bp == nil or job_state.insertion_loc_ptr == nil then -- FIXED
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Critical state missing after job.")
        return
    end
    if job_state.command_type == "modify" and
       (job_state.selection_to_remove_start_loc_ptr == nil or job_state.selection_to_remove_end_loc_ptr == nil) then -- FIXED
        micro.InfoBar():Message("ERROR: LLM Modify: Selection locs missing after job.")
        return
    end
    local current_buffer = job_state.bp.Buf
    local active_cursor = job_state.bp.Cursor
    if not current_buffer or not active_cursor then
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Buffer/cursor nil after job.")
        return
    end
    if string.match(final_stderr, "cat:.*Permission denied") then
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Temp file permission error.")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") temp file perm fail: " .. final_stderr)
        return
    elseif final_stderr and (string.find(final_stderr, "command not found", 1, true) or string.find(final_stderr, "Error:", 1, true) or string.find(final_stderr, "Traceback", 1, true)) and not string.find(final_stderr, "ozone-platform-hint", 1, true) then
        micro.InfoBar():Message("ERROR: LLM "..job_state.command_type..": Critical failure (shell/LLM).")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") critical fail. Stderr: "..final_stderr)
        return
    end
    if final_stdout and string.gsub(final_stdout, "%s", "") ~= "" then
        if #final_stderr > 0 and not string.find(final_stderr, "ozone-platform-hint", 1, true) then
            micro.Log("LLM_DEBUG: Note: Non-critical STDERR for (" .. job_state.original_command .. "): " .. final_stderr)
        end
        local output = string.gsub(string.gsub(final_stdout, "^%s*", ""), "%s*$", "")
        micro.Log("LLM_DEBUG: Final text for insertion: [" .. output .. "]")
        if type(job_state.insertion_loc_ptr.X)~="number" or type(job_state.insertion_loc_ptr.Y)~="number" then
            micro.InfoBar():Message("ERROR: LLM Insert loc invalid after job.")
            return
        end
        local ins_loc = buffer_pkg.Loc(job_state.insertion_loc_ptr.X, job_state.insertion_loc_ptr.Y)
        if job_state.command_type == "modify" then
            if type(job_state.selection_to_remove_start_loc_ptr.X)~="number" or type(job_state.selection_to_remove_start_loc_ptr.Y)~="number" or
               type(job_state.selection_to_remove_end_loc_ptr.X)~="number" or type(job_state.selection_to_remove_end_loc_ptr.Y)~="number" then
                micro.InfoBar():Message("ERROR: LLM Modify remove locs invalid after job.")
                return
            end
            current_buffer:Remove(
                buffer_pkg.Loc(job_state.selection_to_remove_start_loc_ptr.X, job_state.selection_to_remove_start_loc_ptr.Y),
                buffer_pkg.Loc(job_state.selection_to_remove_end_loc_ptr.X, job_state.selection_to_remove_end_loc_ptr.Y)
            )
        end
        current_buffer:Insert(ins_loc, output)
        active_cursor:Relocate()
        micro.InfoBar():Message("LLM " .. job_state.command_type .. ": Text updated.")
    else
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": No valid output received.")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") produced no valid stdout. STDERR: ["..final_stderr.."]. Exit: ["..tostring(job_state.exit_code).."]")
    end
    micro.Log("LLM_DEBUG: --- LLM Job finished (" .. (job_state.command_type or "unknown") .. ") ---")
end

function startLLMJob(bp, args, command_type_str)
    job_state.stdout_data = {}
    job_state.stderr_data = {}
    job_state.exit_code = nil
    job_state.bp = bp
    job_state.command_type = command_type_str
    job_state.temp_file_path = nil
    job_state.original_command = ""
    job_state.insertion_loc_ptr = nil
    job_state.selection_to_remove_start_loc_ptr = nil
    job_state.selection_to_remove_end_loc_ptr = nil
    local parsed_args_data = parseLLMCommandArgs(args)
    local user_llm_request = parsed_args_data.user_request
    local custom_system_prompt_arg = parsed_args_data.custom_system_prompt
    local template_name_arg = parsed_args_data.template_name
    if user_llm_request == "" and not custom_system_prompt_arg and not template_name_arg then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": No request prompt provided.")
        return
    end
    micro.Log("LLM_DEBUG: User request (" .. command_type_str .. "): [" .. user_llm_request .. "]")
    if custom_system_prompt_arg then micro.Log("LLM_DEBUG: Using custom -s: [" .. custom_system_prompt_arg .. "]") end
    if template_name_arg then micro.Log("LLM_DEBUG: Using custom -t: [" .. template_name_arg .. "]") end
    if not bp then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": BufPane is nil!"); return end
    local current_buffer = bp.Buf
    local active_cursor = bp.Cursor
    if not current_buffer then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": Buffer is nil!"); return end
    if not active_cursor then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": Cursor is nil!"); return end
    local selected_text_content = ""
    if active_cursor:HasSelection() then
        if not active_cursor.CurSelection or not active_cursor.CurSelection[1] or not active_cursor.CurSelection[2] then
            micro.InfoBar():Message("ERROR: LLM "..command_type_str..": Invalid selection data.")
            return
        end
        local sel_start_ptr = active_cursor.CurSelection[1]
        local sel_end_ptr = active_cursor.CurSelection[2]
        if command_type_str == "modify" then
            job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
            job_state.selection_to_remove_start_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
            job_state.selection_to_remove_end_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
        elseif command_type_str == "generate" then
            job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
        end
        local sel_bytes = active_cursor:GetSelection()
        if sel_bytes then selected_text_content = util.String(sel_bytes) end
        micro.Log("LLM_DEBUG: Selected text (len " .. string.len(selected_text_content) .. ") captured.")
    else
        if command_type_str == "modify" then
            micro.InfoBar():Message("ERROR: LLM Modify: This command requires text to be selected.")
            return
        end
        job_state.insertion_loc_ptr = buffer_pkg.Loc(active_cursor.X, active_cursor.Y)
        micro.Log("LLM_DEBUG: No selection. Insertion at cursor for " .. command_type_str .. ".")
    end
    local ref_loc_for_context = job_state.insertion_loc_ptr
    local current_context_ref_line = ref_loc_for_context.Y
    local lines_of_context = 100
    local context_before_text = ""
    local context_after_text = ""
    if current_context_ref_line > 0 then
        local context_start_line = go_math.Max(0, current_context_ref_line - lines_of_context)
        local actual_context_end_line = current_context_ref_line - 1
        if actual_context_end_line >= context_start_line then
            local context_start_loc = buffer_pkg.Loc(0, context_start_line)
            local end_line_str_ctx = current_buffer:Line(actual_context_end_line)
            local context_end_loc = buffer_pkg.Loc(string.len(end_line_str_ctx), actual_context_end_line)
            local ctx_bytes_before = current_buffer:Substr(context_start_loc, context_end_loc)
            if ctx_bytes_before then context_before_text = util.String(ctx_bytes_before) end
        end
    end
    local total_lines_in_buffer = current_buffer:LinesNum()
    local reference_end_line_for_context_after = ref_loc_for_context.Y
    if command_type_str == "modify" and job_state.selection_to_remove_end_loc_ptr then
        reference_end_line_for_context_after = job_state.selection_to_remove_end_loc_ptr.Y
    end
    if reference_end_line_for_context_after < total_lines_in_buffer - 1 then
        local context_start_line_after = reference_end_line_for_context_after + 1
        local context_end_line_after = go_math.Min(total_lines_in_buffer - 1, reference_end_line_for_context_after + lines_of_context)
        if context_start_line_after <= context_end_line_after then
            local context_start_loc_after = buffer_pkg.Loc(0, context_start_line_after)
            local end_line_str_ctx_after = current_buffer:Line(context_end_line_after)
            local context_end_loc_after = buffer_pkg.Loc(string.len(end_line_str_ctx_after), context_end_line_after)
            local ctx_bytes_after = current_buffer:Substr(context_start_loc_after, context_end_loc_after)
            if ctx_bytes_after then context_after_text = util.String(ctx_bytes_after) end
        end
    end
    micro.Log("LLM_DEBUG: Context gathering complete for " .. command_type_str .. ".")
    local full_prompt_to_llm
    if command_type_str == "generate" then
        full_prompt_to_llm = string.format(
            "USER_REQUEST: %s\n\nEDITOR_CONTEXT (OPTIONAL):\n%s\n\nCONTEXT_AROUND_CURSOR_BEFORE:\n%s\n\nCONTEXT_AROUND_CURSOR_AFTER:\n%s",
            user_llm_request, selected_text_content, context_before_text, context_after_text
        )
    elseif command_type_str == "modify" then
         full_prompt_to_llm = string.format(
            "USER_REQUEST: %s\n\nCONTEXT_BEFORE_SELECTION:\n%s\n\nSELECTED_TEXT_TO_MODIFY:\n%s\n\nCONTEXT_AFTER_SELECTION:\n%s",
            user_llm_request, context_before_text, selected_text_content, context_after_text
        )
    else
        micro.InfoBar():Message("ERROR: Unknown command type: " .. command_type_str)
        return
    end
    micro.Log("LLM_DEBUG: Full prompt for LLM (" .. command_type_str .. "):\n" .. full_prompt_to_llm)
    job_state.temp_file_path = path.Join(config.ConfigDir, "llm_job_prompt.txt")
    local err_write = ioutil.WriteFile(job_state.temp_file_path, full_prompt_to_llm, 384) -- Decimal 384 for 0600 permissions
    if err_write ~= nil then
        micro.InfoBar():Message("ERROR: LLM "..command_type_str..": Failed to write temp prompt: "..tostring(err_write))
        if job_state.temp_file_path then local p = job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
        return
    end
    micro.Log("LLM_DEBUG: Temp file written: " .. job_state.temp_file_path .. " (permissions 0600 / decimal 384)")
    local llm_parts = {"cat", job_state.temp_file_path, "|", "llm"}
    local chosen_system_prompt_text_for_s_flag = nil
    local using_llm_template_t_flag = false
    local sys_prompt_source_log_msg = "unknown"

    if custom_system_prompt_arg then
        chosen_system_prompt_text_for_s_flag = custom_system_prompt_arg
        sys_prompt_source_log_msg = "custom from -s flag: [" .. custom_system_prompt_arg .. "]"
    elseif template_name_arg then
        table.insert(llm_parts, "-t"); table.insert(llm_parts, escapeShellArg(template_name_arg))
        sys_prompt_source_log_msg = "template from micro -t flag (" .. template_name_arg .. ")"
        using_llm_template_t_flag = true
    else
        -- Use PLUGIN_OPT_PREFIX here
        local default_template_key = PLUGIN_OPT_PREFIX .. "default_" .. command_type_str .. "_template"
        local default_template_name = config.GetGlobalOption(default_template_key)
        if default_template_name and #default_template_name > 0 then
            table.insert(llm_parts, "-t"); table.insert(llm_parts, escapeShellArg(default_template_name))
            sys_prompt_source_log_msg = "plugin default template ('" .. default_template_key .. "' = " .. default_template_name .. ") for '" .. command_type_str .. "'"
            using_llm_template_t_flag = true
        else
            chosen_system_prompt_text_for_s_flag = system_prompts[command_type_str]
            sys_prompt_source_log_msg = "hardcoded plugin default system prompt for '" .. command_type_str .. "'"
            if not chosen_system_prompt_text_for_s_flag then
                micro.InfoBar():Message("ERROR: No system prompt defined for command type: "..command_type_str)
                if job_state.temp_file_path then local p = job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
                return
            end
        end
    end

    if chosen_system_prompt_text_for_s_flag and not using_llm_template_t_flag then
        table.insert(llm_parts, "-s"); table.insert(llm_parts, escapeShellArg(chosen_system_prompt_text_for_s_flag))
    end

    micro.Log("LLM_DEBUG: System prompt/template decision: "..sys_prompt_source_log_msg)
    table.insert(llm_parts,"-x")
    table.insert(llm_parts,"-")
    local cmd = table.concat(llm_parts, " ")
    job_state.original_command = cmd
    micro.InfoBar():Message("LLM "..command_type_str..": Processing...")
    micro.Log("LLM_DEBUG: Executing command: "..cmd)
    micro.Log("LLM_DIAGNOSTIC_JOBSTART: Type of 'shell': " .. type(shell) .. ", Type of 'shell.JobStart': " .. type(shell and shell.JobStart))
    local job, err = shell.JobStart(cmd, handleJobStdout, handleJobStderr, handleJobExit, {})
    if err ~= nil then
        micro.InfoBar():Message("ERROR: LLM "..command_type_str..": Failed to start job: "..tostring(err))
        if job_state.temp_file_path then local p = job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
    elseif not job then
        micro.InfoBar():Message("ERROR: LLM "..command_type_str..": JobStart returned nil job object without error.")
        if job_state.temp_file_path then local p = job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
    end
    micro.Log("LLM_DEBUG: LLM Job ("..command_type_str..") initiated.")
end

function llmModifyCommand(bp, args)
    startLLMJob(bp, args, "modify")
end

function llmGenerateCommand(bp, args)
    startLLMJob(bp, args, "generate")
end

function llmTemplateCommand(bp, args)
    if not (bp and bp.NewTabCmd and type(bp.NewTabCmd) == "function") then
        micro.Log("LLM_CRITICAL: llmTemplateCommand: Initial 'bp' (type: " .. type(bp) .. ") is not valid or NewTabCmd is missing.")
        micro.InfoBar():Message("ERROR: Plugin command context invalid.")
        return
    end
    if #args ~= 1 or #args[1] == 0 then
        micro.InfoBar():Message("Usage: llm_template <template_name>")
        return
    end
    local template_name_to_edit = args[1]
    local templates_dir = getLLMTemplatesPath()
    if not templates_dir then
        micro.InfoBar():Message("ERROR: Could not determine LLM templates directory.")
        return
    end
    local template_file_actual_path = path.Join(templates_dir, template_name_to_edit .. ".yaml")
    micro.Log("LLM_DEBUG: llmTemplateCommand: Opening template file in new tab: " .. template_file_actual_path)
    bp:NewTabCmd({template_file_actual_path})
    micro.InfoBar():Message("Opening template '" .. template_name_to_edit .. ".yaml'...")
end

function llmTemplateDefaultCommand(bp, args)
    if #args == 0 then args = {"--show"} end

    if args[1] == "--show" then -- FIXED with ==
        -- Use PLUGIN_OPT_PREFIX here
        local g_key = PLUGIN_OPT_PREFIX .. "default_generate_template"
        local m_key = PLUGIN_OPT_PREFIX .. "default_modify_template"
        
        micro.Log("LLM_DEBUG: --show: Retrieving generate key: '" .. g_key .. "'")
        local g = config.GetGlobalOption(g_key)
        micro.Log("LLM_DEBUG: --show: Generate value: [" .. tostring(g) .. "] type: " .. type(g))
        
        micro.Log("LLM_DEBUG: --show: Retrieving modify key: '" .. m_key .. "'")
        local m = config.GetGlobalOption(m_key)
        micro.Log("LLM_DEBUG: --show: Modify value: [" .. tostring(m) .. "] type: " .. type(m))

        local g_display = (g and type(g) == "string" and #g > 0) and g or "Not set (uses built-in)"
        local m_display = (m and type(m) == "string" and #m > 0) and m or "Not set (uses built-in)"
        
        micro.InfoBar():Message("Defaults -- Generate: " .. g_display .. " | Modify: " .. m_display)
        return
    end

    if args[1] == "--clear" then -- FIXED with ==
        if #args ~= 2 or not (args[2] == "generate" or args[2] == "modify") then -- FIXED with ==
            micro.InfoBar():Message("Usage: llm_template_default --clear <generate|modify>")
            return
        end
        -- Use PLUGIN_OPT_PREFIX here
        local key_to_clear = PLUGIN_OPT_PREFIX .. "default_" .. args[2] .. "_template"
        config.SetGlobalOption(key_to_clear, "") 
        micro.InfoBar():Message("Default LLM template for '" .. args[2] .. "' cleared.")
        micro.Log("LLM_DEBUG: Cleared global option (set to empty string): " .. key_to_clear)
        return
    end

    if #args ~= 2 or not (args[2] == "generate" or args[2] == "modify") then -- FIXED with ==
        micro.InfoBar():Message("Usage: llm_template_default <template_name> <generate|modify>")
        return
    end

    local template_name_to_set = args[1]
    local command_type_to_set_for = args[2]
    
    local content_check = getLLMTemplateContent(template_name_to_set)
    micro.Log("LLM_DEBUG: llmTemplateDefaultCommand: getLLMTemplateContent result for '" .. template_name_to_set .. "': type=" .. type(content_check) .. ", value=[" .. tostring(content_check) .. "]")

    if content_check == nil then
        micro.InfoBar():Message("ERROR: LLM Template '" .. template_name_to_set .. "' not found or unreadable. Cannot set as default.")
        micro.Log("LLM_ERROR: Attempted to set non-existent/unreadable template '" .. template_name_to_set .. "' as default for " .. command_type_to_set_for)
        return
    end

    -- Use PLUGIN_OPT_PREFIX here
    local key_to_set = PLUGIN_OPT_PREFIX .. "default_" .. command_type_to_set_for .. "_template"
    micro.Log("LLM_DEBUG: llmTemplateDefaultCommand: Attempting to set default: Key='" .. key_to_set .. "', Value='" .. template_name_to_set .. "'")
    
    local err_set = config.SetGlobalOption(key_to_set, template_name_to_set)
    if err_set ~= nil then
         micro.Log("LLM_ERROR: llmTemplateDefaultCommand: config.SetGlobalOption for key '" .. key_to_set .. "' returned an error: " .. tostring(err_set))
    end

    local retrieved_after_set = config.GetGlobalOption(key_to_set)
    micro.Log("LLM_DEBUG: llmTemplateDefaultCommand: Value retrieved immediately after SetGlobalOption for key '" .. key_to_set .. "': [" .. tostring(retrieved_after_set) .. "] type: " .. type(retrieved_after_set))
    
    micro.InfoBar():Message("Default LLM template for '" .. command_type_to_set_for .. "' set to: " .. template_name_to_set)
    micro.Log("LLM_DEBUG: llmTemplateDefaultCommand: Set global option " .. key_to_set .. " = " .. template_name_to_set .. " (Infobar also updated)")
end

function init()
    micro.Log("LLM_DEBUG: LLM Plugin initializing...")
    
    config.RegisterGlobalOption("llm", "default_generate_template", "")
    config.RegisterGlobalOption("llm", "default_modify_template", "")

    config.MakeCommand("llm_modify", llmModifyCommand, config.NoComplete)
    config.MakeCommand("llm_generate", llmGenerateCommand, config.NoComplete)
    config.MakeCommand("llm_template", llmTemplateCommand, config.NoComplete)
    config.MakeCommand("llm_template_default", llmTemplateDefaultCommand, config.NoComplete)

    micro.Log("LLM_DEBUG: LLM Plugin initialized with registered options and commands.")
end
