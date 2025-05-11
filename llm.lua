-- llm.lua (Reverting to User's Original Core Logic + Minimal Feature Integration)
local config = import("micro/config")
local shell = import("micro/shell")
local micro = import("micro")
local buffer_pkg = import("micro/buffer")
local go_math = import("math") 
local util = import("micro/util")
local os = import("os")
local path = import("path/filepath")
local ioutil = import("io/ioutil")
local json = import("encoding/json") 

-- User's original system prompts
local system_prompts = {
    modify = "You are a text editing assistant for modifying text in the micro text editor cli. The user will provide text they have selected, a specific request for how to modify that selected text, and surrounding context from the document. Modify ONLY the 'SELECTED TEXT TO MODIFY' based on the user's request and the context. IMPORTANT: Output _only_ the raw, modified code or text. Do not wrap your output in Markdown code blocks (for example, using triple-backtick fences before and after the code, optionally with a language specifier like 'python'). Do not include any explanatory text before or after the modified code/text unless explicitly asked to.",
    generate = "You are a text generation assistant for the micro CLI text editor. Based on the USER_REQUEST, and only if the USER_REQUEST explicitly refers to the EDITOR_CONTEXT, use that context. Otherwise, generate new text based ONLY on the USER_REQUEST, ignoring any editor context. IMPORTANT: Output _only_ the raw, generated text or code. Do NOT include any explanatory text before or after the generated text, unless the request specifically asks for explanation. If the USER_REQUEST is about the EDITOR_CONTEXT (e.g. 'summarize this', 'add comments for this code'), your output must be a NEW, SEPARATE block of text (e.g. just the summary, just the comments) and NOT the original context modified."
}

local job_state = {
    stdout_data = {}, stderr_data = {}, exit_code = nil, bp = nil, command_type = nil,                 
    insertion_loc_ptr = nil, selection_to_remove_start_loc_ptr = nil, selection_to_remove_end_loc_ptr = nil,   
    temp_file_path = nil, original_command = ""
}

local function parseLLMCommandArgs(args_table)
    local user_request_parts = {}
    local custom_system_prompt = nil
    local template_name = nil
    if args_table then 
        local i = 1
        while i <= #args_table do
            if (args_table[i] == "-s" or args_table[i] == "--system") and args_table[i+1] then
                custom_system_prompt = args_table[i+1]; i = i + 2
            elseif (args_table[i] == "-t" or args_table[i] == "--template") and args_table[i+1] then
                template_name = args_table[i+1]; i = i + 2
            else
                if args_table[i] ~= nil then table.insert(user_request_parts, tostring(args_table[i])) end
                i = i + 1
            end
        end
    end
    return { user_request = table.concat(user_request_parts, " "), custom_system_prompt = custom_system_prompt, template_name = template_name }
end

local function getLLMTemplatesPath()
    local _, stdout, stderr, err = shell.Run("llm templates path")
    if err ~= nil or (stderr and string.len(stderr) > 0) then micro.Log("LLM_ERROR: getLLMTemplatesPath: " .. (stderr or tostring(err))); return nil end
    if stdout then return string.gsub(stdout, "%s*$", "") end; return nil
end

local function getLLMTemplateContent(name)
    local p = getLLMTemplatesPath(); if not p then return nil end
    local bytes, err_read = ioutil.ReadFile(p); if err_read ~= nil then micro.Log("LLM_ERROR: getLLMTemplateContent ReadFile: " .. tostring(err_read)); return nil end
    local file_content_str = util.String(bytes)
    local data, err_json = json.Unmarshal(file_content_str); if err_json ~= nil then micro.Log("LLM_ERROR: getLLMTemplateContent Unmarshal: " .. tostring(err_json)); return nil end
    if data and data[name] and data[name].system then return data[name].system end; return nil
end

local function escapeShellArg(s) if not s then return "" end; return "\"" .. string.gsub(s, "\"", "\\\"") .. "\"" end

function handleJobStdout(output, userargs) table.insert(job_state.stdout_data, output); micro.Log("LLM_DEBUG: Job STDOUT (" .. (job_state.command_type or "unknown") .. "): " .. output) end
function handleJobStderr(output, userargs) table.insert(job_state.stderr_data, output); micro.Log("LLM_DEBUG: Job STDERR (" .. (job_state.command_type or "unknown") .. "): " .. output) end

function handleJobExit(exit_status_or_output, userargs)
    micro.Log("LLM_DEBUG: Job exited (" .. job_state.command_type .. "). Raw data: [" .. tostring(exit_status_or_output) .. "]")
    job_state.exit_code = tostring(exit_status_or_output)
    if job_state.temp_file_path then pcall(os.Remove, job_state.temp_file_path); job_state.temp_file_path = nil; micro.Log("LLM_DEBUG: Temp file removed.") end
    local final_stdout = table.concat(job_state.stdout_data, ""); local final_stderr = table.concat(job_state.stderr_data, "")
    micro.Log("LLM_DEBUG: Final STDOUT (" .. job_state.command_type .. ", len " .. string.len(final_stdout) .. "): [" .. final_stdout .. "]")
    micro.Log("LLM_DEBUG: Final STDERR (" .. job_state.command_type .. ", len " .. string.len(final_stderr) .. "): [" .. final_stderr .. "]")
    if job_state.bp == nil or job_state.insertion_loc_ptr == nil then micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Critical state missing."); return end
    if job_state.command_type == "modify" and (job_state.selection_to_remove_start_loc_ptr == nil or job_state.selection_to_remove_end_loc_ptr == nil) then micro.InfoBar():Message("ERROR: LLM Modify: Selection locs missing."); return end
    local current_buffer = job_state.bp.Buf; local active_cursor = job_state.bp.Cursor
    if not current_buffer or not active_cursor then micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Buffer/cursor nil."); return end
    if string.match(final_stderr, "cat:.*Permission denied") then micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": Temp file perm err."); micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") perm fail: " .. final_stderr); return
    elseif final_stderr and (string.find(final_stderr, "command not found") or string.find(final_stderr, "Error:")) then micro.InfoBar():Message("ERROR: LLM "..job_state.command_type..": Critical shell/LLM err."); micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") crit fail: "..final_stderr); return end
    if final_stdout and string.gsub(final_stdout, "%s", "") ~= "" then
        if #final_stderr > 0 then micro.Log("LLM_DEBUG: Note: STDERR for (" .. job_state.original_command .. "): " .. final_stderr) end
        local output = string.gsub(string.gsub(final_stdout, "^%s*", ""), "%s*$", "") 
        micro.Log("LLM_DEBUG: Final text for insertion: [" .. output .. "]")
        if type(job_state.insertion_loc_ptr.X)~="number" or type(job_state.insertion_loc_ptr.Y)~="number" then micro.InfoBar():Message("ERROR: LLM Insert loc invalid"); return end
        local ins_loc = buffer_pkg.Loc(job_state.insertion_loc_ptr.X, job_state.insertion_loc_ptr.Y)
        if job_state.command_type == "modify" then
            if type(job_state.selection_to_remove_start_loc_ptr.X)~="number" or type(job_state.selection_to_remove_start_loc_ptr.Y)~="number" or type(job_state.selection_to_remove_end_loc_ptr.X)~="number" or type(job_state.selection_to_remove_end_loc_ptr.Y)~="number" then micro.InfoBar():Message("ERROR: LLM Modify remove locs invalid"); return end
            current_buffer:Remove(buffer_pkg.Loc(job_state.selection_to_remove_start_loc_ptr.X, job_state.selection_to_remove_start_loc_ptr.Y), buffer_pkg.Loc(job_state.selection_to_remove_end_loc_ptr.X, job_state.selection_to_remove_end_loc_ptr.Y))
        end
        current_buffer:Insert(ins_loc, output); active_cursor:Relocate()
        micro.InfoBar():Message("LLM " .. job_state.command_type .. ": Text updated.")
    else
        micro.InfoBar():Message("ERROR: LLM " .. job_state.command_type .. ": No valid output."); micro.Log("LLM_ERROR: Cmd("..job_state.original_command..") no valid stdout. STDERR: "..final_stderr..". Exit: "..job_state.exit_code)
    end
    micro.Log("LLM_DEBUG: --- LLM Job finished (" .. job_state.command_type .. ") ---")
