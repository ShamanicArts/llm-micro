# llm-micro

Integrates Simon Willison's [LLM CLI](https://github.com/simonw/llm) with the [Micro editor](https://github.com/zyedidia/micro).

This plugin allows you to leverage Large Language Models directly within Micro for text generation and modification.

## Prerequisites

*   **Micro Text Editor:** Installed and working.
*   **LLM CLI Tool:** Installed and configured (e.g., with API keys). See [LLM documentation](https://llm.datasette.io/en/stable/).

## Installation

To install the `llm-micro` plugin, use Micro's standard plugin directory:

1.  Open your terminal.
2.  Ensure Micro's plugin directory exists and clone the repository:

    ```bash
    # Micro typically creates ~/.config/micro/plug/. This command ensures it exists.
    mkdir -p ~/.config/micro/plug

    # Clone the plugin into the 'llm' subdirectory
    git clone https://github.com/shamanicvocalarts/llm-micro ~/.config/micro/plug/llm
    ```
3.  Restart Micro. It should automatically detect and load the plugin.

## Usage

This plugin provides two main commands, accessible via Micro's command prompt (`Ctrl+E`):






### 1. `llm_modify <your request>`

https://github.com/user-attachments/assets/3b670332-30a1-4c35-8408-34c9f9d4fbe9


This command modifies the currently selected text based on your instructions.

*   **How to use:**
    1.  Select the text you want to modify in Micro.
    2.  Press `Ctrl+E` to open the command prompt.
    3.  Type `llm_modify` followed by your specific request for how the text should be changed (e.g., `llm_modify fix grammar`, `llm_modify convert to uppercase`, `llm_modify rewrite this more formally`).
    4.  Press Enter.
*   **Behavior:**
    *   The selected text, your request, and surrounding context from the document are sent to the LLM.
    *   The LLM's response will replace the originally selected text.
    *   **An error will occur if no text is selected.**

### 2. `llm_generate <your request>`

This command generates new text based on your instructions and optional context.

*   **How to use:**
    1.  (Optional) Select text if you want to provide it as specific context for the generation.
    2.  Position your cursor where you want the new text to be inserted (if no text is selected), or at the end of the selection if text is selected.
    3.  Press `Ctrl+E` to open the command prompt.
    4.  Type `llm_generate` followed by your request for the text to be generated (e.g., `llm_generate write a python function that sums two numbers`, `llm_generate suggest three titles for a blog post about AI`).
    5.  Press Enter.
*   **Behavior:**
    *   Your request, any selected text (as additional context), and surrounding context from the document are sent to the LLM.
    *   If text was selected, the generated text is inserted *after* the selection.
    *   If no text was selected, the generated text is inserted at the current cursor position.

**Important Notes for both commands:**
*   The plugin sends context (lines before and after the selection/cursor) to the LLM.
*   The system prompts used for the LLM aim to get raw text output without Markdown code blocks or extra explanations.
*   You will see messages in Micro's infobar indicating the progress and outcome.
*   Debug logs are available via Micro's logging (`Ctrl+E` then `log`).

---

Contributions and feedback are welcome!
