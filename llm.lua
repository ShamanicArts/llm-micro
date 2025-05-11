-- llm.lua
local config = import("micro/config")
local shell = import("micro/shell")
local micro = import("micro")
local buffer_pkg = import("micro/buffer")
local go_math = import("math")
local util = import("micro/util")
local os = import("os") 
local path = import("path/filepath") 
local ioutil = import("io/ioutil") 

local system_prompts = {
    modify = "You are a text editing assistant for modifying text in the micro text editor cli. The user will provide text they have selected, a specific request for how to modify that selected text, and surrounding context from the document. Modify ONLY the 'SELECTED TEXT TO MODIFY' based on the user's request and the context. IMPORTANT: Output *only* the raw, modified code or text. Do not wrap your output in Markdown code blocks (for example, using triple-backtick fences before and after the code, optionally with a language specifier like 'python'). Do not include any explanatory text before or after the modified code/text unless explicitly asked to.",
    generate = "You are a text generation assistant for the micro CLI text editor. Based on the user's request, and any selected text provided as OPTIONAL context (or text near the cursor if nothing is selected), generate new text. IMPORTANT: Output *only* the raw, generated text. Do not wrap output in Markdown code blocks (for example, using triple-backtick fences before and after the code, optionally with a language specifier like 'python').IMPORTANT: DO NOT WRAP YOUR TEXT OUTPUT IN CODEBLOCKS . JUST OUTPUT RAW TEXT .  Do not include any explanatory text before or after the generated text, unless the request specifically asks for explanation."
}

local job_state = {
    stdout_data = {},
    stderr_data = {},
    exit_code = nil, 
    bp = nil,
    command_type = nil,                 
    insertion_loc_ptr = nil,            
    selection_to_remove_start_loc_ptr = nil, 
    selection_to_remove_end_loc_ptr = nil,   
    temp_file_path = nil,
    original_command = ""
}

function handleJobStdout(output, userargs)
    table.insert(job_state.stdout_data, output)
    micro.Log("LLM_DEBUG: Job STDOUT (" .. (job_state.command_type or "unknown") .. "): " .. output)
end

function handleJobStderr(output, userargs)
    table.insert(job_state.stderr_data, output)
    micro.Log("LLM_DEBUG: Job STDERR (" .. (job_state.command_type or "unknown") .. "): " .. output)
end

