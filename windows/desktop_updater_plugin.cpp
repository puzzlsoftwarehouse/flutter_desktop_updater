#include "desktop_updater_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>
#include <VersionHelpers.h>
#include <Shlwapi.h>
#include <shellapi.h>
#include <tlhelp32.h>

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
#include <vector>

namespace fs = std::filesystem;
namespace desktop_updater
{

  // Forward declarations
  void createBatFile(const std::wstring &updateDir, const std::wstring &destDir, const wchar_t *executable_path, const std::wstring &tempUpdateDir = L"");
  void runBatFile();
  std::wstring FindTempUpdateDirectory();
  bool WaitForProcessToExit(DWORD processId, DWORD timeoutSeconds = 60);
  DWORD GetParentProcessId();
  bool IsProcessRunning(DWORD processId);
  bool WaitForExecutableToBeFree(const wchar_t* executablePath, DWORD timeoutSeconds = 30);
  std::vector<DWORD> FindProcessesByExecutable(const wchar_t* executablePath);
  bool KillProcess(DWORD processId);
  void KillAllProcessesByExecutable(const wchar_t* executablePath);

  DWORD g_parentProcessId = 0;

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
          if (i + 1 < argc)
          {
            g_parentProcessId = _wtoi(argv[i + 1]);
          }
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

  DWORD GetParentProcessId()
  {
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE)
    {
      return 0;
    }

    PROCESSENTRY32W pe32;
    pe32.dwSize = sizeof(PROCESSENTRY32W);
    DWORD currentPid = GetCurrentProcessId();

    if (Process32FirstW(hSnapshot, &pe32))
    {
      do
      {
        if (pe32.th32ProcessID == currentPid)
        {
          CloseHandle(hSnapshot);
          return pe32.th32ParentProcessID;
        }
      } while (Process32NextW(hSnapshot, &pe32));
    }

