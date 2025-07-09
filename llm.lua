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
local system_prompts = {
    modify = "You are a text editing assistant for modifying text in the micro text editor cli. The user will provide text they have selected, a specific request for how to modify that selected text, and surrounding context from the document. Modify ONLY the 'SELECTED TEXT TO MODIFY' based on the user's request and the context. IMPORTANT: Output _only_ the raw, modified code or text. Do not wrap your output in Markdown code blocks (for example, using triple-backtick fences before and after the code, optionally with a language specifier like 'python'). Do not include any explanatory text before or after the modified code/text unless explicitly asked to.",
    generate = "You are a text generation assistant for the micro CLI text editor. Based on the USER_REQUEST, and only if the USER_REQUEST explicitly refers to the EDITOR_CONTEXT, use that context. Otherwise, generate new text based ONLY on the USER_REQUEST, ignoring any editor context. IMPORTANT: Output _only_ the raw, generated text or code. Do NOT include any explanatory text before or after the generated text, unless the request specifically asks for explanation. If the USER_REQUEST is about the EDITOR_CONTEXT (e.g. 'summarize this', 'add comments for this code'), your output must be a NEW, SEPARATE block of text (e.g. just the summary, just the comments) and NOT the original context modified."
}
-- Global state for the currently active LLM job.
local job_state = {
    stdout_data = {}, stderr_data = {}, exit_code = nil,
    bp = nil, command_type = nil, insertion_loc_ptr = nil,
    selection_to_remove_start_loc_ptr = nil, selection_to_remove_end_loc_ptr = nil,
    temp_file_path = nil, original_command = ""
}

-- Function: parseLLMCommandArgs
-- Description: Parses arguments for the llm command.
-- Changelog:
-- - Fixed: Corrected comparison syntax to use '=='.
local function parseLLMCommandArgs(args_table)
    local user_request_parts = {}
    local custom_system_prompt = nil
    local template_name = nil
    if args_table then
        local i = 1
        while i <= #args_table do
            -- *** CORRECTED: Use standard '==' for comparisons ***
            if (args_table[i] == "-s" or args_table[i] == "--system") and args_table[i+1] then
                custom_system_prompt = args_table[i+1]
                i = i + 2
            elseif (args_table[i] == "-t" or args_table[i] == "--template") and args_table[i+1] then
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
local function getLLMTemplatesPath()
    local cmd_str = "llm templates path"
    local output, err_obj = shell.RunCommand(cmd_str)
    if err_obj ~= nil then
        micro.Log("LLM_ERROR: Could not get LLM templates path. Command: " .. cmd_str .. " Error: " .. tostring(err_obj))
        return nil
    end
    if output then
        local processed_path = string.gsub(string.gsub(output, "[\n\r]+%s*$", ""), "^%s*", "")
        if #processed_path > 0 then
             micro.Log("LLM_DEBUG: LLM templates path received: [" .. processed_path .. "]")
             return processed_path
        end
    end
    micro.Log("LLM_WARNING: 'llm templates path' returned no valid output. Raw: [" .. (output or "nil") .. "]")
    return nil
end

