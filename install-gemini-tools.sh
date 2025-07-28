#!/bin/bash
#
# install-gemini-tools.sh
# Installs and configures Nexus, a suite of command-line AI tools using the Gemini API.
#

set -e

# --- Configuration & Constants ---
CONFIG_DIR="/etc/gemini-tools"
CONFIG_FILE="${CONFIG_DIR}/config"
FUNCTIONS_FILE="/usr/local/bin/gemini_functions.sh"
NEXUS_COMMAND_PATH="/usr/local/bin/nexus"
GIT_CREDENTIAL_HELPER_PATH="/usr/local/bin/git-credential-nexus"
CALLING_USER="${SUDO_USER:-$USER}"
CALLING_USER_HOME=$(getent passwd "${CALLING_USER}" | cut -d: -f6)
BASHRC_PATH="${CALLING_USER_HOME}/.bashrc"

# --- Script Start ---
echo "  ---------> Starting Nexus AI Tools Installer <---------  "
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
echo "GEMINI_API_KEY='${GEMINI_API_KEY}'" > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"
echo "API Key saved to ${CONFIG_FILE}"

# --- Function Installation ---
echo "  ---------> Creating AI command functions <---------  "

# Create the main 'nexus' command file with subcommands
cat > "$NEXUS_COMMAND_PATH" << 'EOF'
#!/bin/bash
#
# Nexus
# The Nexus AI Command Line Interface and main dispatcher.

set -e

# --- Subcommand Dispatcher ---
case "$1" in
    --version|-v)
        echo "Nexus AI Tools - Version 1.8.0 (Stable)"
        echo "  - ask, code-assist, aic_helper: v1.8.0"
        echo "  - nexus subcommands: v1.6.0"
        exit 0
        ;;

    git-auth)
        # --- Git Authentication Subcommand ---
        if [[ $EUID -ne 0 ]]; then
            echo "ERROR: 'nexus git-auth' must be run with sudo." >&2
            exit 1
        fi

        if [ "$#" -ne 2 ]; then
            echo "Usage: cd /path/to/repo && sudo nexus git-auth <personal_access_token>" >&2
            exit 1
        fi

        TOKEN="$2"
        CALLING_USER="${SUDO_USER:-$USER}"
        CALLING_USER_HOME=$(getent passwd "${CALLING_USER}" | cut -d: -f6)
        NEXUS_CONFIG_DIR="${CALLING_USER_HOME}/.config/nexus"
        GIT_AUTH_CONFIG="${NEXUS_CONFIG_DIR}/git_auth.conf"

        mkdir -p "$NEXUS_CONFIG_DIR"
        touch "$GIT_AUTH_CONFIG"
        chown -R "${CALLING_USER}:${CALLING_USER}" "$NEXUS_CONFIG_DIR"
        chmod 700 "$NEXUS_CONFIG_DIR"
        chmod 600 "$GIT_AUTH_CONFIG"

        REPO_URL=$(sudo -u "${CALLING_USER}" git config --get remote.origin.url)
        if [ -z "$REPO_URL" ]; then
            echo "Error: Could not find remote.origin.url. Are you inside a Git repository?" >&2
            exit 1
        fi

        sed -i "\|$REPO_URL|d" "$GIT_AUTH_CONFIG"
        echo "repo=${REPO_URL} token=${TOKEN}" >> "$GIT_AUTH_CONFIG"

        echo "--> Successfully associated token with ${REPO_URL}"
        echo "    Authentication is now handled by the Nexus credential helper."
        exit 0
        ;;

    *)
        echo "Nexus AI Tools - A suite of command-line assistants."
        echo "Usage: nexus <command>"
        echo ""
        echo "Commands:"
        echo "  git-auth <token>    Associate a Personal Access Token with the current repository."
        echo "  --version, -v       Show version information."
        echo ""
        echo "See also: ask, code-assist, git aic"
        exit 0
        ;;
esac
EOF

# Create the Git credential helper
cat > "$GIT_CREDENTIAL_HELPER_PATH" << 'EOF'
#!/bin/bash
# git-credential-nexus - Git credential helper for Nexus.
# Reads protocol, host, and path from stdin to find a repo-specific token.
set -e

# Find the config file in the home directory of the user running 'git'
USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
GIT_AUTH_CONFIG="${USER_HOME}/.config/nexus/git_auth.conf"

if [ ! -f "$GIT_AUTH_CONFIG" ]; then
    exit 0
fi

# Git provides key-value pairs on stdin. Read them all.
declare -A git_params
while IFS='=' read -r key value; do
    if [ -n "$key" ]; then
        git_params["$key"]="$value"
    fi
done

protocol=${git_params[protocol]}
host=${git_params[host]}
path=${git_params[path]}

if [ -z "$protocol" ] || [ -z "$host" ] || [ -z "$path" ]; then
    exit 0
fi

REPO_URL="https://${host}/${path}"

TOKEN=$(grep -F "repo=${REPO_URL}" "$GIT_AUTH_CONFIG" | awk -F'token=' '{print $2}' | head -n 1)

if [ -n "$TOKEN" ]; then
    echo "username=token"
    echo "password=${TOKEN}"
