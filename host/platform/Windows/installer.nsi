/**
 * Looking Glass
 * Copyright © 2017-2025 The Looking Glass Authors
 * https://looking-glass.io
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 2 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc., 59
 * Temple Place, Suite 330, Boston, MA 02111-1307 USA
 */

;Include
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"
!include "Sections.nsh"

;Settings
Name "IDDShm Host"
OutFile "IDDShmHost-Setup.exe"
Unicode true
RequestExecutionLevel admin
ShowInstDetails "show"
ShowUninstDetails "show"
ManifestDPIAware true

!ifndef BUILD_32BIT
Target AMD64-Unicode
InstallDir "$PROGRAMFILES\IDDShm Host"
!else
InstallDir "$PROGRAMFILES64\IDDShm Host"
!endif

!define MUI_ICON "icon.ico"
!define MUI_UNICON "icon.ico"
!define MUI_LICENSEPAGE_BUTTON "Agree"
!define MUI_BGCOLOR "3c046c"
!define MUI_TEXTCOLOR "ffffff"
!define MUI_WELCOMEFINISHPAGE_BITMAP "${NSISDIR}\Contrib\Graphics\Wizard\nsis3-grey.bmp"
!define /file VERSION "../../VERSION"

!define MUI_WELCOMEPAGE_TEXT "You are about to install $(^Name) version ${VERSION}.$\r$\n$\r$\nWhen upgrading, you don't need to close your IDDShm client, but should install the ${VERSION} client after installation is complete.$\r$\n$\r$\nPress Next to continue."

;Install and uninstall pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "LICENSE.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"


Function ShowHelpMessage
  !define line1 "Command line options:$\r$\n$\r$\n"
  !define line2 "/S - silent install (must be uppercase)$\r$\n"
  !define line3 "/D=path\to\install\folder - Change install directory$\r$\n"
  !define line4 "   (Must be uppercase, the last option given and no quotes)$\r$\n$\r$\n"
  !define line5 "/startmenu - create start menu shortcut$\r$\n"
  !define line6 "/desktop - create desktop shortcut$\r$\n"
  !define line7 "/noservice - do not create a service to auto start and elevate the host"
  MessageBox MB_OK "${line1}${line2}${line3}${line4}${line5}${line6}${line7}"
  Abort
FunctionEnd

Function .onInit

  var /GLOBAL cmdLineParams
  Push $R0
  ${GetParameters} $cmdLineParams
  ClearErrors

  ${GetOptions} $cmdLineParams '/?' $R0
  IfErrors +2 0
  Call ShowHelpMessage

  ${GetOptions} $cmdLineParams '/H' $R0
  IfErrors +2 0
  Call ShowHelpMessage

  Pop $R0


  Var /GLOBAL option_startMenu
  Var /GLOBAL option_desktop
  Var /GlOBAL option_noservice
  StrCpy $option_startMenu     0
  StrCpy $option_desktop       0
  StrCpy $option_noservice     0

!ifdef IVSHMEM
  Var /GlOBAL option_driver
  StrCpy $option_driver        0
!endif

  Push $R0

  ${GetOptions} $cmdLineParams '/startmenu' $R0
  IfErrors +2 0
  StrCpy $option_startMenu 1

  ${GetOptions} $cmdLineParams '/desktop' $R0
  IfErrors +2 0
  StrCpy $option_desktop 1

  ${GetOptions} $cmdLineParams '/noservice' $R0
  IfErrors +2 0
  StrCpy $option_noservice 1

!ifdef IVSHMEM
  ${GetOptions} $cmdLineParams '/driver' $R0
  IfErrors +2 0
  StrCpy $option_driver 1
!endif

  Pop $R0

FunctionEnd

!macro StopIDDShmService
  ;Attempt to stop existing LG service only if it exists

  nsExec::Exec 'sc.exe query "IDDShm Host"'
  Pop $0 ; SC.exe error level

  ${If} $0 == 0 ; If error level is 0, service exists
    DetailPrint "Stop service: IDDShm Host"
    nsExec::ExecToLog 'net.exe STOP "IDDShm Host"'
  ${EndIf}

!macroend

;Install 
!ifdef IVSHMEM
Section "IVSHMEM Driver" Section0
  StrCpy $option_driver 1
SectionEnd

Section "-IVSHMEM Driver"
  ${If} $option_driver == 1
    DetailPrint "Extracting IVSHMEM driver"
    SetOutPath $INSTDIR
    File ..\..\ivshmem\ivshmem.cat
    File ..\..\ivshmem\ivshmem.inf
    File ..\..\ivshmem\ivshmem.sys
    File /nonfatal ..\..\ivshmem\ivshmem.pdb

    DetailPrint "Installing IVSHMEM driver"
    nsExec::ExecToLog '"$SYSDIR\pnputil.exe" /add-driver "$INSTDIR\ivshmem.inf" /install'
  ${EndIf}