-- Function: getLLMTemplateContent
-- Description: Reads an LLM template's system prompt content from its YAML file.
-- Changelog:
-- - Fixed: Corrected comparison syntax to use '=='.
-- - Fixed: Improved handling of block scalar indentation and empty lines.
local function getLLMTemplateContent(name)
    local templates_dir_path = getLLMTemplatesPath()
    if not templates_dir_path then return nil end
    local template_file_name = name .. ".yaml"
    local specific_template_file_path = path.Join(templates_dir_path, template_file_name)
    micro.Log("LLM_DEBUG: getLLMTemplateContent: Checking for template file: " .. specific_template_file_path)
    local file_bytes, err_read = ioutil.ReadFile(specific_template_file_path)
    if err_read ~= nil then
        micro.Log("LLM_INFO: getLLMTemplateContent: Could not read template file '" .. specific_template_file_path .. "'. Error: " .. tostring(err_read))
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
                    if #text_content_part > 0 then -- Found first non-empty line
                        determined_initial_indent_len = #indent_str
                        table.insert(block_lines_array, text_content_part)
                    elseif #indent_str > 0 then -- Ignore indented empty lines before first content
                        -- continue
                    elseif #indent_str == 0 and #current_line_str == 0 then -- Stop if unindented empty line before first content
                        break
                    end
                else -- Already found first line, processing subsequent lines
                    if #indent_str >= determined_initial_indent_len then -- Sufficient indentation
                        table.insert(block_lines_array, string.sub(current_line_str, determined_initial_indent_len + 1))
                    elseif #text_content_part == 0 and #current_line_str == 0 then -- Allow empty lines only if indentation matches/exceeds
                        -- Empty line with less indent signals end of block
                        break
                    else -- Line has content but insufficient indent
                        break
                    end
                end
            end

            if block_char_match == ">" then -- Folded style
                local temp_folded_content = ""
                local prev_line_was_empty_in_block = true
                for _, line_text_in_block in ipairs(block_lines_array) do
                    local current_line_is_empty = (#string.gsub(line_text_in_block, "%s", "") == 0)
                    if current_line_is_empty then
                        if not prev_line_was_empty_in_block then temp_folded_content = temp_folded_content .. "\n" end
                        prev_line_was_empty_in_block = true
                    else
                        local trimmed_line_text = string.gsub(line_text_in_block, "^%s+", "")
                        if not prev_line_was_empty_in_block then temp_folded_content = temp_folded_content .. " " end
                        temp_folded_content = temp_folded_content .. trimmed_line_text
                        prev_line_was_empty_in_block = false
                    end
                end
                final_system_prompt = temp_folded_content
            else -- Literal style (|)
                final_system_prompt = table.concat(block_lines_array, "\n")
            end
            final_system_prompt = string.gsub(final_system_prompt, "\n?$", "") -- Remove optional final newline
        end
    end

    if final_system_prompt == nil then
        local single_line_match_text = string.match(file_content_string, "^system:%s*(.+)$")
        if single_line_match_text then
            local extracted_prompt = string.gsub(string.gsub(single_line_match_text, "^%s*", ""), "%s*$", "")
            -- *** CORRECTED: Use standard '==' for comparisons ***
            if (string.sub(extracted_prompt, 1, 1) == "'" and string.sub(extracted_prompt, -1, -1) == "'") or
               (string.sub(extracted_prompt, 1, 1) == "\"" and string.sub(extracted_prompt, -1, -1) == "\"") then
                extracted_prompt = string.sub(extracted_prompt, 2, -2)
            end
            final_system_prompt = extracted_prompt
        end
    end

    if final_system_prompt ~= nil then
        micro.Log("LLM_DEBUG: getLLMTemplateContent: Returning system prompt: [" .. final_system_prompt .. "]")
        return final_system_prompt
    else
        micro.Log("LLM_INFO: getLLMTemplateContent: 'system:' key not found or empty in file: " .. specific_template_file_path .. ". Returning empty string.")
        return ""
    end
end

-- Function: escapeShellArg
-- Description: Escapes a string for safe inclusion as a double-quoted argument.
local function escapeShellArg(s)
    if not s then return "" end
    return "\"" .. string.gsub(s, "\"", "\\\"") .. "\""
end

-- Function: handleJobStdout
-- Description: Callback to handle stdout data from the LLM job.
function handleJobStdout(output, userargs)
    table.insert(job_state.stdout_data, output)
end

-- Function: handleJobStderr
-- Description: Callback to handle stderr data from the LLM job.
function handleJobStderr(output, userargs)
    table.insert(job_state.stderr_data, output)
end

-- Function: handleJobExit
-- Description: Callback executed when the LLM job finishes.
-- Changelog:
-- - Fixed: Corrected nil check syntax to use '== nil'.
function handleJobExit(exit_status_or_output, userargs)
    micro.Log("LLM_DEBUG: Job exited (Op mode: " .. (job_state.command_type or "unknown") .. "). Exit: [" .. tostring(exit_status_or_output) .. "]")
    job_state.exit_code = tostring(exit_status_or_output)
    if job_state.temp_file_path then
        local temp_path_to_remove = job_state.temp_file_path
        job_state.temp_file_path = nil
        pcall(os.Remove, temp_path_to_remove)
        micro.Log("LLM_DEBUG: Temp file removed: " .. temp_path_to_remove)
    end
    local final_stdout = table.concat(job_state.stdout_data, "")
    local final_stderr = table.concat(job_state.stderr_data, "")
    micro.Log("LLM_DEBUG: Final STDOUT (len " .. string.len(final_stdout) .. "): [" .. final_stdout .. "]")
    micro.Log("LLM_DEBUG: Final STDERR (len " .. string.len(final_stderr) .. "): [" .. final_stderr .. "]")

    -- *** CORRECTED: Use standard '== nil' for checks ***
    if job_state.bp == nil or job_state.insertion_loc_ptr == nil then
        micro.InfoBar():Message("ERROR: LLM: Critical state missing post-job.")
        micro.Log("LLM_ERROR: Critical state missing. bp="..tostring(job_state.bp)..", ins_loc="..tostring(job_state.insertion_loc_ptr))
        return
    end
    -- *** CORRECTED: Use standard '== nil' for checks ***
    if job_state.command_type == "modify" and
       (job_state.selection_to_remove_start_loc_ptr == nil or job_state.selection_to_remove_end_loc_ptr == nil) then
        micro.InfoBar():Message("ERROR: LLM Modify: Selection locs missing post-job.")
        micro.Log("LLM_ERROR: Modify sel locs missing. Start="..tostring(job_state.selection_to_remove_start_loc_ptr)..", End="..tostring(job_state.selection_to_remove_end_loc_ptr))
        return
    end

    local current_buffer = job_state.bp.Buf
    local active_cursor = job_state.bp.Cursor
    if not current_buffer or not active_cursor then
        micro.InfoBar():Message("ERROR: LLM: Buffer/cursor nil post-job.")
        return
    end

    if string.match(final_stderr, "cat:.*Permission denied") then
        micro.InfoBar():Message("ERROR: LLM: Temp file permission error.")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") temp file perm fail: " .. final_stderr)
        return
    elseif final_stderr and (string.find(final_stderr, "command not found", 1, true) or string.find(final_stderr, "Error:", 1, true) or string.find(final_stderr, "Traceback", 1, true)) and not string.find(final_stderr, "ozone-platform-hint", 1, true) then
        micro.InfoBar():Message("ERROR: LLM: Critical failure (shell/LLM). See logs.")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") critical fail. Stderr: "..final_stderr)
        return
    end

    if final_stdout and string.gsub(final_stdout, "%s", "") ~= "" then
        if #final_stderr > 0 and not string.find(final_stderr, "ozone-platform-hint", 1, true) then
            micro.Log("LLM_DEBUG: Non-critical STDERR for (" .. job_state.original_command .. "): " .. final_stderr)
        end
        local output = string.gsub(string.gsub(final_stdout, "^%s*", ""), "%s*$", "")
        micro.Log("LLM_DEBUG: Final text for insertion: [" .. output .. "]")

        if type(job_state.insertion_loc_ptr.X) ~= "number" or type(job_state.insertion_loc_ptr.Y) ~= "number" then
             micro.InfoBar():Message("ERROR: LLM: Insert loc invalid.")
             return
        end
        local ins_loc = buffer_pkg.Loc(job_state.insertion_loc_ptr.X, job_state.insertion_loc_ptr.Y)

        if job_state.command_type == "modify" then
            if type(job_state.selection_to_remove_start_loc_ptr.X)~="number" or type(job_state.selection_to_remove_start_loc_ptr.Y)~="number" or
               type(job_state.selection_to_remove_end_loc_ptr.X)~="number" or type(job_state.selection_to_remove_end_loc_ptr.Y)~="number" then
                micro.InfoBar():Message("ERROR: LLM Modify: Remove locs invalid.")
                return
            end
            current_buffer:Remove(
                buffer_pkg.Loc(job_state.selection_to_remove_start_loc_ptr.X, job_state.selection_to_remove_start_loc_ptr.Y),
                buffer_pkg.Loc(job_state.selection_to_remove_end_loc_ptr.X, job_state.selection_to_remove_end_loc_ptr.Y)
            )
        end
        current_buffer:Insert(ins_loc, output)
        active_cursor:Relocate()
        micro.InfoBar():Message("LLM (" .. job_state.command_type .. "): Text updated.") -- Indicate mode
    else
        micro.InfoBar():Message("ERROR: LLM ("..job_state.command_type.."): No valid output received.")
        micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") no valid stdout. STDERR: ["..final_stderr.."]. Exit: ["..tostring(job_state.exit_code).."]")
    end
    micro.Log("LLM_DEBUG: --- LLM Job finished (Op mode: " .. (job_state.command_type or "unknown") .. ") ---")
