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


https://github.com/user-attachments/assets/a44f402a-405c-4997-b514-3136961bdcde




This plugin provides commands accessible via Micro's command prompt (`Ctrl+E`):

### Core Command: `llm`

This is the primary command for interacting with an LLM. It intelligently adapts its behavior based on whether text is selected.

*   **Syntax:** `llm [options] <your request>`

*   **Behavior:**
    *   **If text is selected:** The command operates in **"modify"** mode.
        *   Your `<prompt>`, the selected text, and surrounding context are sent to the LLM.
        *   The LLM's response **replaces** the originally selected text.
        *   *Example:* Select faulty code, run `llm fix this code`.
    *   **If NO text is selected:** The command operates in **"generate"** mode.
        *   Your `<prompt>` and surrounding context are sent to the LLM.
        *   The LLM's response is **inserted** at the cursor position.
        *   *Example:* Place cursor on empty line, run `llm write a python function that sums two numbers`.

*   **How to use:**
    1.  (Optional) Select text if you want to modify it or provide it as specific context for generation.
    2.  Position your cursor appropriately (start of selection for modify, insertion point for generate).
    3.  Press `Ctrl+E` to open the command prompt.
    4.  Type `llm` followed by your specific request (e.g., `llm fix grammar`, `llm write a docstring for the function below`).
    5.  (Optional) Add [options](#options-for-llm) like `-t <template_name>` or `-s "<custom system prompt>"` **before** your request.
    6.  Press Enter.



#### Options for `llm`:

The `llm` command accepts the following optional flags, which should precede your main textual request:

*   `-t <template_name>` or `--template <template_name>`: Use a specific LLM CLI template. The `llm` CLI tool must be aware of this template (see [LLM Templates documentation](https://llm.datasette.io/en/stable/templates.html)).
*   `-s "<custom_system_prompt>"` or `--system "<custom_system_prompt>"`: Provide a custom system prompt directly, enclosed in quotes. This overrides any default or template-based system prompt.

#### System Prompt Precedence:

The system prompt used for the LLM call follows this order:

1.  Custom system prompt provided via `-s` or `--system` flag.
2.  System prompt from an LLM template specified via `-t` or `--template` flag.
3.  System prompt from the plugin's single default template set via `llm_template_default` (see below).
4.  The plugin's built-in default system prompt corresponding to the detected operation mode ("modify" or "generate").

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

#### 2. `llm_template_default`

Manages the single default LLM template used by the `llm` command when no `-t` or `-s` flag is provided.

*   **Set Default:** `llm_template_default <template_name>`
    *   Sets `<template_name>.yaml` as the default template for all `llm` command invocations.
    *   *Example:* `llm_template_default my_universal_helper`
    *   The plugin verifies if the template file exists and is readable before setting it.

*   **Clear Default:** `llm_template_default --clear`
    *   Clears the default template setting. The plugin will revert to using its built-in system prompts based on the operation mode ("modify" or "generate") if no `-t` or `-s` flag is used.

*   **Show Default:** `llm_template_default --show`
    *   Displays the currently set default template.
    *   Output will be shown in the infobar, e.g., `Default LLM template: my_universal_helper` or `Default LLM template: Not set`.



## Configuration

You can configure the plugin by setting global options in Micro's `settings.json` file (`Ctrl+E` then `set`).

*   `"llm.default_template": ""` (string):
    *   Specifies the name (without `.yaml`) of an LLM template to use by default for the `llm` command if no `-t` or `-s` flag is provided.
    *   Set to `""` (empty string) to have no default template (uses built-in prompts).
    *   Example: `"llm.default_template": "my_default"`

*   `"llm.context_lines": 100` (number):
    *   Specifies how many lines of context before and after the cursor/selection should be sent to the LLM.
    *   Set to `0` to disable sending context.
    *   Default is `100`.
    *   Example: `"llm.context_lines": 50`

**Example `settings.json`:**

```json
{
    "llm.context_lines": 50,
    "llm.default_template": "my_refactor_template"
}