SectionEnd
!endif

Section "-Install" Section1

  !insertmacro StopIDDShmService

  SetOutPath $INSTDIR
  File ..\..\IDDShmHost.exe
  File /nonfatal ..\..\IDDShmHost.pdb
  File LICENSE.txt
  WriteUninstaller $INSTDIR\uninstaller.exe

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "EstimatedSize" "$0"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "DisplayName" "IDDShm Host"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "UninstallString" "$\"$INSTDIR\uninstaller.exe$\""
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "QuietUninstallString" "$\"$INSTDIR\uninstaller.exe$\" /S"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "Publisher" "Microsoft"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "DisplayIcon" "$\"$INSTDIR\IDDShmHost.exe$\""
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "NoRepair" "1"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "NoModify" "1"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host" \
  "DisplayVersion" ${VERSION}

SectionEnd

Section "IDDShm Host Service" Section2

  ${If} $option_noservice == 0
    DetailPrint "Install service: IDDShm Host"
    nsExec::Exec '"$INSTDIR\IDDShmHost.exe" UninstallService'
    nsExec::ExecToLog '"$INSTDIR\IDDShmHost.exe" InstallService'
  ${EndIf}

SectionEnd

Section /o "Desktop Shortcut" Section3
  StrCpy $option_desktop 1
SectionEnd

Section "Start Menu Shortcut" Section4
  StrCpy $option_startMenu 1
SectionEnd

Section "-Hidden Start Menu" Section5
  SetShellVarContext all

  ${If} $option_startMenu == 1
    CreateDirectory "$APPDATA\IDDShm Host"
    CreateDirectory "$SMPROGRAMS\IDDShm Host"
    CreateShortCut "$SMPROGRAMS\IDDShm Host\IDDShm Host.lnk" $INSTDIR\IDDShmHost.exe
    CreateShortCut "$SMPROGRAMS\IDDShm Host\IDDShm Logs.lnk" "$APPDATA\IDDShm Host"
  ${EndIf}

  ${If} $option_desktop == 1
    CreateShortCut "$DESKTOP\IDDShm Host.lnk" $INSTDIR\IDDShmHost.exe
  ${EndIf}
SectionEnd

Section "Uninstall" Section6
  SetShellVarContext all

  !insertmacro StopIDDShmService

  DetailPrint "Uninstall service: IDDShm Host"
  nsExec::ExecToLog '"$INSTDIR\IDDShmHost.exe" UninstallService'

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\IDDShm Host"
  Delete "$SMPROGRAMS\IDDShm Host.lnk"
  Delete "$DESKTOP\IDDShm Host.lnk"
  Delete "$INSTDIR\uninstaller.exe"
  Delete "$INSTDIR\IDDShmHost.exe"
  Delete "$INSTDIR\IDDShmHost.pdb"
  Delete "$INSTDIR\ivshmem.cat"
  Delete "$INSTDIR\ivshmem.inf"
  Delete "$INSTDIR\ivshmem.sys"
  Delete "$INSTDIR\ivshmem.pdb"
  Delete "$INSTDIR\LICENSE.txt"

  RMDir $INSTDIR
SectionEnd

;Description text for selection of install items
LangString DESC_Section0 ${LANG_ENGLISH} "Install the IVSHMEM driver. This driver is needed for IDDShm to function. This will replace the driver if it is already installed."
LangString DESC_Section1 ${LANG_ENGLISH} "Install Files into $INSTDIR"
LangString DESC_Section2 ${LANG_ENGLISH} "Install service to automatically start IDDShm Host."
LangString DESC_Section3 ${LANG_ENGLISH} "Create desktop shortcut icon."
LangString DESC_Section4 ${LANG_ENGLISH} "Create start menu shortcut."

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
!ifdef IVSHMEM
  !insertmacro MUI_DESCRIPTION_TEXT ${Section0} $(DESC_Section0)
!endif
  !insertmacro MUI_DESCRIPTION_TEXT ${Section1} $(DESC_Section1)
  !insertmacro MUI_DESCRIPTION_TEXT ${Section2} $(DESC_Section2)
  !insertmacro MUI_DESCRIPTION_TEXT ${Section3} $(DESC_Section3)
  !insertmacro MUI_DESCRIPTION_TEXT ${Section4} $(DESC_Section4)
!insertmacro MUI_FUNCTION_DESCRIPTION_END
