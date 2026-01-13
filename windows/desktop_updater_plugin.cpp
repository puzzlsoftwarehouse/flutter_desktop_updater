#include "desktop_updater_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <VersionHelpers.h>
#include <Shlwapi.h> // Include Shlwapi.h for PathFileExistsW
#include <shellapi.h> // ShellExecuteW for UAC elevation

#pragma comment(lib, "Version.lib") // Link with Version.lib
#pragma comment(lib, "Shlwapi.lib") // Link with Shlwapi.lib
#pragma comment(lib, "Shell32.lib") // Link with Shell32.lib for ShellExecuteW

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>
#include <filesystem>
#include <iostream>
#include <fstream>
#include <cstdlib>

namespace fs = std::filesystem;
namespace desktop_updater
{

  // Forward declarations
  void createBatFile(const std::wstring &updateDir, const std::wstring &destDir, const wchar_t *executable_path, const std::wstring &tempUpdateDir = L"");
  void runBatFile();
  std::wstring FindTempUpdateDirectory();

  // Check if the application was started with elevated update arguments
  bool CheckForElevatedUpdate()
  {
    int argc;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    
    if (argv != nullptr)
    {
      for (int i = 1; i < argc; i++)
      {
        if (wcscmp(argv[i], L"--update-elevated") == 0)
        {
          LocalFree(argv);
          return true;
        }
      }
      LocalFree(argv);
    }
    return false;
  }

  std::wstring FindTempUpdateDirectory()
  {
    wchar_t tempPath[MAX_PATH];
    if (GetTempPathW(MAX_PATH, tempPath) == 0)
    {
      return L"";
    }

    std::wstring searchPath = std::wstring(tempPath) + L"desktop_updater_download*";
    WIN32_FIND_DATAW findData;
    HANDLE hFind = FindFirstFileW(searchPath.c_str(), &findData);
    
    if (hFind != INVALID_HANDLE_VALUE)
    {
      do
      {
        if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        {
          if (wcscmp(findData.cFileName, L".") != 0 && wcscmp(findData.cFileName, L"..") != 0)
          {
            std::wstring foundPath = std::wstring(tempPath) + findData.cFileName + L"\\update";
            
            if (PathFileExistsW(foundPath.c_str()))
            {
              FindClose(hFind);
              return foundPath;
            }
          }
        }
      } while (FindNextFileW(hFind, &findData) != 0);
      
      FindClose(hFind);
    }
    
    return L"";
  }

  // Execute the update process when running elevated
  void ExecuteElevatedUpdate()
  {
    printf("Executing elevated update process...\n");
    
    // Get the current executable file path
    wchar_t executable_path[MAX_PATH];
    GetModuleFileNameW(NULL, executable_path, MAX_PATH);

    printf("Executable path: %ls\n", executable_path);

    // Try to find temp update directory first
    std::wstring tempUpdateDir = FindTempUpdateDirectory();
    std::wstring updateDir = tempUpdateDir.empty() ? L"update" : tempUpdateDir;
    std::wstring destDir = L".";

    if (!tempUpdateDir.empty())
    {
      printf("Found temp update directory: %ls\n", tempUpdateDir.c_str());
    }

    // Create and run the batch file for updating
    createBatFile(updateDir, destDir, executable_path, tempUpdateDir);
    runBatFile();

    // Exit after update
    ExitProcess(0);
  }

  // static
  void DesktopUpdaterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    // Check if this instance was started for elevated update
    if (CheckForElevatedUpdate())
    {
      ExecuteElevatedUpdate();
      return; // This will not be reached due to ExitProcess in ExecuteElevatedUpdate
    }

    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "desktop_updater",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<DesktopUpdaterPlugin>();

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  DesktopUpdaterPlugin::DesktopUpdaterPlugin() {}

  DesktopUpdaterPlugin::~DesktopUpdaterPlugin() {}