end

-- This function structure mirrors your original `startLLMJob`
function startLLMJob(bp, args, command_type_str)
    job_state.stdout_data = {}; job_state.stderr_data = {}; job_state.exit_code = nil; job_state.bp = bp; job_state.command_type = command_type_str
    job_state.temp_file_path = nil; job_state.original_command = ""; job_state.insertion_loc_ptr = nil
    job_state.selection_to_remove_start_loc_ptr = nil; job_state.selection_to_remove_end_loc_ptr = nil

    local parsed_cmd_args_data = parseLLMCommandArgs(args) -- Get {user_request, custom_system_prompt, template_name}
    local user_llm_request = parsed_cmd_args_data.user_request
    local custom_system_prompt_arg = parsed_cmd_args_data.custom_system_prompt
    local template_name_arg = parsed_cmd_args_data.template_name

    if user_llm_request == "" and not custom_system_prompt_arg and not template_name_arg then
        micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": No request prompt provided.")
        return
    end
    micro.Log("LLM_DEBUG: User request (" .. command_type_str .. "): [" .. user_llm_request .. "]")
    if custom_system_prompt_arg then micro.Log("LLM_DEBUG: Using -s: [" .. custom_system_prompt_arg .. "]") end
    if template_name_arg then micro.Log("LLM_DEBUG: Using -t: [" .. template_name_arg .. "]") end

    if not bp then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp (BufPane) is nil!"); return end
    local current_buffer = bp.Buf; local active_cursor = bp.Cursor
    if not current_buffer then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp.Buf is nil!"); return end
    if not active_cursor then micro.InfoBar():Message("ERROR: LLM " .. command_type_str .. ": bp.Cursor is nil!"); return end
    
    local selected_text_content = ""
    if active_cursor:HasSelection() then
        if not active_cursor.CurSelection or not active_cursor.CurSelection[1] or not active_cursor.CurSelection[2] then micro.InfoBar():Message("ERROR: LLM "..command_type_str..": active_cursor.CurSelection is invalid."); return end
        local sel_start_ptr = active_cursor.CurSelection[1]; local sel_end_ptr = active_cursor.CurSelection[2]
        if command_type_str == "modify" then
            job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
            job_state.selection_to_remove_start_loc_ptr = buffer_pkg.Loc(sel_start_ptr.X, sel_start_ptr.Y)
            job_state.selection_to_remove_end_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
            micro.Log("LLM_DEBUG: Using selection for modify. Insert at sel_start, remove sel_start to sel_end.")
        elseif command_type_str == "generate" then
            job_state.insertion_loc_ptr = buffer_pkg.Loc(sel_end_ptr.X, sel_end_ptr.Y)
            micro.Log("LLM_DEBUG: Selection present for generate; will insert AFTER selection.")
        end
        local sel_bytes = active_cursor:GetSelection(); if sel_bytes then selected_text_content = util.String(sel_bytes) end
        micro.Log("LLM_DEBUG: Selected text (len " .. string.len(selected_text_content) .. ") present for " .. command_type_str .. " command.")
    else
        if command_type_str == "modify" then micro.InfoBar():Message("ERROR: LLM Modify: No text selected to modify."); return end
        job_state.insertion_loc_ptr = buffer_pkg.Loc(active_cursor.X, active_cursor.Y)
        micro.Log("LLM_DEBUG: No selection for " .. command_type_str .. ", will insert at cursor X="..active_cursor.X ..", Y="..active_cursor.Y)
    end
    
    local ref_loc_for_context = job_state.insertion_loc_ptr
    local current_context_ref_line = ref_loc_for_context.Y
    local lines_of_context = 30; local context_before_text = ""; local context_after_text = ""
    -- Context gathering from your original script
    if current_context_ref_line > 0 then
        local context_start_line = math.max(0, current_context_ref_line - lines_of_context)
        local actual_context_end_line = current_context_ref_line - 1
        if actual_context_end_line >= context_start_line then
            local context_start_loc = buffer_pkg.Loc(0, context_start_line)
            local end_line_str_ctx = current_buffer:Line(actual_context_end_line)
            local context_end_loc = buffer_pkg.Loc(string.len(end_line_str_ctx), actual_context_end_line)
            local ctx_bytes = current_buffer:Substr(context_start_loc, context_end_loc); if ctx_bytes then context_before_text = util.String(ctx_bytes) end
        end
    end
    local total_lines_in_buffer = current_buffer:LinesNum()
    local reference_end_line_for_context_after
    if command_type_str == "modify" and job_state.selection_to_remove_end_loc_ptr then reference_end_line_for_context_after = job_state.selection_to_remove_end_loc_ptr.Y
    else reference_end_line_for_context_after = ref_loc_for_context.Y end
    if reference_end_line_for_context_after < total_lines_in_buffer - 1 then
        local context_start_line = reference_end_line_for_context_after + 1
        local context_end_line = math.min(total_lines_in_buffer - 1, reference_end_line_for_context_after + lines_of_context)
        if context_start_line <= context_end_line then
            local context_start_loc = buffer_pkg.Loc(0, context_start_line)
            local end_line_str_ctx = current_buffer:Line(context_end_line)
            local context_end_loc = buffer_pkg.Loc(string.len(end_line_str_ctx), context_end_line)
            local ctx_bytes = current_buffer:Substr(context_start_loc, context_end_loc); if ctx_bytes then context_after_text = util.String(ctx_bytes) end
        end
    end
    micro.Log("LLM_DEBUG: Context gathered for " .. command_type_str .. ".")

    local full_prompt_to_llm
    -- Using your original prompt structures
    if command_type_str == "generate" then
        -- If selected_text_content is not empty, it means user selected text.
        -- The system prompt for generate will guide how to use this optional context.
        full_prompt_to_llm = string.format(
            "USER_REQUEST: %s\n\nEDITOR_CONTEXT (OPTIONAL):\n%s\n\nCONTEXT_AROUND_CURSOR_BEFORE:\n%s\n\nCONTEXT_AROUND_CURSOR_AFTER:\n%s",
            user_llm_request, selected_text_content, context_before_text, context_after_text
        )
    else -- modify
         full_prompt_to_llm = string.format(
            "USER_REQUEST: %s\n\nCONTEXT_BEFORE_SELECTION:\n%s\n\nSELECTED_TEXT_TO_MODIFY:\n%s\n\nCONTEXT_AFTER_SELECTION:\n%s",
            user_llm_request, context_before_text, selected_text_content, context_after_text
        )
    end
    micro.Log("LLM_DEBUG: Full prompt for LLM (" .. command_type_str .. "):\n" .. full_prompt_to_llm)

    job_state.temp_file_path = path.Join(config.ConfigDir, "llm_job_prompt.txt")
    local err_write = ioutil.WriteFile(job_state.temp_file_path, full_prompt_to_llm, 384) 
    if err_write ~= nil then micro.InfoBar():Message("ERROR: LLM "..command_type_str..": Failed write temp prompt: "..tostring(err_write)); if job_state.temp_file_path then pcall(os.Remove,job_state.temp_file_path);job_state.temp_file_path=nil;end; return end
    micro.Log("LLM_DEBUG: Temp file written: " .. job_state.temp_file_path .. " (perms 384)")

    local llm_parts = {"cat", job_state.temp_file_path, "|", "llm"}
    local current_system_prompt_text_to_use
    local sys_prompt_src = "unknown"

    if custom_system_prompt_arg then
        current_system_prompt_text_to_use = custom_system_prompt_arg
        sys_prompt_src = "-s arg"
    elseif template_name_arg then
        -- If -t is used, it overrides default and hardcoded. LLM CLI handles -t directly.
        table.insert(llm_parts, "-t"); table.insert(llm_parts, escapeShellArg(template_name_arg))
        sys_prompt_src = "-t " .. template_name_arg
        -- No need to set current_system_prompt_text_to_use if -t is directly passed to llm cli
    else
        local def_tpl_key = "llm_default_"..command_type_str.."_template"; local def_tpl = config.GetGlobalOption(def_tpl_key)
        if def_tpl and #def_tpl > 0 then
            -- If default template is set, use it with -t
            table.insert(llm_parts, "-t"); table.insert(llm_parts, escapeShellArg(def_tpl))
            sys_prompt_src = "default template " .. def_tpl
        else 
            -- Fallback to hardcoded system_prompts
            current_system_prompt_text_to_use = system_prompts[command_type_str]
            sys_prompt_src = "hardcoded"
            if not current_system_prompt_text_to_use then micro.InfoBar():Message("ERR: No sys prompt for "..command_type_str); if job_state.temp_file_path then pcall(os.Remove,job_state.temp_file_path);job_state.temp_file_path=nil;end; return end
        end
    end

    -- If current_system_prompt_text_to_use was set (from -s or hardcoded), add it.
    -- If -t was used, this block is skipped as -t is already in llm_parts.
    if current_system_prompt_text_to_use and not template_name_arg and not (sys_prompt_src:find("default template")) then
        table.insert(llm_parts, "-s"); table.insert(llm_parts, escapeShellArg(current_system_prompt_text_to_use))
    end
    
    micro.Log("LLM_DEBUG: Sys prompt source: "..sys_prompt_src); 
    table.insert(llm_parts,"-x"); micro.Log("LLM_DEBUG: Added -x flag."); 
    table.insert(llm_parts,"-")
    
    local cmd = table.concat(llm_parts, " "); job_state.original_command = cmd
    micro.InfoBar():Message("LLM "..command_type_str..": Starting job..."); micro.Log("LLM_DEBUG: Starting job: "..cmd)
    local job, err = shell.JobStart(cmd, handleJobStdout, handleJobStderr, handleJobExit, {})
    if err ~= nil then micro.InfoBar():Message("ERR: LLM "..command_type_str..": JobStart fail: "..tostring(err)); if job_state.temp_file_path then pcall(os.Remove,job_state.temp_file_path);job_state.temp_file_path=nil;end
    elseif not job then micro.InfoBar():Message("ERR: LLM "..command_type_str..": JobStart nil obj"); if job_state.temp_file_path then pcall(os.Remove,job_state.temp_file_path);job_state.temp_file_path=nil;end end
    micro.Log("LLM_DEBUG: LLM Job ("..command_type_str..") started.")
