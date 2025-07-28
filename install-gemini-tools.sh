grep -q "source ${FUNCTIONS_FILE}" "${BASHRC_PATH}"; then
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
sudo -u "${SUDO_USER:-$USER}" git config --global alias.aic '!f() { git diff --staged | aic_he>
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