end

-- Function: startLLMJob
-- Description: Core function to prepare and start the asynchronous LLM job.
function startLLMJob(bp, args, command_type_str)
    job_state.stdout_data = {} ; job_state.stderr_data = {} ; job_state.exit_code = nil
    job_state.bp = bp ; job_state.command_type = command_type_str
    job_state.temp_file_path = nil ; job_state.original_command = ""
    job_state.insertion_loc_ptr = nil ; job_state.selection_to_remove_start_loc_ptr = nil
    job_state.selection_to_remove_end_loc_ptr = nil

    local parsed_args_data = parseLLMCommandArgs(args) -- Uses corrected parseLLMCommandArgs
    local user_llm_request = parsed_args_data.user_request
    local custom_system_prompt_arg = parsed_args_data.custom_system_prompt
    local template_name_arg = parsed_args_data.template_name

    if user_llm_request == "" and not custom_system_prompt_arg and not template_name_arg then
        micro.InfoBar():Message("ERROR: LLM (" .. command_type_str .. "): No request prompt.")
        return
    end
    micro.Log("LLM_DEBUG: User request (" .. command_type_str .. "): [" .. user_llm_request .. "]")
    if custom_system_prompt_arg then micro.Log("LLM_DEBUG: Using custom -s: [" .. custom_system_prompt_arg .. "]") end
    if template_name_arg then micro.Log("LLM_DEBUG: Using custom -t: [" .. template_name_arg .. "]") end
    if not bp then micro.InfoBar():Message("ERROR: LLM: BufPane is nil!"); return end
    local current_buffer = bp.Buf ; local active_cursor = bp.Cursor
    if not current_buffer then micro.InfoBar():Message("ERROR: LLM: Buffer is nil!"); return end
    if not active_cursor then micro.InfoBar():Message("ERROR: LLM: Cursor is nil!"); return end

    local selected_text_content = ""
    if active_cursor:HasSelection() then
        local sel_bytes_check = active_cursor:GetSelection()
        if sel_bytes_check and #util.String(sel_bytes_check) > 0 then
             if not active_cursor.CurSelection or not active_cursor.CurSelection[1] or not active_cursor.CurSelection[2] then
                 micro.InfoBar():Message("ERROR: LLM: Invalid selection data.") ; return
             end
             local sel_start_ptr = active_cursor.CurSelection[1] ; local sel_end_ptr = active_cursor.CurSelection[2]
             if command_type_str == "modify" then
                 job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
                 job_state.selection_to_remove_start_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
                 job_state.selection_to_remove_end_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
             elseif command_type_str == "generate" then
                 job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
             end
             selected_text_content = util.String(sel_bytes_check)
             micro.Log("LLM_DEBUG: Selected text (len " .. string.len(selected_text_content) .. ") captured.")
        else
             job_state.insertion_loc_ptr = buffer_pkg.Loc(active_cursor.X, active_cursor.Y)
             micro.Log("LLM_DEBUG: Zero-width selection; treating as no selection for location.")
        end
    else
        job_state.insertion_loc_ptr = buffer_pkg.Loc(active_cursor.X, active_cursor.Y)
        micro.Log("LLM_DEBUG: No selection; insertion at cursor.")
    end

    local ref_loc_for_context = job_state.insertion_loc_ptr
    local current_context_ref_line = ref_loc_for_context.Y
    local lines_of_context = config.GetGlobalOption(PLUGIN_OPT_PREFIX .. "context_lines")
    if type(lines_of_context) ~= "number" or lines_of_context <= 0 then lines_of_context = 100 end

    local context_before_text = "" ; local context_after_text = ""
    if current_context_ref_line > 0 then
        local context_start_line = go_math.Max(0, current_context_ref_line - lines_of_context)
        local actual_context_end_line = current_context_ref_line - 1
        if actual_context_end_line >= context_start_line then
            local end_line_str_ctx = current_buffer:Line(actual_context_end_line)
            local ctx_bytes = current_buffer:Substr(buffer_pkg.Loc(0, context_start_line), buffer_pkg.Loc(string.len(end_line_str_ctx), actual_context_end_line))
            if ctx_bytes then context_before_text = util.String(ctx_bytes) end
        end
    end
    local total_lines_in_buffer = current_buffer:LinesNum()
    local ref_end_line = ref_loc_for_context.Y
    if command_type_str == "modify" and job_state.selection_to_remove_end_loc_ptr then ref_end_line = job_state.selection_to_remove_end_loc_ptr.Y end
    if ref_end_line < total_lines_in_buffer - 1 then
        local context_start_line_after = ref_end_line + 1
        local context_end_line_after = go_math.Min(total_lines_in_buffer - 1, ref_end_line + lines_of_context)
        if context_start_line_after <= context_end_line_after then
             local end_line_str_ctx_after = current_buffer:Line(context_end_line_after)
             local ctx_bytes = current_buffer:Substr(buffer_pkg.Loc(0, context_start_line_after), buffer_pkg.Loc(string.len(end_line_str_ctx_after), context_end_line_after))
             if ctx_bytes then context_after_text = util.String(ctx_bytes) end
        end
    end
    micro.Log("LLM_DEBUG: Context gathering complete ("..lines_of_context.." lines).")

    local full_prompt_to_llm
    if command_type_str == "generate" then
        full_prompt_to_llm = string.format( "USER_REQUEST: %s\n\nEDITOR_CONTEXT (OPTIONAL SELECTION):\n%s\n\nCONTEXT_AROUND_CURSOR_BEFORE:\n%s\n\nCONTEXT_AROUND_CURSOR_AFTER:\n%s", user_llm_request, selected_text_content, context_before_text, context_after_text )
    elseif command_type_str == "modify" then
         full_prompt_to_llm = string.format( "USER_REQUEST: %s\n\nCONTEXT_BEFORE_SELECTION:\n%s\n\nSELECTED_TEXT_TO_MODIFY:\n%s\n\nCONTEXT_AFTER_SELECTION:\n%s", user_llm_request, context_before_text, selected_text_content, context_after_text )
    else return end -- Should not happen
    micro.Log("LLM_DEBUG: Full prompt for LLM (" .. command_type_str .. "):\n" .. full_prompt_to_llm)

    job_state.temp_file_path = path.Join(config.ConfigDir, "llm_job_prompt.txt")
    -- Write the file with a UTF-8 Byte Order Mark (BOM) for Windows compatibility
    local bom = "\239\187\191" -- UTF-8 BOM bytes
    local err_write = ioutil.WriteFile(job_state.temp_file_path, bom .. full_prompt_to_llm, 384)
    if err_write ~= nil then
        micro.InfoBar():Message("ERROR: LLM: Failed write temp prompt: "..tostring(err_write))
        if job_state.temp_file_path then local p=job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
        return
    end
    micro.Log("LLM_DEBUG: Temp file written with UTF-8 BOM: " .. job_state.temp_file_path)

    local llm_executable = "llm"
    local is_windows = (string.byte(path.Join("a", "b"), 2) == 92)
    if is_windows then
        llm_executable = "llm.exe"
    end

    local llm_command_parts = {llm_executable}
    local chosen_system_prompt_text_for_s_flag = nil ; local using_llm_template_t_flag = false
    local sys_prompt_source_log_msg = "unknown"

    if custom_system_prompt_arg then
        chosen_system_prompt_text_for_s_flag = custom_system_prompt_arg
        sys_prompt_source_log_msg = "custom from -s flag"
    elseif template_name_arg then
        table.insert(llm_command_parts, "-t"); table.insert(llm_command_parts, escapeShellArg(template_name_arg))
        sys_prompt_source_log_msg = "template from -t flag (" .. template_name_arg .. ")"
        using_llm_template_t_flag = true
    else
        local default_template_key = PLUGIN_OPT_PREFIX .. "default_template"
        local default_template_name = config.GetGlobalOption(default_template_key)
        if default_template_name and #default_template_name > 0 then
            table.insert(llm_command_parts, "-t"); table.insert(llm_command_parts, escapeShellArg(default_template_name))
            sys_prompt_source_log_msg = "plugin default template (" .. default_template_name .. ")"
            using_llm_template_t_flag = true
        else
            chosen_system_prompt_text_for_s_flag = system_prompts[command_type_str]
            sys_prompt_source_log_msg = "hardcoded plugin default for '" .. command_type_str .. "'"
            if not chosen_system_prompt_text_for_s_flag then
                micro.InfoBar():Message("ERROR: No sys prompt for mode: " .. command_type_str)
                if job_state.temp_file_path then local p=job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end ; return
            end
        end
    end
    if chosen_system_prompt_text_for_s_flag and not using_llm_template_t_flag then
        table.insert(llm_command_parts, "-s"); table.insert(llm_command_parts, escapeShellArg(chosen_system_prompt_text_for_s_flag))
    end
    micro.Log("LLM_DEBUG: System prompt/template decision: " .. sys_prompt_source_log_msg)

    table.insert(llm_command_parts, "-x") ; table.insert(llm_command_parts, "-")
    local llm_command_str = table.concat(llm_command_parts, " ")

    local cmd_to_spawn
    local cmd_args

    if is_windows then
        cmd_to_spawn = "powershell.exe"
        
        -- Enhanced UTF-8 setup for PowerShell
        local utf8_setup = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; " ..
                          "[Console]::InputEncoding = [System.Text.Encoding]::UTF8; " ..
                          "$OutputEncoding = [System.Text.Encoding]::UTF8; " ..
                          "$env:PYTHONUTF8='1'; " ..
                          "$env:PYTHONIOENCODING='utf-8'; "
        
        -- Use -Raw flag with Get-Content to preserve exact bytes
        local pipeline_command = string.format("Get-Content %s -Raw | %s", 
                                             escapeShellArg(job_state.temp_file_path), 
                                             llm_command_str)
        
        local full_robust_command = utf8_setup .. pipeline_command
        cmd_args = {"-NoProfile", "-Command", full_robust_command}
        
        -- Alternative approach using cmd.exe (uncomment if PowerShell still has issues)
        -- cmd_to_spawn = "cmd.exe"
        -- local cmd_pipeline = string.format("type %s | %s", escapeShellArg(job_state.temp_file_path), llm_command_str)
        -- cmd_args = {"/C", "chcp 65001 && " .. cmd_pipeline}
    else
        cmd_to_spawn = "bash"
        local pipeline = string.format("cat %s | %s", escapeShellArg(job_state.temp_file_path), llm_command_str)
        cmd_args = {"-c", pipeline}
    end

    job_state.original_command = cmd_to_spawn .. " " .. table.concat(cmd_args, " ")
    micro.InfoBar():Message("LLM (" .. command_type_str .. "): Processing...")
    micro.Log("LLM_DEBUG: Spawning command: " .. cmd_to_spawn)
    micro.Log("LLM_DEBUG: With arguments: " .. table.concat(cmd_args, ", "))

    local job, err = shell.JobSpawn(cmd_to_spawn, cmd_args, handleJobStdout, handleJobStderr, handleJobExit, {})
    
    if err ~= nil then
        micro.InfoBar():Message("ERROR: LLM: JobSpawn failed: "..tostring(err))
        if job_state.temp_file_path then local p=job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
    elseif not job then
        micro.InfoBar():Message("ERROR: LLM: JobSpawn nil job.")
        if job_state.temp_file_path then local p=job_state.temp_file_path; job_state.temp_file_path=nil; pcall(os.Remove,p); end
    end
    micro.Log("LLM_DEBUG: LLM Job (" .. command_type_str .. ") initiated.")
