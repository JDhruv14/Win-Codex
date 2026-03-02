; Superset for Windows — NSIS Installer Script
; Builds a proper Windows installer from the portable Superset build.
;
; Prerequisites:
;   1. Run `scripts\run-superset.ps1 -BuildExe -NoLaunch` first to create the portable build
;   2. Install NSIS (https://nsis.sourceforge.io/)
;   3. Run: makensis installer\superset-installer.nsi
;
; The installer packages the portable build into a standard Windows installer
; with Start Menu shortcuts, uninstaller, and Add/Remove Programs entry.

!include "MUI2.nsh"
!include "FileFunc.nsh"

; ── Build configuration ──────────────────────────────────────────────────────

!define PRODUCT_NAME "Superset"
!define PRODUCT_PUBLISHER "superset.sh"
!define PRODUCT_WEB_SITE "https://superset.sh"
!define PRODUCT_DIR_REGKEY "Software\${PRODUCT_NAME}"
!define PRODUCT_UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"

; Source directory — the portable build output from run-superset.ps1 -BuildExe
!define SOURCE_DIR "..\work-superset\packaged\Superset-win32-x64"

; ── Installer metadata ───────────────────────────────────────────────────────

Name "${PRODUCT_NAME}"
OutFile "..\Superset-Setup.exe"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey HKLM "${PRODUCT_DIR_REGKEY}" ""
RequestExecutionLevel admin
SetCompressor /SOLID lzma
SetCompressorDictSize 64

; ── Version info (read from app if available) ────────────────────────────────

VIProductVersion "1.0.4.0"
VIAddVersionKey "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey "CompanyName" "${PRODUCT_PUBLISHER}"
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} Installer"
VIAddVersionKey "FileVersion" "1.0.4"
VIAddVersionKey "LegalCopyright" "Apache-2.0"

; ── MUI configuration ────────────────────────────────────────────────────────

!define MUI_ABORTWARNING
!define MUI_ICON "${SOURCE_DIR}\resources\app\resources\build\icons\icon.ico"
!define MUI_UNICON "${SOURCE_DIR}\resources\app\resources\build\icons\icon.ico"

; Welcome page
!insertmacro MUI_PAGE_WELCOME

; License page
!define MUI_LICENSEPAGE_CHECKBOX
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"

; Directory page
!insertmacro MUI_PAGE_DIRECTORY

; Install files page
!insertmacro MUI_PAGE_INSTFILES

; Finish page — offer to launch
!define MUI_FINISHPAGE_RUN "$INSTDIR\${PRODUCT_NAME}.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch ${PRODUCT_NAME}"
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; Language
!insertmacro MUI_LANGUAGE "English"

; ── Install section ──────────────────────────────────────────────────────────

Section "Install"
  SetOutPath "$INSTDIR"

  ; Copy the entire portable build
  File /r "${SOURCE_DIR}\*.*"

  ; Write registry keys
  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "" "$INSTDIR"
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayIcon" "$INSTDIR\${PRODUCT_NAME}.exe"
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "URLInfoAbout" "${PRODUCT_WEB_SITE}"
  WriteRegStr HKLM "${PRODUCT_UNINST_KEY}" "DisplayVersion" "1.0.4"
  WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "NoRepair" 1

  ; Calculate and write install size
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${PRODUCT_UNINST_KEY}" "EstimatedSize" "$0"

  ; Create uninstaller
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Create Start Menu shortcuts
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_NAME}.exe" "" "$INSTDIR\${PRODUCT_NAME}.exe" 0
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0

  ; Create Desktop shortcut
  CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_NAME}.exe" "" "$INSTDIR\${PRODUCT_NAME}.exe" 0

  ; Register superset:// protocol handler
  WriteRegStr HKCR "superset" "" "URL:Superset Protocol"
  WriteRegStr HKCR "superset" "URL Protocol" ""
  WriteRegStr HKCR "superset\DefaultIcon" "" "$INSTDIR\${PRODUCT_NAME}.exe,0"
  WriteRegStr HKCR "superset\shell\open\command" "" '"$INSTDIR\${PRODUCT_NAME}.exe" "%1"'
SectionEnd

; ── Uninstall section ────────────────────────────────────────────────────────

Section "Uninstall"
  ; Kill running instances
  nsExec::Exec 'taskkill /f /im "${PRODUCT_NAME}.exe"'

  ; Remove files (entire install directory)
  RMDir /r "$INSTDIR"

  ; Remove Start Menu shortcuts
  RMDir /r "$SMPROGRAMS\${PRODUCT_NAME}"

  ; Remove Desktop shortcut
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"

  ; Remove registry keys
  DeleteRegKey HKLM "${PRODUCT_UNINST_KEY}"
  DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"

  ; Remove protocol handler
  DeleteRegKey HKCR "superset"
SectionEnd