    CloseHandle(hSnapshot);
    return 0;
  }

  bool IsProcessRunning(DWORD processId)
  {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | SYNCHRONIZE, FALSE, processId);
    if (hProcess == NULL)
    {
      return false;
    }

    DWORD exitCode;
    if (GetExitCodeProcess(hProcess, &exitCode))
    {
      CloseHandle(hProcess);
      return (exitCode == STILL_ACTIVE);
    }

    CloseHandle(hProcess);
    return false;
  }

  std::wstring NormalizePath(const wchar_t* path)
  {
    wchar_t normalizedPath[MAX_PATH];
    if (GetFullPathNameW(path, MAX_PATH, normalizedPath, NULL) == 0)
    {
      return std::wstring(path);
    }
    
    wchar_t* longPath = normalizedPath;
    wchar_t longPathBuffer[MAX_PATH * 2];
    if (GetLongPathNameW(normalizedPath, longPathBuffer, MAX_PATH * 2) > 0)
    {
      longPath = longPathBuffer;
    }
    
    for (wchar_t* p = longPath; *p; p++)
    {
      if (*p == L'/')
      {
        *p = L'\\';
      }
      else if (*p >= L'A' && *p <= L'Z')
      {
        *p = *p - L'A' + L'a';
      }
    }
    
    return std::wstring(longPath);
  }

  std::vector<DWORD> FindProcessesByExecutable(const wchar_t* executablePath)
  {
    std::vector<DWORD> pids;
    std::wstring normalizedTargetPath = NormalizePath(executablePath);
    
    HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hSnapshot == INVALID_HANDLE_VALUE)
    {
      return pids;
    }

    PROCESSENTRY32W pe32;
    pe32.dwSize = sizeof(PROCESSENTRY32W);

    if (Process32FirstW(hSnapshot, &pe32))
    {
      do
      {
        if (pe32.th32ProcessID == GetCurrentProcessId())
        {
          continue;
        }

        HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pe32.th32ProcessID);
        if (hProcess != NULL)
        {
          wchar_t processPath[MAX_PATH];
          DWORD pathSize = MAX_PATH;
          if (QueryFullProcessImageNameW(hProcess, 0, processPath, &pathSize))
          {
            std::wstring normalizedProcessPath = NormalizePath(processPath);
            if (normalizedProcessPath == normalizedTargetPath)
            {
              pids.push_back(pe32.th32ProcessID);
            }
          }
          CloseHandle(hProcess);
        }
      } while (Process32NextW(hSnapshot, &pe32));
    }

    CloseHandle(hSnapshot);
    return pids;
  }

  bool WaitForExecutableToBeFree(const wchar_t* executablePath, DWORD timeoutSeconds)
  {
    printf("Verificando se o executável está liberado: %ls\n", executablePath);
    
    DWORD startTime = GetTickCount();
    DWORD timeoutMs = timeoutSeconds * 1000;

    while ((GetTickCount() - startTime) < timeoutMs)
    {
      HANDLE hFile = CreateFileW(executablePath, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
      if (hFile != INVALID_HANDLE_VALUE)
      {
        CloseHandle(hFile);
        printf("Executável está liberado.\n");
        return true;
      }

      DWORD error = GetLastError();
      if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION)
      {
        Sleep(500);
        continue;
      }
      else
      {
        printf("Erro ao verificar arquivo: %lu\n", error);
        return false;
      }
    }

    printf("Timeout aguardando executável ser liberado.\n");
    return false;
  }

  bool KillProcess(DWORD processId)
  {
    HANDLE hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, processId);
    if (hProcess == NULL)
    {
      DWORD error = GetLastError();
      if (error == ERROR_INVALID_PARAMETER)
      {
        printf("Processo %lu já não existe mais.\n", processId);
        return true;
      }
      printf("Não foi possível abrir o processo %lu para encerrar. Erro: %lu\n", processId, error);
      return false;
    }

    printf("Forçando encerramento do processo %lu...\n", processId);
    BOOL result = TerminateProcess(hProcess, 1);
    CloseHandle(hProcess);

    if (result)
    {
      printf("Processo %lu encerrado forçadamente.\n", processId);
      Sleep(1000);
      return true;
    }
    else
    {
      printf("Falha ao encerrar processo %lu. Erro: %lu\n", processId, GetLastError());
      return false;
    }
  }

  void KillAllProcessesByExecutable(const wchar_t* executablePath)
  {
    std::vector<DWORD> processes = FindProcessesByExecutable(executablePath);
    DWORD currentPid = GetCurrentProcessId();

    for (DWORD pid : processes)
    {
      if (pid != currentPid && IsProcessRunning(pid))
      {
        printf("Matando processo %lu...\n", pid);
        KillProcess(pid);
      }
    }
  }

  bool WaitForProcessToExit(DWORD processId, DWORD timeoutSeconds)
  {
    HANDLE hProcess = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_INFORMATION, FALSE, processId);
    if (hProcess == NULL)
    {
      DWORD error = GetLastError();
      if (error == ERROR_INVALID_PARAMETER)
      {
        printf("Processo %lu não existe mais (já encerrado).\n", processId);
        return true;
      }
      printf("Não foi possível abrir o processo %lu. Erro: %lu\n", processId, error);
      return false;
    }

    printf("Aguardando processo %lu encerrar (timeout: %lu segundos)...\n", processId, timeoutSeconds);
    DWORD waitResult = WaitForSingleObject(hProcess, timeoutSeconds * 1000);
    CloseHandle(hProcess);

    if (waitResult == WAIT_OBJECT_0)
    {
      printf("Processo %lu encerrado com sucesso.\n", processId);
      Sleep(1000);
      return true;
    }
    else if (waitResult == WAIT_TIMEOUT)
    {
      printf("Timeout aguardando processo %lu encerrar. Forçando encerramento...\n", processId);
      KillProcess(processId);
      return true;
    }
    else
    {
      printf("Erro ao aguardar processo %lu: %lu. Tentando forçar encerramento...\n", processId, waitResult);
      KillProcess(processId);
      return true;
    }
  }

  void ExecuteElevatedUpdate()
  {
    printf("Executando processo de atualização elevado...\n");
    
    wchar_t executable_path[MAX_PATH];
    GetModuleFileNameW(NULL, executable_path, MAX_PATH);
    printf("Caminho do executável: %ls\n", executable_path);

    DWORD parentPid = g_parentProcessId;
    if (parentPid == 0)
    {
      parentPid = GetParentProcessId();
    }

    std::vector<DWORD> allProcesses = FindProcessesByExecutable(executable_path);
    printf("Encontrados %zu processo(s) usando o executável.\n", allProcesses.size());

    if (parentPid != 0)
    {
      printf("Aguardando processo original (PID: %lu) encerrar...\n", parentPid);
      WaitForProcessToExit(parentPid, 15);
    }

    for (DWORD pid : allProcesses)
    {
      if (pid != GetCurrentProcessId() && IsProcessRunning(pid))
      {
        printf("Aguardando processo adicional (PID: %lu) encerrar...\n", pid);
        WaitForProcessToExit(pid, 10);
      }
    }

    printf("Verificando processos restantes...\n");
    allProcesses = FindProcessesByExecutable(executable_path);
    bool hasRunningProcesses = false;
    for (DWORD pid : allProcesses)
    {
      if (pid != GetCurrentProcessId() && IsProcessRunning(pid))
      {
        hasRunningProcesses = true;
        break;
      }
    }

    if (hasRunningProcesses)
    {
      printf("Ainda há processos rodando. Forçando encerramento de todos...\n");
      KillAllProcessesByExecutable(executable_path);
      Sleep(2000);
    }

    printf("Verificando se o executável está liberado...\n");
    if (!WaitForExecutableToBeFree(executable_path, 15))
    {
      printf("Executável ainda em uso. Forçando encerramento novamente...\n");
      KillAllProcessesByExecutable(executable_path);
      Sleep(2000);
    }

    std::wstring tempUpdateDir = FindTempUpdateDirectory();
    std::wstring updateDir = tempUpdateDir.empty() ? L"update" : tempUpdateDir;
    std::wstring destDir = L".";

    if (!tempUpdateDir.empty())
    {
      printf("Diretório de atualização temporário encontrado: %ls\n", tempUpdateDir.c_str());
    }

    printf("Criando arquivo .bat para atualização...\n");
    createBatFile(updateDir, destDir, executable_path, tempUpdateDir);
    
    printf("Executando arquivo .bat...\n");
    runBatFile();

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

  bool RequestAdminPrivileges()
  {
    wchar_t exePath[MAX_PATH];
    GetModuleFileNameW(NULL, exePath, MAX_PATH);

    DWORD currentPid = GetCurrentProcessId();
    wchar_t args[64];
    swprintf_s(args, 64, L"--update-elevated %lu", currentPid);

    HINSTANCE result = ShellExecuteW(NULL, L"runas", exePath, args, NULL, SW_SHOW);

    if ((INT_PTR)result > 32)
    {
      return true;
    }
    else
    {
      std::wcout << L"Falha ao obter privilégios de administrador. Código de erro: " << (INT_PTR)result << std::endl;
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
    printf("Reiniciando a aplicação...\n");

    if (!IsRunningAsAdmin())
    {
      printf("Não está rodando como administrador. Solicitando elevação...\n");
      
      if (RequestAdminPrivileges())
      {
        printf("Processo elevado iniciado. Encerrando processo atual.\n");
        ExitProcess(0);
      }
      else
      {
        printf("Falha ao obter privilégios de administrador. Atualização cancelada.\n");
        return;
      }
    }

    printf("Rodando com privilégios de administrador. Procedendo com atualização...\n");

    wchar_t executable_path[MAX_PATH];
    GetModuleFileNameW(NULL, executable_path, MAX_PATH);
    printf("Caminho do executável: %ls\n", executable_path);

    DWORD parentPid = GetParentProcessId();
    std::vector<DWORD> allProcesses = FindProcessesByExecutable(executable_path);
    printf("Encontrados %zu processo(s) usando o executável.\n", allProcesses.size());

    if (parentPid != 0 && parentPid != GetCurrentProcessId())
    {
      printf("Aguardando processo original (PID: %lu) encerrar...\n", parentPid);
      WaitForProcessToExit(parentPid, 15);
    }

    for (DWORD pid : allProcesses)
    {
      if (pid != GetCurrentProcessId() && IsProcessRunning(pid))
      {
        printf("Aguardando processo adicional (PID: %lu) encerrar...\n", pid);
        WaitForProcessToExit(pid, 10);
      }
    }

    printf("Verificando processos restantes...\n");
    allProcesses = FindProcessesByExecutable(executable_path);
    bool hasRunningProcesses = false;
    for (DWORD pid : allProcesses)
    {
      if (pid != GetCurrentProcessId() && IsProcessRunning(pid))
      {
        hasRunningProcesses = true;
        break;
      }
    }

    if (hasRunningProcesses)
    {
      printf("Ainda há processos rodando. Forçando encerramento de todos...\n");
      KillAllProcessesByExecutable(executable_path);
      Sleep(2000);
    }

    printf("Verificando se o executável está liberado...\n");
    if (!WaitForExecutableToBeFree(executable_path, 15))
    {
      printf("Executável ainda em uso. Forçando encerramento novamente...\n");
      KillAllProcessesByExecutable(executable_path);
      Sleep(2000);
    }

    std::wstring tempUpdateDir = FindTempUpdateDirectory();
    std::wstring updateDir = tempUpdateDir.empty() ? L"update" : tempUpdateDir;
    std::wstring destDir = L".";

    if (!tempUpdateDir.empty())
    {
      printf("Diretório de atualização temporário encontrado: %ls\n", tempUpdateDir.c_str());
    }

    printf("Criando arquivo .bat para atualização...\n");
    createBatFile(updateDir, destDir, executable_path, tempUpdateDir);

    printf("Executando arquivo .bat...\n");
    runBatFile();

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
