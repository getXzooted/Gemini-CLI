#!/bin/bash
#
# install-gemini-tools.sh
# Installs and configures a suite of command-line AI tools using the Gemini API.
# This includes 'ask', 'code-assist', and a 'git aic' helper.
#

set -e

# --- Configuration & Constants ---
CONFIG_DIR="/etc/gemini-tools"
CONFIG_FILE="${CONFIG_DIR}/config"
FUNCTIONS_FILE="/usr/local/bin/gemini_functions.sh"
# Detect the home directory of the user who invoked sudo
CALLING_USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
BASHRC_PATH="${CALLING_USER_HOME}/.bashrc"

# --- Script Start ---
echo "  ---------> Starting Gemini Tools Installer <---------  "
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Please use 'sudo'."
    exit 1
fi

echo "  ---------> Installing prerequisites (curl, jq) <---------  "
apt-get update && apt-get install -y --fix-broken curl jq

# --- API Key Setup ---
echo "  ---------> Setting up Gemini API Key <---------  "
mkdir -p "$CONFIG_DIR"
read -p "Please enter your Gemini API Key: " GEMINI_API_KEY
# Store the API key in a secure, root-owned config file
echo "GEMINI_API_KEY='${GEMINI_API_KEY}'" > "$CONFIG_FILE"
# Set permissions to be world-readable, but only root-writable
chmod 644 "$CONFIG_FILE"
echo "API Key saved to ${CONFIG_FILE}"

# --- Function Installation ---
echo "  ---------> Creating AI command functions <---------  "

# Use a HEREDOC to write the functions to a file. This is clean and easy to read.
cat > "$FUNCTIONS_FILE" << 'EOF'
#!/bin/bash
#
# /usr/local/bin/gemini_functions.sh
# This file contains the core functions for the command-line AI tools.
# It is sourced by the user's .bashrc file.
#

# Load the API key from the central config file
if [ -f /etc/gemini-tools/config ]; then
    source /etc/gemini-tools/config
fi

# General-purpose 'ask' command using 2.5 Flash with thinking disabled for speed.
ask() {
    local model="gemini-2.5-flash"
    local prompt_text="$*"
    local json_payload

    json_payload=$(printf '{
      "contents": [ { "parts": [ { "text": "%s" } ] } ],
      "generationConfig": { "thinkingConfig": { "thinkingBudget": 0 } }
    }' "$prompt_text")

    curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
         -H "x-goog-api-key: $GEMINI_API_KEY" \
         -H 'Content-Type: application/json' \
         -X POST \
         -d "${json_payload}" | jq -r '.candidates[0].content.parts[0].text'
}

# Powerful 'code-assist' command that analyzes a project directory, a log file, and a prompt.
code-assist() {
    local model="gemini-2.5-pro"
    local project_dir="$1"
    local user_prompt="${*:2}"
    local project_context
    local log_context
    local final_prompt

    if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
        echo "Error: Please provide a valid project directory as the first argument."
        echo "Usage: cat error.log | code-assist /path/to/project \"Your prompt\""
        return 1
    fi

    echo "## Analyzing project files in $project_dir..." >&2
    project_context=$(find "$project_dir" -type f \
        -not -path '*/.git/*' -not -path '*/node_modules/*' \
        -not -path '*/dist/*' -not -path '*/build/*' -not -name '*.lock' \
        -exec sh -c 'echo "\n--- FILE: {} ---"; cat {};' \;)

    if [ ! -t 0 ]; then
        log_context=$(cat)
    fi

    final_prompt="Analyze the following information to solve the user's request.

--- FULL PROJECT CONTEXT ---
${project_context}

--- LOG FILE / ERROR OUTPUT ---
${log_context:-"No log file provided."}

--- USER REQUEST ---
${user_prompt}
"
    local json_payload
    json_payload=$(jq -n --arg text "$final_prompt" '{contents: [{parts: [{text: $text}]}]}')

    echo "## Sending context to Gemini 2.5 Pro. Please wait..." >&2
    curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
         -H "x-goog-api-key: $GEMINI_API_KEY" \
         -H 'Content-Type: application/json' \
         -X POST \
         -d "${json_payload}" | jq -r '.candidates[0].content.parts[0].text'
}

# Helper for git commits using 2.5 Flash with thinking disabled for speed.
aic_helper() {
    local model="gemini-2.5-flash"
    local piped_diff=$(cat)
    local prompt_text="Write a concise git commit message in the conventional commit format for the following changes. Only output the commit message itself, nothing else:\n\n${piped_diff}"
    local json_payload

    json_payload=$(printf '{
      "contents": [ { "parts": [ { "text": "%s" } ] } ],
      "generationConfig": { "thinkingConfig": { "thinkingBudget": 0 } }
    }' "$prompt_text")

    curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
         -H "x-goog-api-key: $GEMINI_API_KEY" \
         -H 'Content-Type: application/json' \
         -X POST \
         -d "${json_payload}" | jq -r '.candidates[0].content.parts[0].text'
}

EOF

# Make the functions script executable (good practice)
chmod +x "$FUNCTIONS_FILE"
echo "AI functions created at ${FUNCTIONS_FILE}"

# --- Shell Configuration ---
echo "  ---------> Configuring shell environment (.bashrc) <---------  "

# Add sourcing line to .bashrc if it's not already there
if ! grep -q "source ${FUNCTIONS_FILE}" "${BASHRC_PATH}"; then
    echo -e "\n# Source for Gemini AI Command-Line Tools" >> "${BASHRC_PATH}"
    echo "if [ -f ${FUNCTIONS_FILE} ]; then" >> "${BASHRC_PATH}"
    echo "    source ${FUNCTIONS_FILE}" >> "${BASHRC_PATH}"
    echo "fi" >> "${BASHRC_PATH}"
    echo "Configuration added to ${BASHRC_PATH}"
else
    echo "Configuration already exists in ${BASHRC_PATH}"
fi

# --- Git Configuration ---
echo "  ---------> Configuring Git alias 'aic' <---------  "
# Run git config as the original user to set it up for them
sudo -u "${SUDO_USER:-$USER}" git config --global alias.aic '!f() { git diff --staged | aic_helper | git commit -F -; }; f'
echo "Git alias 'aic' created."

# --- Final Message ---
echo "----------------------------------------------------------------"
echo " SUCCESS: Gemini AI Tools installation complete!"
echo ""
echo " Please close and reopen your terminal or run the following command:"
echo "   source ~/.bashrc"
echo ""
echo " You can now use the following commands:"
echo "   - ask \"Your general question here\""
echo "   - code-assist /path/to/project \"Your coding question\""
echo "   - git aic (after staging files with 'git add')"
echo "----------------------------------------------------------------"