end

-- Function: llmCommand (NEW)
-- Description: Unified command entry point. Determines mode based on selection.
local function llmCommand(bp, args)
    local command_type_str
    if bp.Cursor:HasSelection() then
        local sel_bytes = bp.Cursor:GetSelection()
        if sel_bytes and #util.String(sel_bytes) > 0 then command_type_str = "modify"
        else command_type_str = "generate" end
    else command_type_str = "generate" end
    micro.Log("LLM_DEBUG: llmCommand: Determined mode: " .. command_type_str)
    startLLMJob(bp, args, command_type_str)
end

-- Function: llmTemplateCommand
-- Description: Opens the specified LLM template file in a new Micro tab.
function llmTemplateCommand(bp, args)
    if not (bp and bp.NewTabCmd and type(bp.NewTabCmd) == "function") then
        micro.InfoBar():Message("ERROR: Plugin context invalid.") ; return
    end
    if #args ~= 1 or #args[1] == 0 then
        micro.InfoBar():Message("Usage: llm_template <template_name>") ; return
    end
    local template_name_to_edit = args[1]
    local templates_dir = getLLMTemplatesPath()
    if not templates_dir then micro.InfoBar():Message("ERROR: No LLM templates dir.") ; return end
    local template_file_actual_path = path.Join(templates_dir, template_name_to_edit .. ".yaml")
    micro.Log("LLM_DEBUG: llmTemplateCommand: Opening: " .. template_file_actual_path)
    bp:NewTabCmd({template_file_actual_path})
    micro.InfoBar():Message("Opening template '" .. template_name_to_edit .. ".yaml'...")