function handleJobExit(exit_status_or_output, userargs)
    micro.Log("LLM_DEBUG: Job exited (" .. job_state.command_type .. "). Raw data: [" .. tostring(exit_status_or_output) .. "]")
    job_state.exit_code = tostring(exit_status_or_output)

    if job_state.temp_file_path then
        pcall(os.Remove, job_state.temp_file_path)
        job_state.temp_file_path = nil
        micro.Log("LLM_DEBUG: Temp file removed.")
    end

    local final_stdout = table.concat(job_state.stdout_data, "")
    local final_stderr = table.concat(job_state.stderr_data, "")
    micro.Log("LLM_DEBUG: Final STDOUT (" .. job_state.command_type .. ", len " .. string.len(final_stdout) .. "): [" .. final_stdout .. "]")
    micro.Log("LLM_DEBUG: Final STDERR (" .. job_state.command_type .. ", len " .. string.len(final_stderr) .. "): [" .. final_stderr .. "]")

    if job_state.bp == nil or job_state.insertion_loc_ptr == nil then
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Critical state missing in job exit.")
        return
    end
    if job_state.command_type == "modify" and (job_state.selection_to_remove_start_loc_ptr == nil or job_state.selection_to_remove_end_loc_ptr == nil) then
        micro.InfoBar():Message("ERROR: LLM Modify: Selection locs for removal missing.")
        return
    end
    
    local current_buffer = job_state.bp.Buf 
    local active_cursor = job_state.bp.Cursor

    if not current_buffer or not active_cursor then
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Buffer or cursor became nil in onExit.")
        return
    end

    if final_stderr and (string.find(final_stderr, "command not found", 1, true) or string.match(final_stderr, "cat: /home/.+/llm_job_prompt.txt: No such file or directory") ) then
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Critical shell error. Check log.")
        micro.Log("LLM_DEBUG: Cmd (" .. job_state.original_command .. ") failed (critical STDERR): " .. final_stderr)
        return
    end

    if final_stdout and string.gsub(final_stdout, "%s", "") ~= "" then
        if #final_stderr > 0 then
            micro.Log("LLM_DEBUG: Note: STDERR for (" .. job_state.original_command .. "): " .. final_stderr)
        end

        local output_to_insert = final_stdout
        output_to_insert = string.gsub(output_to_insert, "^%s*", "") 
        output_to_insert = string.gsub(output_to_insert, "%s*$", "") 
        
        micro.Log("LLM_DEBUG: Final text for insertion (" .. job_state.command_type .. "): [" .. output_to_insert .. "]")

        if type(job_state.insertion_loc_ptr.X) ~= "number" or type(job_state.insertion_loc_ptr.Y) ~= "number" then
            micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": insertion_loc_ptr fields (X,Y) invalid.")
            return
        end
        local insertion_loc_val = buffer_pkg.Loc(job_state.insertion_loc_ptr.X, job_state.insertion_loc_ptr.Y)

        if job_state.command_type == "modify" then
            if type(job_state.selection_to_remove_start_loc_ptr.X) ~= "number" or type(job_state.selection_to_remove_start_loc_ptr.Y) ~= "number" or
               type(job_state.selection_to_remove_end_loc_ptr.X) ~= "number" or type(job_state.selection_to_remove_end_loc_ptr.Y) ~= "number" then
                micro.InfoBar():Message("ERROR: LLM Modify: selection_to_remove loc_ptr fields (X,Y) invalid.")
                return
            end
            local sel_start_val = buffer_pkg.Loc(job_state.selection_to_remove_start_loc_ptr.X, job_state.selection_to_remove_start_loc_ptr.Y)
            local sel_end_val = buffer_pkg.Loc(job_state.selection_to_remove_end_loc_ptr.X, job_state.selection_to_remove_end_loc_ptr.Y)
            current_buffer:Remove(sel_start_val, sel_end_val)
        end
        
        current_buffer:Insert(insertion_loc_val, output_to_insert) 
        active_cursor:Relocate()
        
        micro.InfoBar():Message("LLM " .. job_state.command_type .. ": Text updated successfully.")
    else
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": No valid output from LLM.")
        micro.Log("LLM_DEBUG: Cmd (" .. job_state.original_command .. ") no valid stdout. STDERR: " .. final_stderr .. ". Exit: " .. job_state.exit_code)
    end
    micro.Log("LLM_DEBUG: --- LLM Job finished (" .. job_state.command_type .. ") ---")
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

    local arg_table = {}
    if args then
        for i = 1, #args do
            local arg_val = args[i]
            if arg_val ~= nil then table.insert(arg_table, tostring(arg_val)) end
        end
    end

    if #arg_table == 0 then 
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": No request prompt provided.")
        return 
    end
    local user_llm_request = table.concat(arg_table, " ")
    micro.Log("LLM_DEBUG: User request (" .. command_type_str .. "): [" .. user_llm_request .. "]")

    if not bp then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp (BufPane) is nil!"); return end
    local current_buffer = bp.Buf
    local active_cursor = bp.Cursor
    if not current_buffer then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp.Buf is nil!"); return end
    if not active_cursor then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp.Cursor is nil!"); return end

    local selected_text_content = "" 

    if active_cursor:HasSelection() then
        if not active_cursor.CurSelection or not active_cursor.CurSelection[1] or not active_cursor.CurSelection[2] then
            micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": active_cursor.CurSelection is invalid."); return
        end
        local sel_start_ptr = active_cursor.CurSelection[1]
        local sel_end_ptr = active_cursor.CurSelection[2]
        
        if command_type_str == "modify" then
            job_state.insertion_loc_ptr = sel_start_ptr 
            job_state.selection_to_remove_start_loc_ptr = sel_start_ptr
            job_state.selection_to_remove_end_loc_ptr = sel_end_ptr
            micro.Log("LLM_DEBUG: Using selection for modify. Insert at sel_start, remove sel_start to sel_end.")
        elseif command_type_str == "generate" then
            -- *** MODIFIED: For generate with selection, insert AFTER selection ***
            job_state.insertion_loc_ptr = sel_end_ptr 
            micro.Log("LLM_DEBUG: Using selection as context for generate; will insert AFTER selection (at sel_end).")
        end

        local sel_bytes = active_cursor:GetSelection()
        if sel_bytes then selected_text_content = util.String(sel_bytes) end
        micro.Log("LLM_DEBUG: Selected text (len " .. string.len(selected_text_content) .. ") present for " .. command_type_str .. " command.")
    else
        if command_type_str == "modify" then
            micro.InfoBar():Message("ERROR: LLM Modify: No text selected to modify.")
            return
        end
        job_state.insertion_loc_ptr = buffer_pkg.Loc(active_cursor.X, active_cursor.Y) 
        micro.Log("LLM_DEBUG: No selection for " .. command_type_str .. ", will insert at cursor X="..active_cursor.X ..", Y="..active_cursor.Y)
    end

    local ref_loc_for_context = job_state.insertion_loc_ptr
    local current_context_ref_line = ref_loc_for_context.Y

    local lines_of_context = 30 
    local context_before_text = ""
    if current_context_ref_line > 0 then
        local context_start_line = go_math.Max(0, current_context_ref_line - lines_of_context)
        local actual_context_end_line = current_context_ref_line - 1 
        if actual_context_end_line >= context_start_line then
            local context_start_loc = buffer_pkg.Loc(0, context_start_line)
            local end_line_str_ctx = current_buffer:Line(actual_context_end_line)
            local context_end_loc = buffer_pkg.Loc(string.len(end_line_str_ctx), actual_context_end_line)
            local ctx_bytes = current_buffer:Substr(context_start_loc, context_end_loc)
            if ctx_bytes then context_before_text = util.String(ctx_bytes) end
        end
    end

    local total_lines_in_buffer = current_buffer:LinesNum()
    local context_after_text = ""
    
    local reference_end_line_for_context_after
    if command_type_str == "modify" and job_state.selection_to_remove_end_loc_ptr then
        reference_end_line_for_context_after = job_state.selection_to_remove_end_loc_ptr.Y
    else -- For generate (with or without selection), or modify with no valid end_sel_ptr (shouldn't happen)
        reference_end_line_for_context_after = ref_loc_for_context.Y
    end

    if reference_end_line_for_context_after < total_lines_in_buffer - 1 then
        local context_start_line = reference_end_line_for_context_after + 1 
        local context_end_line = go_math.Min(total_lines_in_buffer - 1, reference_end_line_for_context_after + lines_of_context)
        if context_start_line <= context_end_line then
            local context_start_loc = buffer_pkg.Loc(0, context_start_line)
            local end_line_str_ctx = current_buffer:Line(context_end_line)
            local context_end_loc = buffer_pkg.Loc(string.len(end_line_str_ctx), context_end_line)
            local ctx_bytes = current_buffer:Substr(context_start_loc, context_end_loc)
            if ctx_bytes then context_after_text = util.String(ctx_bytes) end
        end
    end
    micro.Log("LLM_DEBUG: Context gathered for " .. command_type_str .. ".")

    local full_prompt_to_llm
    if command_type_str == "generate" then
        if selected_text_content ~= "" then
            full_prompt_to_llm = string.format(
                "USER_REQUEST: %s\n\nSELECTED_TEXT_AS_ADDITIONAL_CONTEXT:\n%s\n\nCONTEXT_AROUND_SELECTION_END_BEFORE:\n%s\n\nCONTEXT_AROUND_SELECTION_END_AFTER:\n%s",
                user_llm_request, selected_text_content, context_before_text, context_after_text)
        else 
            full_prompt_to_llm = string.format(
                "USER_REQUEST: %s\n\nCONTEXT_AROUND_CURSOR_BEFORE:\n%s\n\nCONTEXT_AROUND_CURSOR_AFTER:\n%s",
                user_llm_request, context_before_text, context_after_text)
        end
    else 
         full_prompt_to_llm = string.format(
            "USER_REQUEST: %s\n\nCONTEXT_BEFORE_SELECTION:\n%s\n\nSELECTED_TEXT_TO_MODIFY:\n%s\n\nCONTEXT_AFTER_SELECTION:\n%s",
            user_llm_request, context_before_text, selected_text_content, context_after_text)
    end
    micro.Log("LLM_DEBUG: Full prompt for LLM (" .. command_type_str .. "):\n" .. full_prompt_to_llm)

    job_state.temp_file_path = path.Join(config.ConfigDir, "llm_job_prompt.txt")
    local err_write = ioutil.WriteFile(job_state.temp_file_path, full_prompt_to_llm, 384)
    if err_write ~= nil then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": Failed to write temp prompt: " .. tostring(err_write))
        if job_state.temp_file_path then pcall(os.Remove, job_state.temp_file_path); job_state.temp_file_path = nil; end
        return
    end
    micro.Log("LLM_DEBUG: Temp file written: " .. job_state.temp_file_path)

    local current_system_prompt = system_prompts[command_type_str]
    if not current_system_prompt then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": No system prompt defined.")
        if job_state.temp_file_path then pcall(os.Remove, job_state.temp_file_path); job_state.temp_file_path = nil; end
        return
    end
    local escaped_system_prompt = string.gsub(current_system_prompt, "\"", "\\\"") 
    local llm_cli_command = string.format("cat %s | llm -s \"%s\" -", job_state.temp_file_path, escaped_system_prompt)
    job_state.original_command = llm_cli_command

    micro.InfoBar():Message("LLM " .. command_type_str .. ": Starting LLM job...") 
    micro.Log("LLM_DEBUG: Starting job (" .. command_type_str .. "): " .. llm_cli_command)

    local job_cmd_obj, job_err = shell.JobStart(llm_cli_command, handleJobStdout, handleJobStderr, handleJobExit, {})

    if job_err ~= nil then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": Failed to start job: " .. tostring(job_err))
        if job_state.temp_file_path then pcall(os.Remove, job_state.temp_file_path); job_state.temp_file_path = nil; end
        return
    end
    if job_cmd_obj == nil then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": JobStart nil object but no error.")
        if job_state.temp_file_path then pcall(os.Remove, job_state.temp_file_path); job_state.temp_file_path = nil; end
        return
    end
    
    micro.Log("LLM_DEBUG: LLM Job (" .. command_type_str .. ") started. Waiting for callbacks...") 
end

function llmModifyCommand(bp, args)
    startLLMJob(bp, args, "modify")
end

function llmGenerateCommand(bp, args)
    startLLMJob(bp, args, "generate")
end

function init()
    micro.Log("LLM_DEBUG: LLM Plugin initializing (v15.1)...")
    config.MakeCommand("llm_modify", llmModifyCommand, config.NoComplete)
    config.MakeCommand("llm_generate", llmGenerateCommand, config.NoComplete) 
    micro.InfoBar():Message("LLM Plugin: 'llm_modify' and 'llm_generate' commands loaded.")
end
