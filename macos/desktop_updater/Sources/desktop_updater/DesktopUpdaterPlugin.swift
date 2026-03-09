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
        
        // Get the application-specific Application Support directory path, example: ~/Library/Application Support/com.yourcompany.yourapp
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            print("Bundle identifier not found")
            return
        }
        let appSpecificDir = appSupportDir.appendingPathComponent(bundleIdentifier)
        let updateFolder = appSpecificDir.appendingPathComponent("updates").appendingPathComponent("update").path

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

        print("Update folder path: \(updateFolder)")
        print("Log file path: \(logFile.path)")

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

        # Verify that the update folder exists and has content
        if [ ! -d "$UPDATE_FOLDER_PATH" ]; then
            log_message "Error: Update folder does not exist: $UPDATE_FOLDER_PATH"
            exit 1
        fi
        log_message "Update folder contents:"
        ls -la "$UPDATE_FOLDER_PATH" | tee -a "$LOG_FILE"

        # Verify there are files to update
        UPDATE_FILES_COUNT=$(ls -1 "$UPDATE_FOLDER_PATH" | wc -l)
        if [ "$UPDATE_FILES_COUNT" -eq 0 ]; then
            log_message "Error: Update folder is empty"
            exit 1
        fi
        log_message "Found $UPDATE_FILES_COUNT files to update"

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
            log_message "Error: Application failed to close after $TIMEOUT seconds"
            exit 1
        fi
        log_message "Application terminated successfully"

        # Verify that the original bundle exists
        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "Error: Original bundle does not exist: $APP_BUNDLE_PATH"
            exit 1
        fi

        # Create temporary directory on the same volume as the app (enables reflink for speed)
        APP_DIR="$(dirname "$APP_BUNDLE_PATH")"
        TEMP_DIR=$(mktemp -d "${APP_DIR}/.update.XXXXXX" 2>/dev/null)
        if [ ! -d "$TEMP_DIR" ]; then
            TEMP_DIR=$(mktemp -d)
        fi
        log_message "Created temporary directory: $TEMP_DIR"

        # Copy the original bundle: try reflink (APFS, nearly instant) then ditto then cp -R
        log_message "Copying bundle (reflink -> ditto -> cp fallback)..."
        if cp -R -c "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>/dev/null; then
            log_message "  Used reflink (clone) - minimal I/O"
        elif ditto "$APP_BUNDLE_PATH" "$TEMP_DIR/$(basename "$APP_BUNDLE_PATH")" 2>/dev/null; then
            log_message "  Used ditto (optimized for bundles)"
        elif cp -R "$APP_BUNDLE_PATH" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  Used cp -R (fallback)"
        else
            log_message "ERROR: Failed to copy bundle to temporary directory"
            log_message "  Source: $APP_BUNDLE_PATH"
            log_message "  Destination: $TEMP_DIR/"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        TEMP_BUNDLE="$TEMP_DIR/$(basename "$APP_BUNDLE_PATH")"
        log_message "Temporary bundle path: $TEMP_BUNDLE"

        # Verify that the temporary bundle was created correctly
        if [ ! -d "$TEMP_BUNDLE" ]; then
            log_message "Error: Temporary bundle was not created correctly"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        log_message "Stripping inherited code-signing xattrs from clone..."
        xattr -cr "$TEMP_BUNDLE"
        log_message "  ✓ xattrs cleared"
        DEST_DIR="$TEMP_BUNDLE/Contents"

        # Overlay update files with rsync (single pass, faster than per-item cp -R)
        log_message "Overlaying update files: $UPDATE_FOLDER_PATH -> $DEST_DIR"
        if [ ! -d "$UPDATE_FOLDER_PATH" ]; then
            log_message "ERROR: Update folder not found: $UPDATE_FOLDER_PATH"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        if rsync -a --delete --exclude='*.log' "$UPDATE_FOLDER_PATH/" "$DEST_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  ✓ Update files overlayed (rsync)"
        else
            log_message "ERROR: rsync overlay failed"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Quick check: executable must exist after overlay
        EXECUTABLE_NAME="$(basename "$EXECUTABLE_PATH")"
        if [ ! -f "$DEST_DIR/MacOS/$EXECUTABLE_NAME" ]; then
            log_message "ERROR: Executable missing after overlay: MacOS/$EXECUTABLE_NAME"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
        log_message "All files verified successfully"

        TEMP_EXECUTABLE="$TEMP_BUNDLE/Contents/MacOS/$(basename "$EXECUTABLE_PATH")"

        # Verify executable permissions in the temporary bundle
        log_message "Setting executable permissions..."
        chmod +x "$TEMP_EXECUTABLE"
        if [ ! -x "$TEMP_EXECUTABLE" ]; then
            log_message "Error: Temporary executable not found or not executable"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Create backup of the original bundle
        BACKUP_PATH="$APP_BUNDLE_PATH.backup"
        log_message "Creating backup at: $BACKUP_PATH"
        if ! mv "$APP_BUNDLE_PATH" "$BACKUP_PATH"; then
            log_message "Error: Failed to create backup"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Move the temporary bundle to the final location
        log_message "Moving temporary bundle to final location..."
        if ! mv "$TEMP_BUNDLE" "$APP_BUNDLE_PATH"; then
            log_message "Error: Failed to move bundle to final location"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Verify that the final bundle exists and has the correct files
        if [ ! -d "$APP_BUNDLE_PATH" ]; then
            log_message "Error: Final bundle does not exist"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Clean up temporary directory and update folder
        rm -rf "$TEMP_DIR"
        rm -rf "$UPDATE_FOLDER_PATH"

        # Brief pause before launching
        log_message "Waiting before launching application..."
        sleep 1

        # Re-sign the bundle ad-hoc to fix the code signature after file replacement
        log_message "Re-signing application bundle ad-hoc..."
        if codesign --force --deep --sign - "$APP_BUNDLE_PATH" 2>&1 | tee -a "$LOG_FILE"; then
            log_message "  ✓ App bundle re-signed successfully"
        else
            log_message "  ⚠ Warning: Re-signing failed, app may not launch"
        fi

        # Try to open the application
        log_message "Launching application..."
        xattr -dr com.apple.quarantine "$APP_BUNDLE_PATH" 2>/dev/null || true
        open "$APP_BUNDLE_PATH"

        # Wait for the application to start
        TIMEOUT=60
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
            log_message "Error: Application failed to start after $TIMEOUT seconds"
            rm -rf "$APP_BUNDLE_PATH"
            mv "$BACKUP_PATH" "$APP_BUNDLE_PATH"
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