fi
EOF

# Create the shell functions file for the AI helpers
cat > "$FUNCTIONS_FILE" << 'EOF'
#!/bin/bash
# /usr/local/bin/gemini_functions.sh - AI helper functions for Nexus.
if [ -f /etc/gemini-tools/config ]; then source /etc/gemini-tools/config; fi
ask() {
    local model="gemini-2.5-flash"; local prompt_text="$*"; local json_payload
    json_payload=$(jq -n --arg text "$prompt_text" '{"contents":[{"parts":[{"text":$text}]}],"generationConfig":{"thinkingConfig":{"thinkingBudget":0}}}')
    curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' -X POST -d "${json_payload}" | jq -r '.candidates[0].content.parts[0].text'
}
code-assist() {
    local model="gemini-2.5-pro"; local project_dir="$1"; local user_prompt="${*:2}"; local project_context; local log_context; local final_prompt
    if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then echo "Error: Invalid project directory." >&2; return 1; fi
    echo "## Analyzing project files in $project_dir..." >&2
    project_context=$(find "$project_dir" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/build/*' -not -name '*.lock' -exec sh -c 'echo "\n--- FILE: {} ---"; cat {};' \;)
    if [ ! -t 0 ]; then log_context=$(cat); fi
    final_prompt="Analyze the following information to solve the user's request.\n\n--- FULL PROJECT CONTEXT ---\n${project_context}\n\n--- LOG FILE / ERROR OUTPUT ---\n${log_context:-"No log file provided."}\n\n--- USER REQUEST ---\n${user_prompt}"
    json_payload=$(jq -n --arg text "$final_prompt" '{contents:[{parts:[{text:$text}]}]}')
    echo "## Sending context to Gemini 2.5 Pro. Please wait..." >&2
    curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' -X POST -d "${json_payload}" | jq -r '.candidates[0].content.parts[0].text'
}
aic_helper() {
    local model="gemini-2.5-flash"; local piped_diff=$(cat); local prompt_text="Write a concise git commit message in the conventional commit format for the following changes. Only output the commit message itself, nothing else:\n\n${piped_diff}"; local json_payload; local api_response; local commit_message
    json_payload=$(jq -n --arg text "$prompt_text" '{"contents":[{"parts":[{"text":$text}]}],"generationConfig":{"thinkingConfig":{"thinkingBudget":0}}}')
    api_response=$(curl -s "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' -X POST -d "${json_payload}")
    commit_message=$(echo "$api_response" | jq -r '.candidates[0].content.parts[0].text')
    if [[ -z "$commit_message" || "$commit_message" == "null" ]]; then
        echo "Error: Failed to generate commit message from API." >&2; echo "API Response:" >&2; echo "$api_response" >&2; exit 1
    else
        echo "$commit_message"
    fi
}
export -f ask code-assist aic_helper
EOF

# Make all scripts executable
chmod +x "$NEXUS_COMMAND_PATH" "$GIT_CREDENTIAL_HELPER_PATH" "$FUNCTIONS_FILE"
chown "${CALLING_USER}:${CALLING_USER}" "$NEXUS_COMMAND_PATH"
chown "${CALLING_USER}:${CALLING_USER}" "$GIT_CREDENTIAL_HELPER_PATH"
chown "${CALLING_USER}:${CALLING_USER}" "$FUNCTIONS_FILE"

echo "AI functions and commands created and configured."

# --- Shell Configuration ---
echo "  ---------> Configuring shell environment (.bashrc) <---------  "
if ! grep -q "source ${FUNCTIONS_FILE}" "${BASHRC_PATH}"; then
    echo -e "\n# Source for Nexus AI Command-Line Tools" >> "${BASHRC_PATH}"
    echo "if [ -f ${FUNCTIONS_FILE} ]; then source ${FUNCTIONS_FILE}; fi" >> "${BASHRC_PATH}"
    echo "Configuration added to ${BASHRC_PATH}"
else
    echo "Configuration already exists in ${BASHRC_PATH}"
fi

# --- Git Configuration ---
echo "  ---------> Configuring Git <---------  "
# Use 'su' to run the git config commands as the original user.
su - "${CALLING_USER}" -c "git config --global alias.aic '!bash -c \"source /usr/local/bin/gemini_functions.sh && git diff --staged | aic_helper | git commit -F -\"'"
su - "${CALLING_USER}" -c "git config --global credential.helper /usr/local/bin/git-credential-nexus"
# **CRITICAL FIX:** Tell Git to send the full path to the credential helper.
su - "${CALLING_USER}" -c "git config --global credential.useHttpPath true"
echo "Git alias 'aic' and credential helper 'nexus' created."

# --- Final Message ---
echo "----------------------------------------------------------------"
echo " SUCCESS: Nexus AI Tools installation complete!"
echo ""
echo " To authorize a repository for passwordless 'git push', run:"
echo "   cd /path/to/your/repo"
echo "   sudo nexus git-auth <your_personal_access_token>"
echo ""
echo " Please close and reopen your terminal or run 'source ~/.bashrc'"
echo "----------------------------------------------------------------"
