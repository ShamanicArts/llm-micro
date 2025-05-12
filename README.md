# llm-micro

Integrates Simon Willison's [LLM CLI](https://github.com/simonw/llm) with the [Micro editor](https://github.com/zyedidia/micro).
This plugin allows you to leverage Large Language Models directly within Micro for text generation, modification, and custom-defined tasks through templates.

## Prerequisites

*   **Micro Text Editor:** Installed and working.
*   **LLM CLI Tool:** Installed and configured (e.g., with API keys). See [LLM documentation](https://llm.datasette.io/en/stable/). Ensure that the `llm` command is accessible in your system's PATH.

## Installation

To install the `llm-micro` plugin, use Micro's standard plugin directory:

1.  Open your terminal.
2.  Ensure Micro's plugin directory exists and clone the repository:
    ```bash
    # Micro typically creates ~/.config/micro/plug/. This command ensures it exists.
    mkdir -p ~/.config/micro/plug
    # Clone the plugin into the 'llm' subdirectory (or your preferred name)
    git clone https://github.com/shamanicvocalarts/llm-micro ~/.config/micro/plug/llm
    ```
3.  Restart Micro. It should automatically detect and load the plugin. The plugin registers its options on startup.

## Usage

This plugin provides commands accessible via Micro's command prompt (`Ctrl+E`):

### Core Commands: `llm_modify` and `llm_generate`

These commands allow you to interact with an LLM for text manipulation.

#### 1. `llm_modify [options] <your request>`

<https://github.com/user-attachments/assets/3b670332-30a1-4c35-8408-34c9f9d4fbe9>

This command modifies the currently selected text based on your instructions.

*   **How to use:**
    1.  Select the text you want to modify in Micro.
    2.  Press `Ctrl+E` to open the command prompt.
    3.  Type `llm_modify` followed by your specific request (e.g., `llm_modify fix grammar`, `llm_modify convert to uppercase`).
    4.  (Optional) Add [options](#options-for-llm_modify-and-llm_generate) like `-t <template_name>` or `-s "<custom system prompt>"` before your request.
    5.  Press Enter.
*   **Behavior:**
    *   The selected text, your request, and surrounding context are sent to the LLM.
    *   The LLM's response replaces the originally selected text.
    *   **An error will occur if no text is selected.**

#### 2. `llm_generate [options] <your request>`

This command generates new text based on your instructions and optional context.

*   **How to use:**
    1.  (Optional) Select text if you want to provide it as specific context.
    2.  Position your cursor where you want the new text inserted.
    3.  Press `Ctrl+E`.
    4.  Type `llm_generate` followed by your request (e.g., `llm_generate write a python function that sums two numbers`).
    5.  (Optional) Add [options](#options-for-llm_modify-and-llm_generate) like `-t <template_name>` or `-s "<custom system prompt>"` before your request.
    6.  Press Enter.
*   **Behavior:**
    *   Your request, any selected text, and surrounding context are sent to the LLM.
    *   If text was selected, generated text is inserted *after* the selection.
    *   If no text was selected, generated text is inserted at the cursor.

#### Options for `llm_modify` and `llm_generate`:

Both commands accept the following optional flags, which should precede your main textual request:

*   `-t <template_name>` or `--template <template_name>`: Use a specific LLM CLI template. The `llm` CLI tool must be aware of this template (see [LLM Templates documentation](https://llm.datasette.io/en/stable/templates.html)).
*   `-s "<custom_system_prompt>"` or `--system "<custom_system_prompt>"`: Provide a custom system prompt directly, enclosed in quotes. This overrides any default or template-based system prompt.

**System Prompt Precedence:**
The system prompt used for the LLM call follows this order:
1.  Custom system prompt provided via `-s` or `--system` flag.
2.  System prompt from an LLM template specified via `-t` or `--template` flag.
3.  System prompt from a plugin default template set via `llm_template_default` (see below).
4.  The plugin's built-in default system prompt for "modify" or "generate".

### Template Management Commands

This plugin allows you to manage and use LLM CLI templates. Templates are stored as YAML files in the directory reported by `llm templates path` (typically `~/.config/io.datasette.llm/templates/`).

#### 1. `llm_template <template_name>`

Opens an LLM template YAML file for editing directly within Micro.

*   **How to use:**
    1.  Press `Ctrl+E`.
    2.  Type `llm_template <template_name>` (e.g., `llm_template my_summary_template`). Do not include `.yaml`.
    3.  Press Enter.
*   **Behavior:**
    *   If `<template_name>.yaml` exists in your `llm` templates directory, it will be opened in a new tab.
    *   If it doesn't exist, a new buffer will be opened, and saving it (`Ctrl+S`) will create `<template_name>.yaml` in that directory.
    *   You are responsible for the correct YAML structure of the template (e.g., `system: "..."` or `prompt: "..."`). Refer to the [LLM Templates documentation](https://llm.datasette.io/en/stable/templates.html).

#### 2. `llm_template_default <template_name> <generate|modify>`

Sets a specific LLM template as the default for either `llm_generate` or `llm_modify` commands when no `-t` or `-s` flag is provided.

*   **How to use (set):**
    *   `llm_template_default my_custom_writer generate` (sets `my_custom_writer.yaml` as default for `llm_generate`)
    *   `llm_template_default my_code_refactor modify` (sets `my_code_refactor.yaml` as default for `llm_modify`)
*   The plugin will verify if the template file exists and is readable before setting it as a default.

#### 3. `llm_template_default --clear <generate|modify>`

Clears the default template for the specified command type, reverting to the plugin's built-in system prompts if no `-t` or `-s` is used.

*   **How to use (clear):**
    *   `llm_template_default --clear generate`
    *   `llm_template_default --clear modify`

#### 4. `llm_template_default --show`

Displays the currently set default templates for `generate` and `modify`.

*   **How to use (show):**
    *   `llm_template_default --show`
    *   Output will be shown in the infobar, e.g., "Defaults -- Generate: my_custom_writer | Modify: Not set (uses built-in)".

**Important Notes for All Commands:**

*   The plugin sends context (lines before and after the selection/cursor) to the LLM.
*   The `-x` flag is automatically added to `llm` CLI calls to attempt to extract raw text/code from Markdown fenced blocks if the LLM outputs them.
*   You will see messages in Micro's infobar indicating the progress and outcome.
*   Debug logs are available via Micro's logging (`Ctrl+E` then `log`). These logs are very helpful for troubleshooting.

---
Contributions and feedback are welcome!
