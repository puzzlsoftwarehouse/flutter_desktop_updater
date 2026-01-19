import Cocoa
import FlutterMacOS

public class DesktopUpdaterPlugin: NSObject, FlutterPlugin {
    func getCurrentVersion() -> String {
        let infoDictionary = Bundle.main.infoDictionary!
        let version = infoDictionary["CFBundleVersion"] as! String
        return version
    }
    
    func restartApp() {
        let fileManager = FileManager.default
        let appBundlePath = Bundle.main.bundlePath
        
        // Update folder is inside the app bundle Contents directory (where Dart saves the files)
        // This matches the path used in lib/src/download.dart: path.join("$savePath/update", filePath)
        // where savePath is the Contents directory
        let updateFolder = (appBundlePath as NSString).appendingPathComponent("Contents/update")
        
        // Get the application-specific Application Support directory for logs
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            print("Bundle identifier not found")
            return
        }
        let appSpecificDir = appSupportDir.appendingPathComponent(bundleIdentifier)
        
        // Create logs directory and manage log rotation
        let logsDir = appSpecificDir.appendingPathComponent("logs")
        try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        // Rotate logs to keep only the 3 most recent ones
        do {
            let logFiles = try fileManager.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.creationDateKey])
                .filter { $0.pathExtension == "log" }
                .sorted { url1, url2 in
                    let date1 = try url1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    let date2 = try url2.resourceValues(forKeys: [.creationDateKey]).creationDate ?? Date.distantPast
                    return date1 > date2
                }
            
            // Remove oldest logs if we have more than 2 (keeping space for the new one)
            if logFiles.count >= 2 {
                for logFile in logFiles[2...] {
                    try? fileManager.removeItem(at: logFile)
                }
            }
        } catch {
            print("Error managing log rotation: \(error)")
        }
        
        let logFile = logsDir.appendingPathComponent("update_\(Int(Date().timeIntervalSince1970)).log")
        
        guard let executablePath = Bundle.main.executablePath else {
            print("Executable path not found")
            return
        }

        // Verify update folder exists before proceeding
        var isDir: ObjCBool = false
        let updateFolderExists = fileManager.fileExists(atPath: updateFolder, isDirectory: &isDir)
        
        print("=== Update Process Debug Info ===")
        print("App Bundle Path: \(appBundlePath)")
        print("Executable Path: \(executablePath)")
        print("Update folder path: \(updateFolder)")
        print("Update folder exists: \(updateFolderExists)")
        if updateFolderExists {
            print("Update folder is directory: \(isDir.boolValue)")
            if let contents = try? fileManager.contentsOfDirectory(atPath: updateFolder) {
                print("Update folder contains \(contents.count) items")
                if contents.count > 0 {
                    print("First few items: \(contents.prefix(5).joined(separator: ", "))")
                }
            }
        } else {
            print("WARNING: Update folder does not exist!")
            print("Checking if Contents directory exists...")
            let contentsPath = (appBundlePath as NSString).appendingPathComponent("Contents")
            if fileManager.fileExists(atPath: contentsPath, isDirectory: &isDir) && isDir.boolValue {
                print("Contents directory exists")
                if let contents = try? fileManager.contentsOfDirectory(atPath: contentsPath) {
                    print("Contents directory has \(contents.count) items: \(contents.joined(separator: ", "))")
                }
            } else {
                print("Contents directory does not exist!")
            }
        }
        print("Log file path: \(logFile.path)")
        print("=================================")

        // Path to temporary script location
        let scriptPath = NSTemporaryDirectory() + "update_and_restart.sh"

        // Shell script content
        let scriptContent = """
        #!/bin/bash
        APP_BUNDLE_PATH="$1"
        UPDATE_FOLDER_PATH="$2"
        EXECUTABLE_PATH="$3"
        LOG_FILE="$4"

        # Función para logging
        log_message() {
            local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
            echo "$message" | tee -a "$LOG_FILE"
        }

        log_message "Starting update process..."
        log_message "App Bundle Path: $APP_BUNDLE_PATH"
        log_message "Update Folder Path: $UPDATE_FOLDER_PATH"
        log_message "Executable Path: $EXECUTABLE_PATH"
        log_message "Log File: $LOG_FILE"

        # Check if we're in debug or release mode
        if [[ "$APP_BUNDLE_PATH" == *"/Debug/"* ]]; then
            log_message "Running in debug mode - skipping signature verification"
            IS_DEBUG=true
        else
            log_message "Running in release mode - verifying signatures"
            IS_DEBUG=false
        fi

        # Verify that the update folder exists and has content
        if [ ! -d "$UPDATE_FOLDER_PATH" ]; then
            log_message "ERROR: Update folder does not exist: $UPDATE_FOLDER_PATH"
            log_message "  Current working directory: $(pwd)"
            log_message "  User: $(whoami)"
            log_message "  App Bundle Path: $APP_BUNDLE_PATH"
            log_message "  Checking if Contents directory exists:"
            ls -ld "$APP_BUNDLE_PATH/Contents" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Checking Contents directory contents:"
            ls -la "$APP_BUNDLE_PATH/Contents" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Parent directory permissions:"
            ls -ld "$(dirname "$UPDATE_FOLDER_PATH")" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Attempting to find update folder in alternative locations..."
            log_message "  Checking if update folder exists in Application Support:"
            if [ -d "$HOME/Library/Application Support/$(basename "$APP_BUNDLE_PATH" .app)/updates/update" ]; then
                log_message "    Found alternative location: $HOME/Library/Application Support/$(basename "$APP_BUNDLE_PATH" .app)/updates/update"
            fi
            exit 1
        fi
        log_message "Update folder contents:"
        ls -la "$UPDATE_FOLDER_PATH" | tee -a "$LOG_FILE"

        # Verify there are files to update
        UPDATE_FILES_COUNT=$(ls -1 "$UPDATE_FOLDER_PATH" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$UPDATE_FILES_COUNT" -eq 0 ]; then
            log_message "ERROR: Update folder is empty"
            log_message "  Update folder path: $UPDATE_FOLDER_PATH"
            exit 1
        fi
        log_message "Found $UPDATE_FILES_COUNT files/directories to update"

        # Function to check if the application is running
        is_app_running() {
            pgrep -f "$EXECUTABLE_PATH" > /dev/null
            return $?
        }

        # Terminate the current application gracefully
        log_message "Terminating current application instance..."
        APP_PID=$(pgrep -f "$EXECUTABLE_PATH")
        if [ ! -z "$APP_PID" ]; then
            log_message "Found application with PID: $APP_PID"
            kill -TERM $APP_PID
            sleep 2
            if is_app_running; then
                log_message "Application still running, sending SIGKILL..."
                kill -KILL $APP_PID
                sleep 1
            fi
        else
            log_message "No running instance found"
        fi

        # Wait for the application to close
        TIMEOUT=10
        COUNT=0
        while is_app_running && [ $COUNT -lt $TIMEOUT ]; do
            sleep 1
            COUNT=$((COUNT + 1))
            log_message "Waiting for application to close... ($COUNT/$TIMEOUT)"
        done

        if is_app_running; then
            log_message "ERROR: Application failed to close after $TIMEOUT seconds"
            exit 1
        fi
        log_message "Application terminated successfully"

        # Verify that the original bundle exists
        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "ERROR: Original bundle does not exist: $APP_BUNDLE_PATH"
            log_message "  Current directory: $(pwd)"
            log_message "  Directory listing:"
            ls -la "$(dirname "$APP_BUNDLE_PATH")" 2>&1 | tee -a "$LOG_FILE" || true
            exit 1
        fi

        # Check disk space before proceeding
        log_message "Checking available disk space..."
        UPDATE_SIZE=$(du -sk "$UPDATE_FOLDER_PATH" 2>/dev/null | awk '{print $1}')
        AVAILABLE_SPACE=$(df -k "$APP_BUNDLE_PATH" | tail -1 | awk '{print $4}')
        log_message "  Update size: ${UPDATE_SIZE}KB"
        log_message "  Available space: ${AVAILABLE_SPACE}KB"
        if [ "$UPDATE_SIZE" -gt "$AVAILABLE_SPACE" ]; then
            log_message "ERROR: Insufficient disk space. Need ${UPDATE_SIZE}KB, have ${AVAILABLE_SPACE}KB"
            exit 1
        fi

        # Create temporary directory for the update
        TEMP_DIR=$(mktemp -d)
        log_message "Created temporary directory: $TEMP_DIR"

        # Copy the original bundle to the temporary directory
        log_message "Copying original bundle to temporary directory..."
        if ! cp -R "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "ERROR: Failed to copy bundle to temporary directory"
            log_message "  Source: $APP_BUNDLE_PATH"
            log_message "  Destination: $TEMP_DIR/"
            log_message "  Error details:"
            cp -R "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        TEMP_BUNDLE="$TEMP_DIR/$(basename "$APP_BUNDLE_PATH")"
        log_message "Temporary bundle path: $TEMP_BUNDLE"

        # Verify that the temporary bundle was created correctly
        if [ ! -d "$TEMP_BUNDLE" ]; then
            log_message "ERROR: Temporary bundle was not created correctly"
            log_message "  Expected path: $TEMP_BUNDLE"
            log_message "  Temporary directory contents:"
            ls -la "$TEMP_DIR" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Verify destination directory exists and is writable
        DEST_DIR="$TEMP_BUNDLE/Contents"
        if [ ! -d "$DEST_DIR" ]; then
            log_message "ERROR: Destination directory does not exist: $DEST_DIR"
            log_message "  Temporary bundle structure:"
            find "$TEMP_BUNDLE" -maxdepth 2 -type d 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        if [ ! -w "$DEST_DIR" ]; then
            log_message "ERROR: Destination directory is not writable: $DEST_DIR"
            log_message "  Directory permissions:"
            ls -ld "$DEST_DIR" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Current user: $(whoami)"
            log_message "  Directory owner: $(stat -f '%Su' "$DEST_DIR" 2>/dev/null || echo 'unknown')"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        if [ "$IS_DEBUG" = false ]; then
            # Verify signatures of update files
            log_message "Verifying update files signatures..."
            for file in "$UPDATE_FOLDER_PATH"/*; do
                if [ -f "$file" ]; then
                    log_message "Checking signature of: $file"
                    if ! codesign -v "$file" 2>&1 | tee -a "$LOG_FILE"; then
                        log_message "ERROR: Update file not properly signed: $file"
                        rm -rf "$TEMP_DIR"
                        exit 1
                    fi
                fi
            done

            # Verify that team identifiers match
            log_message "Checking team identifiers..."
            UPDATE_TEAM_ID=$(codesign -d --verbose=2 "$UPDATE_FOLDER_PATH/$(basename "$EXECUTABLE_PATH")" 2>&1 | grep "TeamIdentifier" | awk '{print $2}')
            ORIGINAL_TEAM_ID=$(codesign -d --verbose=2 "$APP_BUNDLE_PATH" 2>&1 | grep "TeamIdentifier" | awk '{print $2}')
            
            log_message "Original team ID: $ORIGINAL_TEAM_ID"
            log_message "Update team ID: $UPDATE_TEAM_ID"
            
            if [ "$UPDATE_TEAM_ID" != "$ORIGINAL_TEAM_ID" ]; then
                log_message "ERROR: Team identifier mismatch. Original: $ORIGINAL_TEAM_ID, Update: $UPDATE_TEAM_ID"
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            log_message "Team identifier verified: $UPDATE_TEAM_ID"
        fi

        # Copy update files one by one with detailed error reporting
        log_message "Starting to copy update files to temporary bundle..."
        log_message "  Source: $UPDATE_FOLDER_PATH"
        log_message "  Destination: $DEST_DIR"
        
        COPY_ERRORS=0
        COPIED_FILES=0
        COPIED_DIRS=0
        
        # Function to copy a single file with error handling
        copy_file_with_details() {
            local src_file="$1"
            local dest_path="$2"
            local relative_path="$3"
            
            log_message "  Copying: $relative_path"
            
            # Get file info
            if [ -f "$src_file" ]; then
                local file_size=$(stat -f%z "$src_file" 2>/dev/null || echo "unknown")
                log_message "    Size: ${file_size} bytes"
            fi
            
            # Check source file permissions
            if [ ! -r "$src_file" ]; then
                log_message "    ERROR: Source file is not readable"
                log_message "    Source permissions: $(ls -l "$src_file" 2>&1 || echo 'unknown')"
                COPY_ERRORS=$((COPY_ERRORS + 1))
                return 1
            fi
            
            # Create destination directory if needed
            local dest_dir=$(dirname "$dest_path")
            if [ ! -d "$dest_dir" ]; then
                log_message "    Creating destination directory: $dest_dir"
                if ! mkdir -p "$dest_dir" 2>&1 | tee -a "$LOG_FILE"; then
                    log_message "    ERROR: Failed to create destination directory"
                    log_message "    Directory: $dest_dir"
                    log_message "    Permissions: $(ls -ld "$(dirname "$dest_dir")" 2>&1 || echo 'unknown')"
                    COPY_ERRORS=$((COPY_ERRORS + 1))
                    return 1
                fi
            fi
            
            # Check if destination directory is writable
            if [ ! -w "$dest_dir" ]; then
                log_message "    ERROR: Destination directory is not writable"
                log_message "    Directory: $dest_dir"
                log_message "    Permissions: $(ls -ld "$dest_dir" 2>&1 || echo 'unknown')"
                log_message "    Owner: $(stat -f '%Su' "$dest_dir" 2>/dev/null || echo 'unknown')"
                log_message "    Current user: $(whoami)"
                COPY_ERRORS=$((COPY_ERRORS + 1))
                return 1
            fi
            
            # Perform the copy with error capture
            local cp_output=$(cp -p "$src_file" "$dest_path" 2>&1)
            local cp_exit_code=$?
            
            if [ $cp_exit_code -ne 0 ]; then
                log_message "    ERROR: Failed to copy file"
                log_message "    Source: $src_file"
                log_message "    Destination: $dest_path"
                log_message "    Exit code: $cp_exit_code"
                log_message "    Error output: $cp_output"
                log_message "    Source file info:"
                ls -l "$src_file" 2>&1 | tee -a "$LOG_FILE" || true
                log_message "    Destination directory info:"
                ls -ld "$dest_dir" 2>&1 | tee -a "$LOG_FILE" || true
                COPY_ERRORS=$((COPY_ERRORS + 1))
                return 1
            fi
            
            # Verify the file was copied correctly
            if [ ! -f "$dest_path" ]; then
                log_message "    ERROR: File was not copied (destination does not exist)"
                log_message "    Expected: $dest_path"
                COPY_ERRORS=$((COPY_ERRORS + 1))
                return 1
            fi
            
            # Verify file sizes match (if source is a regular file)
            if [ -f "$src_file" ] && [ -f "$dest_path" ]; then
                local src_size=$(stat -f%z "$src_file" 2>/dev/null || echo "0")
                local dest_size=$(stat -f%z "$dest_path" 2>/dev/null || echo "0")
                if [ "$src_size" != "$dest_size" ]; then
                    log_message "    ERROR: File size mismatch after copy"
                    log_message "    Source size: $src_size bytes"
                    log_message "    Destination size: $dest_size bytes"
                    COPY_ERRORS=$((COPY_ERRORS + 1))
                    return 1
                fi
            fi
            
            COPIED_FILES=$((COPIED_FILES + 1))
            log_message "    ✓ Successfully copied"
            return 0
        }
        
        # Copy files and directories
        # Save current directory
        ORIGINAL_DIR=$(pwd)
        
        # Change to update folder to avoid path issues
        cd "$UPDATE_FOLDER_PATH" || {
            log_message "ERROR: Failed to change to update folder: $UPDATE_FOLDER_PATH"
            rm -rf "$TEMP_DIR"
            exit 1
        }
        
        log_message "Current directory: $(pwd)"
        log_message "Destination directory: $DEST_DIR"
        
        for item in *; do
            # Skip if glob didn't match anything
            if [ "$item" = "*" ] && [ ! -e "$item" ]; then
                log_message "  No items found in update folder"
                break
            fi
            
            # Skip . and ..
            if [ "$item" = "." ] || [ "$item" = ".." ]; then
                continue
            fi
            
            # Build absolute paths - don't use local to avoid scope issues
            CURRENT_DIR=$(pwd)
            item_path="$CURRENT_DIR/$item"
            dest_item="$DEST_DIR/$item"
            verify_path="$DEST_DIR/$item"
            
            # Debug: show all variables
            log_message "  Processing: $item"
            log_message "    CURRENT_DIR: $CURRENT_DIR"
            log_message "    item: $item"
            log_message "    DEST_DIR: $DEST_DIR"
            log_message "    Source path: $item_path"
            log_message "    Destination path: $dest_item"
            log_message "    Verify path: $verify_path"
            
            # Skip log files - they shouldn't be copied to the bundle
            if [[ "$item" == *.log ]]; then
                log_message "    Skipping log file: $item"
                continue
            fi
            
            if [ -d "$item" ]; then
                log_message "    Type: directory"
                # Remove destination if it exists to avoid conflicts with symlinks
                if [ -e "$verify_path" ]; then
                    log_message "    Removing existing destination: $verify_path"
                    rm -rf "$verify_path" 2>&1 | tee -a "$LOG_FILE" || {
                        log_message "    WARNING: Failed to remove existing destination, will attempt copy anyway"
                    }
                fi
                
                # Copy directory recursively, preserving symlinks
                cp_output=$(cp -R -p "$item" "$DEST_DIR/" 2>&1)
                cp_exit_code=$?
                
                log_message "    Copy command exit code: $cp_exit_code"
                if [ -n "$cp_output" ]; then
                    log_message "    Copy output: $cp_output"
                fi
                
                if [ $cp_exit_code -ne 0 ]; then
                    log_message "    ERROR: Failed to copy directory"
                    log_message "    Source: $item_path"
                    log_message "    Destination: $DEST_DIR"
                    log_message "    Exit code: $cp_exit_code"
                    log_message "    Error output: $cp_output"
                    log_message "    Attempting alternative copy method (rsync)..."
                    
                    # Try using rsync as fallback if available
                    if command -v rsync >/dev/null 2>&1; then
                        rsync_output=$(rsync -a --delete "$item_path/" "$verify_path/" 2>&1)
                        rsync_exit_code=$?
                        if [ $rsync_exit_code -eq 0 ]; then
                            log_message "    ✓ Successfully copied using rsync"
                            COPIED_DIRS=$((COPIED_DIRS + 1))
                        else
                            log_message "    ERROR: rsync also failed"
                            log_message "    rsync output: $rsync_output"
                            COPY_ERRORS=$((COPY_ERRORS + 1))
                        fi
                    else
                        COPY_ERRORS=$((COPY_ERRORS + 1))
                    fi
                else
                    # Verify directory was copied - use absolute path
                    log_message "    Verifying copy..."
                    log_message "    Checking if $verify_path exists..."
                    if [ -d "$verify_path" ]; then
                        log_message "    ✓ Directory exists at $verify_path"
                        COPIED_DIRS=$((COPIED_DIRS + 1))
                        log_message "    ✓ Successfully copied directory"
                    else
                        log_message "    ERROR: Directory was not copied (destination does not exist)"
                        log_message "    Expected: $verify_path"
                        log_message "    DEST_DIR value: $DEST_DIR"
                        log_message "    item value: $item"
                        log_message "    Checking destination directory contents:"
                        ls -la "$DEST_DIR" 2>&1 | tee -a "$LOG_FILE" || true
                        log_message "    Checking if item exists with different case or path:"
                        find "$DEST_DIR" -maxdepth 1 -iname "$item" 2>&1 | tee -a "$LOG_FILE" || true
                        COPY_ERRORS=$((COPY_ERRORS + 1))
                    fi
                fi
            elif [ -f "$item" ]; then
                log_message "    Type: file"
                copy_file_with_details "$item_path" "$dest_item" "$item"
            else
                log_message "    WARNING: Skipping unknown type: $item"
                log_message "    File info:"
                ls -la "$item" 2>&1 | tee -a "$LOG_FILE" || true
            fi
        done
        
        # Return to original directory
        cd "$ORIGINAL_DIR" || cd "$HOME"
        
        # Summary of copy operation
        log_message "Copy operation summary:"
        log_message "  Files copied: $COPIED_FILES"
        log_message "  Directories copied: $COPIED_DIRS"
        log_message "  Errors: $COPY_ERRORS"
        
        if [ $COPY_ERRORS -gt 0 ]; then
            log_message "ERROR: Failed to copy $COPY_ERRORS file(s)/directory(ies)"
            log_message "  Source folder: $UPDATE_FOLDER_PATH"
            log_message "  Destination folder: $DEST_DIR"
            log_message "  Please check the log above for details about which files failed"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Verify that files were copied correctly by checking a few key files
        log_message "Verifying copied files..."
        VERIFICATION_ERRORS=0
        # Use find to get only regular files, avoiding glob expansion issues
        while IFS= read -r file; do
            # Skip if empty or if it's the glob pattern itself (didn't expand)
            if [ -z "$file" ] || [ "$file" = "$UPDATE_FOLDER_PATH/*" ]; then
                continue
            fi
            
            # Only process regular files (not directories)
            if [ -f "$file" ]; then
                local file_name=$(basename "$file")
                # Skip if file_name is empty
                if [ -z "$file_name" ]; then
                    continue
                fi
                
                local dest_file="$DEST_DIR/$file_name"
                if [ ! -f "$dest_file" ]; then
                    log_message "  ERROR: File verification failed - destination does not exist: $file_name"
                    VERIFICATION_ERRORS=$((VERIFICATION_ERRORS + 1))
                else
                    # Compare file sizes
                    local src_size=$(stat -f%z "$file" 2>/dev/null || echo "0")
                    local dest_size=$(stat -f%z "$dest_file" 2>/dev/null || echo "0")
                    if [ "$src_size" != "$dest_size" ]; then
                        log_message "  ERROR: File size mismatch: $file_name (src: $src_size, dest: $dest_size)"
                        VERIFICATION_ERRORS=$((VERIFICATION_ERRORS + 1))
                    else
                        log_message "  ✓ Verified: $file_name"
                    fi
                fi
            fi
        done < <(find "$UPDATE_FOLDER_PATH" -maxdepth 1 -type f 2>/dev/null || true)
        
        if [ $VERIFICATION_ERRORS -gt 0 ]; then
            log_message "ERROR: File verification failed for $VERIFICATION_ERRORS file(s)"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        log_message "All files verified successfully"

        # Re-seal the bundle after copying (bundle seal is invalidated when contents change).
        # Frameworks and executable from the backend are already signed and notarized; we only
        # need to re-sign the bundle container so its seal matches the new contents.
        if [ "$IS_DEBUG" = false ]; then
            log_message "Re-signing bundle seal after copy (update files are already signed)..."
            
            ORIGINAL_SIGNING_IDENTITY=$(codesign -d --verbose=2 "$APP_BUNDLE_PATH" 2>&1 | grep "^Authority=" | head -1 | sed 's/^Authority=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
            if [ -z "$ORIGINAL_SIGNING_IDENTITY" ]; then
                ORIGINAL_SIGNING_IDENTITY=$(codesign -d -vv "$APP_BUNDLE_PATH" 2>&1 | grep "Authority=" | head -1 | sed 's/.*Authority=//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
            fi
            if [ -z "$ORIGINAL_SIGNING_IDENTITY" ] && [ -n "$ORIGINAL_TEAM_ID" ]; then
                ORIGINAL_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "$ORIGINAL_TEAM_ID" | head -1 | awk -F'"' '{print $2}' || echo "")
            fi
            if [ -z "$ORIGINAL_SIGNING_IDENTITY" ] || [ "$ORIGINAL_SIGNING_IDENTITY" = "Apple" ]; then
                if [ -n "$ORIGINAL_TEAM_ID" ]; then
                    ORIGINAL_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "$ORIGINAL_TEAM_ID" | head -1 | awk -F'"' '{print $2}' || echo "")
                fi
            fi
            
            if [ -z "$ORIGINAL_SIGNING_IDENTITY" ]; then
                log_message "ERROR: Could not determine signing identity from original bundle"
                log_message "  Attempted to extract from: $APP_BUNDLE_PATH"
                log_message "  Original team ID: $ORIGINAL_TEAM_ID"
                codesign -d --verbose=2 "$APP_BUNDLE_PATH" 2>&1 | head -20 | tee -a "$LOG_FILE" || true
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            log_message "Using signing identity: $ORIGINAL_SIGNING_IDENTITY"
            
            log_message "Re-signing bundle: $TEMP_BUNDLE"
            if ! codesign --force --sign "$ORIGINAL_SIGNING_IDENTITY" --preserve-metadata=entitlements,requirements,flags,runtime "$TEMP_BUNDLE" 2>&1 | tee -a "$LOG_FILE"; then
                log_message "  ERROR: Failed to re-sign bundle"
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            log_message "  ✓ Bundle re-signed successfully"
        fi

        # Verify executable permissions in the temporary bundle
        TEMP_EXECUTABLE="$TEMP_BUNDLE/Contents/MacOS/$(basename "$EXECUTABLE_PATH")"
        log_message "Setting executable permissions..."
        if [ ! -f "$TEMP_EXECUTABLE" ]; then
            log_message "ERROR: Temporary executable not found: $TEMP_EXECUTABLE"
            log_message "  Contents of MacOS directory:"
            ls -la "$TEMP_BUNDLE/Contents/MacOS/" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        chmod +x "$TEMP_EXECUTABLE"
        if [ ! -x "$TEMP_EXECUTABLE" ]; then
            log_message "ERROR: Failed to set executable permissions"
            log_message "  File: $TEMP_EXECUTABLE"
            log_message "  Current permissions: $(ls -l "$TEMP_EXECUTABLE" 2>&1 || echo 'unknown')"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        log_message "Executable permissions set successfully"

        # Create backup of the original bundle
        BACKUP_PATH="$APP_BUNDLE_PATH.backup"
        log_message "Creating backup at: $BACKUP_PATH"
        if ! mv "$APP_BUNDLE_PATH" "$BACKUP_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "ERROR: Failed to create backup"
            log_message "  Source: $APP_BUNDLE_PATH"
            log_message "  Destination: $BACKUP_PATH"
            log_message "  Permissions:"
            ls -ld "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Parent directory permissions:"
            ls -ld "$(dirname "$APP_BUNDLE_PATH")" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Move the temporary bundle to the final location
        log_message "Moving temporary bundle to final location..."
        if ! mv "$TEMP_BUNDLE" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "ERROR: Failed to move bundle to final location"
            log_message "  Source: $TEMP_BUNDLE"
            log_message "  Destination: $APP_BUNDLE_PATH"
            log_message "  Error details:"
            mv "$TEMP_BUNDLE" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            log_message "  Attempting to restore backup..."
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Verify that the final bundle exists and has the correct files
        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "ERROR: Final bundle does not exist after move"
            log_message "  Expected: $APP_BUNDLE_PATH"
            log_message "  Attempting to restore backup..."
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        
        # Final signature verification after move (critical check)
        if [ "$IS_DEBUG" = false ]; then
            log_message "Performing final signature verification after move..."
            FINAL_FRAMEWORKS_DIR="$APP_BUNDLE_PATH/Contents/Frameworks"
            if [ -d "$FINAL_FRAMEWORKS_DIR" ]; then
                find "$FINAL_FRAMEWORKS_DIR" -name "*.framework" -type d | while read -r framework; do
                    if ! codesign -v --verbose=2 "$framework" 2>&1 | tee -a "$LOG_FILE"; then
                        log_message "ERROR: Final framework signature verification failed: $framework"
                        log_message "  Attempting to restore backup..."
                        rm -rf "$APP_BUNDLE_PATH"
                        mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
                        rm -rf "$TEMP_DIR"
                        exit 1
                    fi
                done
            fi
            if ! codesign -v --verbose=2 "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
                log_message "ERROR: Final bundle signature verification failed"
                log_message "  Attempting to restore backup..."
                rm -rf "$APP_BUNDLE_PATH"
                mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
                rm -rf "$TEMP_DIR"
                exit 1
            fi
            log_message "✓ All signatures verified successfully after move"
        fi

        # Clean up temporary directory
        rm -rf "$TEMP_DIR"
        log_message "Temporary directory cleaned up"

        # Wait before opening the application
        log_message "Waiting before launching application..."
        sleep 3

        # Try to open the application
        log_message "Launching application..."
        if [ "$IS_DEBUG" = true ]; then
            cd "$(dirname "$EXECUTABLE_PATH")"
            log_message "Changed directory to: $(pwd)"
            ./"$(basename "$EXECUTABLE_PATH")" &
            LAUNCH_PID=$!
            log_message "Launched with PID: $LAUNCH_PID"
        else
            open "$APP_BUNDLE_PATH"
        fi

        # Wait for the application to start
        TIMEOUT=15
        COUNT=0
        while ! is_app_running && [ $COUNT -lt $TIMEOUT ]; do
            sleep 1
            COUNT=$((COUNT + 1))
            log_message "Waiting for application to start... ($COUNT/$TIMEOUT)"
        done

        if is_app_running; then
            log_message "Application launched successfully"
            rm -rf "$BACKUP_PATH"
            exit 0
        else
            log_message "ERROR: Application failed to start after $TIMEOUT seconds"
            log_message "  Attempting to restore backup..."
            rm -rf "$APP_BUNDLE_PATH"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE" || true
            exit 1
        fi
        """

        // Write the script to temporary file
        do {
            try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            print("Script written to: \(scriptPath)")
            print("Script permissions set to 755")
        } catch {
            print("Error writing shell script: \(error)")
            return
        }

        // Launch the script as a detached process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath, appBundlePath, updateFolder, executablePath, logFile.path]
        
        do {
            try process.run()
            print("Update script started")
            Thread.sleep(forTimeInterval: 2.0)
        } catch {
            print("Failed to run update script: \(error)")
            return
        }

        // Finish the application
        DispatchQueue.main.async {
            print("Terminating current application instance...")
            NSApplication.shared.terminate(nil)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "desktop_updater", binaryMessenger: registrar.messenger)
        let instance = DesktopUpdaterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
        case "restartApp":
            restartApp()
            result(nil)
        case "getExecutablePath":
            result(Bundle.main.executablePath)
        case "getCurrentVersion":
            result(getCurrentVersion())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
