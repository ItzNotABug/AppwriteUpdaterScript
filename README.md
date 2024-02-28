# Appwrite Updater Script 🚀

Update & Migrate your Appwrite instance sequentially with a small script 🌟!

### Features 🌈

- **Updates**: Fetch and apply the latest Appwrite version seamlessly.
- **Version Selection**: Choose a specific version to update to, with a default to the latest.
- **Sequential Version Migration**: If you select a version several releases ahead, the script updates version by version, ensuring proper migration of the internal dataset
  and databases for each incremental update.
- **Migration Management**: Run migrations post-update.
- **Space Cleanup**: Remove previous Docker image to free up space.

### Prerequisites 🛠️

- Docker / Docker Desktop
- `jq` for JSON processing

### Quick Start 🚀

1. **Navigate to the correct folder**:\
   Navigate to where your `appwrite` folder is.
   Directory structure is same as `appwrite` requires -

   ```text
   parent_directory <= you run the commands in this directory
   └── appwrite
       └── docker-compose.yml
   ```

2. **Get the script**:
   ```bash
   curl -o appwrite-updater.sh https://raw.githubusercontent.com/ItzNotABug/AppwriteUpdaterScript/master/appwrite-updater.sh && chmod +x appwrite-updater.sh
   ```

3. **Run the Script**:
   ```bash
   ./appwrite-updater.sh
   ```

   Follow the prompts to select the version you wish to update to. If no input is provided, the script defaults to the latest version.

### Contributing 🤝

Contributions are welcome! Feel free to fork, improve, and submit a pull request.

### Disclaimer ⚠️

This script is independently maintained and not an official appwrite product. Use at your own risk.

---

**Note: The script is tested on a Mac system only.**