  // Modify the createBatFile function to accept parameters and use them in the bat script
  void createBatFile(const std::wstring &updateDir, const std::wstring &destDir, const wchar_t *executable_path, const std::wstring &tempUpdateDir)
  {
    // Convert wide strings to regular strings using Windows API for proper conversion
    int updateSize = WideCharToMultiByte(CP_UTF8, 0, updateDir.c_str(), -1, NULL, 0, NULL, NULL);
    std::string updateDirStr(updateSize, 0);
    WideCharToMultiByte(CP_UTF8, 0, updateDir.c_str(), -1, &updateDirStr[0], updateSize, NULL, NULL);
    updateDirStr.pop_back(); // Remove null terminator

    int destSize = WideCharToMultiByte(CP_UTF8, 0, destDir.c_str(), -1, NULL, 0, NULL, NULL);
    std::string destDirStr(destSize, 0);
    WideCharToMultiByte(CP_UTF8, 0, destDir.c_str(), -1, &destDirStr[0], destSize, NULL, NULL);
    destDirStr.pop_back(); // Remove null terminator

    int exePathSize = WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, NULL, 0, NULL, NULL);
    std::string exePathStr(exePathSize, 0);
    WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, &exePathStr[0], exePathSize, NULL, NULL);
    exePathStr.pop_back(); // Remove null terminator

    std::string cleanupTempDir = "";
    if (!tempUpdateDir.empty())
    {
      int tempDirSize = WideCharToMultiByte(CP_UTF8, 0, tempUpdateDir.c_str(), -1, NULL, 0, NULL, NULL);
      std::string tempDirStr(tempDirSize, 0);
      WideCharToMultiByte(CP_UTF8, 0, tempUpdateDir.c_str(), -1, &tempDirStr[0], tempDirSize, NULL, NULL);
      tempDirStr.pop_back(); // Remove null terminator
      
      size_t lastSlash = tempDirStr.find_last_of("\\/");
      if (lastSlash != std::string::npos)
      {
        std::string parentTempDir = tempDirStr.substr(0, lastSlash);
        cleanupTempDir = "rmdir /S /Q \"" + parentTempDir + "\"\n";
      }
    }

    const std::string batScript =
        "@echo off\n"
        "chcp 65001 > NUL\n"
        "timeout /t 2 /nobreak > NUL\n"
        "xcopy /E /I /Y \"" +
        updateDirStr + "\\*\" \"" + destDirStr + "\\\"\n";
    
    std::string finalScript = batScript;
    
    if (!tempUpdateDir.empty())
    {
      finalScript += cleanupTempDir;
    }
    else
    {
      finalScript += "rmdir /S /Q \"" + updateDirStr + "\"\n";
    }
    
    finalScript +=
        "timeout /t 1 /nobreak > NUL\n"
        "start \"\" \"" +
        exePathStr + "\"\n"
                     "timeout /t 1 /nobreak > NUL\n"
                     "del update_script.bat\n"
                     "exit\n";

    std::ofstream batFile("update_script.bat");
    batFile << finalScript;
    batFile.close();
    std::cout << "Temporary .bat created.\n";
  }

  // Check if the current process is running with administrator privileges
  bool IsRunningAsAdmin()
  {
    BOOL isAdmin = FALSE;
    PSID adminGroup = NULL;

    // Create a SID for the BUILTIN\Administrators group
    SID_IDENTIFIER_AUTHORITY ntAuthority = SECURITY_NT_AUTHORITY;
    if (AllocateAndInitializeSid(&ntAuthority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &adminGroup))
    {
      // Check if the current user is a member of the administrators group
      if (!CheckTokenMembership(NULL, adminGroup, &isAdmin))
      {
        isAdmin = FALSE;
      }
      FreeSid(adminGroup);
    }

    return isAdmin == TRUE;
  }

  // Request administrator privileges and restart the application with elevation
  bool RequestAdminPrivileges()
  {
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(NULL, exePath, MAX_PATH);

    // Use ShellExecuteW with "runas" to request elevation
    HINSTANCE result = ShellExecuteW(NULL, L"runas", exePath, L"--update-elevated", NULL, SW_SHOW);

    if ((INT_PTR)result > 32)
    {
      // Successfully started elevated process, exit current process
      return true;
    }
    else
    {
      // User cancelled UAC or other error
      std::wcout << L"Failed to get administrator privileges. Error code: " << (INT_PTR)result << std::endl;
      return false;
    }
  }

  void runBatFile()
  {
    STARTUPINFO si = {sizeof(si)};
    PROCESS_INFORMATION pi;

    WCHAR cmdLine[] = L"cmd.exe /c update_script.bat";
    if (CreateProcess(
            NULL,
            cmdLine,
            NULL,
            NULL,
            FALSE,
            CREATE_NO_WINDOW,
            NULL,
            NULL,
            &si,
            &pi))
    {
      CloseHandle(pi.hProcess);
      CloseHandle(pi.hThread);
    }
    else
    {
      std::cout << "Failed to run the .bat file.\n";
    }
  }

  void RestartApp()
  {
    printf("Restarting the application...\n");

    // First check if we're already running as administrator
    if (!IsRunningAsAdmin())
    {
      printf("Not running as administrator. Requesting elevation...\n");
      
      // Request administrator privileges
      if (RequestAdminPrivileges())
      {
        // Successfully started elevated process, exit current process
        printf("Elevated process started. Exiting current process.\n");
        ExitProcess(0);
      }
      else
      {
        // User cancelled UAC or elevation failed
        printf("Failed to get administrator privileges. Update cancelled.\n");
        return; // Don't proceed with update
      }
    }

    // If we reach here, we're running as administrator
    printf("Running with administrator privileges. Proceeding with update...\n");

    // Get the current executable file path
    char szFilePath[MAX_PATH];
    GetModuleFileNameA(NULL, szFilePath, MAX_PATH);

    // Child process
    wchar_t executable_path[MAX_PATH];
    GetModuleFileNameW(NULL, executable_path, MAX_PATH);

    printf("Executable path: %ls\n", executable_path);

    // Try to find temp update directory first
    std::wstring tempUpdateDir = FindTempUpdateDirectory();
    std::wstring updateDir = tempUpdateDir.empty() ? L"update" : tempUpdateDir;
    std::wstring destDir = L".";

    if (!tempUpdateDir.empty())
    {
      printf("Found temp update directory: %ls\n", tempUpdateDir.c_str());
    }

    // Update createBatFile call with parameters
    createBatFile(updateDir, destDir, executable_path, tempUpdateDir);

    // 3. .bat dosyasını çalıştır
    runBatFile();

    // Exit the current process
    ExitProcess(0);
  }

  void DesktopUpdaterPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("getPlatformVersion") == 0)
    {
      std::ostringstream version_stream;
      version_stream << "Windows ";
      if (IsWindows10OrGreater())
      {
        version_stream << "10+";
      }
      else if (IsWindows8OrGreater())
      {
        version_stream << "8";
      }
      else if (IsWindows7OrGreater())
      {
        version_stream << "7";
      }
      result->Success(flutter::EncodableValue(version_stream.str()));
    }
    else if (method_call.method_name().compare("restartApp") == 0)
    {
      RestartApp();
      result->Success();
    }
    else if (method_call.method_name().compare("getExecutablePath") == 0)
    {
      wchar_t executable_path[MAX_PATH];
      GetModuleFileNameW(NULL, executable_path, MAX_PATH);

      // Convert wchar_t to std::string (UTF-8)
      int size_needed = WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, NULL, 0, NULL, NULL);
      std::string executablePathStr(size_needed, 0);
      WideCharToMultiByte(CP_UTF8, 0, executable_path, -1, &executablePathStr[0], size_needed, NULL, NULL);

      result->Success(flutter::EncodableValue(executablePathStr));
    }
    else if (method_call.method_name().compare("getCurrentVersion") == 0)
    {
      // Get only bundle version, Product version 1.0.0+2, should return 2
      wchar_t exePath[MAX_PATH];
      GetModuleFileNameW(NULL, exePath, MAX_PATH);

      DWORD verHandle = 0;
      UINT size = 0;
      LPBYTE lpBuffer = NULL;
      DWORD verSize = GetFileVersionInfoSizeW(exePath, &verHandle);
      if (verSize == NULL)
      {
        result->Error("VersionError", "Unable to get version size.");
        return;
      }

      std::vector<BYTE> verData(verSize);
      if (!GetFileVersionInfoW(exePath, verHandle, verSize, verData.data()))
      {
        result->Error("VersionError", "Unable to get version info.");
        return;
      }

      // Retrieve translation information
      struct LANGANDCODEPAGE
      {
        WORD wLanguage;
        WORD wCodePage;
      } *lpTranslate;

      UINT cbTranslate = 0;
      if (!VerQueryValueW(verData.data(), L"\\VarFileInfo\\Translation",
                          (LPVOID *)&lpTranslate, &cbTranslate) ||
          cbTranslate < sizeof(LANGANDCODEPAGE))
      {
        result->Error("VersionError", "Unable to get translation info.");
        return;
      }

      // Build the query string using the first translation
      wchar_t subBlock[50];
      swprintf(subBlock, 50, L"\\StringFileInfo\\%04x%04x\\ProductVersion",
               lpTranslate[0].wLanguage, lpTranslate[0].wCodePage);

      if (!VerQueryValueW(verData.data(), subBlock, (LPVOID *)&lpBuffer, &size))
      {
        result->Error("VersionError", "Unable to query version value.");
        return;
      }

      std::wstring productVersion((wchar_t *)lpBuffer);
      size_t plusPos = productVersion.find(L'+');
      if (plusPos != std::wstring::npos && plusPos + 1 < productVersion.length())
      {
        std::wstring buildNumber = productVersion.substr(plusPos + 1);

        // Trim any trailing spaces
        buildNumber.erase(buildNumber.find_last_not_of(L' ') + 1);

        // Convert wchar_t to std::string (UTF-8)
        int size_needed = WideCharToMultiByte(CP_UTF8, 0, buildNumber.c_str(), -1, NULL, 0, NULL, NULL);
        std::string buildNumberStr(size_needed - 1, 0); // Exclude null terminator
        WideCharToMultiByte(CP_UTF8, 0, buildNumber.c_str(), -1, &buildNumberStr[0], size_needed - 1, NULL, NULL);

        result->Success(flutter::EncodableValue(buildNumberStr));
      }
      else
      {
        result->Error("VersionError", "Invalid version format.");
      }
    }
    else
    {
      result->NotImplemented();
    }
  }

} // namespace desktop_updater