end

-- Function: llmTemplateDefaultCommand
-- Description: Manages the single default LLM template.
-- Changelog:
-- - Modified: Simplified for single default template.
-- - Fixed: Corrected comparison syntax to use '=='.
local function llmTemplateDefaultCommand(bp, args)
    local default_template_config_key = PLUGIN_OPT_PREFIX .. "default_template"
    local usage_msg = "Usage: llm_template_default <template_name> | --show | --clear"

    -- *** CORRECTED: Use standard '==' for comparisons ***
    if #args == 0 or (#args == 1 and args[1] == "--show") then
        local current_default = config.GetGlobalOption(default_template_config_key)
        local display = (current_default and type(current_default) == "string" and #current_default > 0) and current_default or "Not set"
        micro.InfoBar():Message("Default LLM template: " .. display)
        return
    end
    -- *** CORRECTED: Use standard '==' for comparisons ***
    if #args == 1 and args[1] == "--clear" then
        config.SetGlobalOption(default_template_config_key, "")
        micro.InfoBar():Message("Default LLM template cleared.")
        return
    end
    if #args == 1 then
        local template_name = args[1]
        if string.sub(template_name, 1, 2) == "--" then micro.InfoBar():Message(usage_msg) ; return end
        local content_check = getLLMTemplateContent(template_name)
        if content_check == nil then
            micro.InfoBar():Message("ERROR: Template '" .. template_name .. "' not found/unreadable.") ; return
        end
        config.SetGlobalOption(default_template_config_key, template_name)
        micro.InfoBar():Message("Default LLM template set to: " .. template_name)
        return
    end
    micro.InfoBar():Message(usage_msg)
end

-- Function: init
-- Description: Initializes the LLM plugin.
-- Changelog:
-- - Fixed: Correct arguments passed to config.RegisterGlobalOption (pluginName, optionName, defaultValue).
function init()
    micro.Log("LLM_DEBUG: LLM Plugin initializing...")

    -- *** CORRECTED: Pass 3 arguments to RegisterGlobalOption ***
    local pluginName = "llm" -- Define plugin name consistently
    config.RegisterGlobalOption(pluginName, "default_template", "")
    config.RegisterGlobalOption(pluginName, "context_lines", 100)

    config.MakeCommand("llm", llmCommand, config.NoComplete)
    config.MakeCommand("llm_template", llmTemplateCommand, config.NoComplete)
    config.MakeCommand("llm_template_default", llmTemplateDefaultCommand, config.NoComplete)
    micro.Log("LLM_DEBUG: LLM Plugin initialized with unified commands.")
end