end

function llmModifyCommand(bp, args) startLLMJob(bp, args, "modify") end
function llmGenerateCommand(bp, args) startLLMJob(bp, args, "generate") end

local function handleLLMTemplateBufferSave(bp)
    local buf = bp.Buf; local name = buf:GetOption("llm_template_target_name")
    if not name or #name == 0 then micro.Log("LLM_ERR: No target_name on template buf save"); micro.InfoBar():Message("ERR: No template name for buf."); return true end
    local content = buf:String(); if string.gsub(content,"%s","")=="" then micro.InfoBar():Message("Template empty. Not saving."); return true end
    local cmd_parts = {"llm","-s",escapeShellArg(content),"--save",escapeShellArg(name)}; local cmd_str = table.concat(cmd_parts," ")
    micro.Log("LLM_DEBUG: Saving template: "..cmd_str)
    local _, stdout, stderr, err = shell.Run(cmd_str)
    if err~=nil or (stderr and #stderr>0 and not string.find(stderr,"template already exists")) then local msg="Fail save LLM tpl '"..name.."'. "; if stderr and #stderr>0 then msg=msg.."LLM Stderr: "..stderr else msg=msg.."Err: "..tostring(err) end; micro.InfoBar():Message(msg); micro.Log("LLM_ERR: "..msg.." Cmd: "..cmd_str)
    else micro.InfoBar():Message("LLM Tpl '"..name.."' saved/updated."); micro.Log("LLM_DEBUG: Tpl '"..name.."' saved. LLM Stdout: "..(stdout or "N/A")) end
    buf:SetDirty(false); return true
end

function llmTemplateCommand(bp, args)
    if #args~=1 or #args[1]==0 then micro.InfoBar():Message("Usage: llm_template <name>"); return end
    local name=args[1]; local content=getLLMTemplateContent(name); local buf_content=""; local msg="Editing new LLM tpl '"..name.."'. Save (Ctrl+S)."
    if content then buf_content=content; msg="Editing LLM tpl '"..name.."'. Save (Ctrl+S)." else buf_content="-- Sys prompt for LLM tpl: "..name.."\n" end
    local fname="llm_edit_"..name..".llm-tpl.txt"; local dir=path.Join(config.ConfigDir,"llm_plugin_tpl_bufs")
    pcall(function() local _,e=os.MkdirAll(dir,0755); if e~=nil then micro.Log("LLM_WARN: MkdirAll fail: "..dir.." Err: "..tostring(e)) end end)
    local buf_path=path.Join(dir,fname); local new_buf=buffer_pkg.NewBufferFromString(buf_content,buf_path)
    new_buf:SetOption("llm_template_target_name",name); new_buf:SetOption("onSave",handleLLMTemplateBufferSave)
    new_buf.Settings["syntax"]=true; new_buf.Settings["filetype"]="markdown"
    local tab_group=micro.CurPane().Parent
    if not tab_group then bp:OpenBuffer(new_buf) else local tab=tab_group:NewTab(true); tab:SetBuffer(new_buf) end
    micro.InfoBar():Message(msg)
end

function llmTemplateDefaultCommand(bp, args)
    if #args==0 then args={"--show"} end
    if args[1]=="--show" then local g=config.GetGlobalOption("llm_default_generate_template") or "N/A"; local m=config.GetGlobalOption("llm_default_modify_template") or "N/A"; micro.InfoBar():Message("Defaults -- Gen: "..g.." | Mod: "..m); return end
    if args[1]=="--clear" then if #args~=2 or not (args[2]=="generate" or args[2]=="modify") then micro.InfoBar():Message("Usage: llm_template_default --clear <generate|modify>"); return end
        config.SetGlobalOption("llm_default_"..args[2].."_template",nil); micro.InfoBar():Message("Default LLM tpl for '"..args[2].."' cleared.")
    else if #args~=2 or not (args[2]=="generate" or args[2]=="modify") then micro.InfoBar():Message("Usage: llm_template_default <name> <generate|modify>"); return end
        if not getLLMTemplateContent(args[1]) then micro.InfoBar():Message("ERR: LLM Tpl '"..args[1].."' not found."); micro.Log("LLM_ERR: Set non-existent tpl '"..args[1].."' as default for "..args[2]); return end
        config.SetGlobalOption("llm_default_"..args[2].."_template",args[1]); micro.InfoBar():Message("Default LLM tpl for '"..args[2].."' set to: "..args[1])
    end
end

function init()
    micro.Log("LLM_DEBUG: LLM Plugin initializing (User Original Base + Features)...")
    config.MakeCommand("llm_modify", llmModifyCommand, config.NoComplete)
    config.MakeCommand("llm_generate", llmGenerateCommand, config.NoComplete)
    config.MakeCommand("llm_template", llmTemplateCommand, config.NoComplete)
    config.MakeCommand("llm_template_default", llmTemplateDefaultCommand, config.NoComplete)
    micro.InfoBar():Message("LLM Plugin: Commands loaded.")
end
