param(
  [string]$ResultPath,
  [string]$Title,
  [string]$InitialFolder,
  [switch]$ForceInitialFolder,
  [switch]$TestMode,
  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace YbReference
{
    [Flags]
    internal enum FileOpenOptions : uint
    {
        PickFolders = 0x00000020,
        ForceFileSystem = 0x00000040,
        PathMustExist = 0x00000800
    }

    internal enum ShellDisplayName : uint
    {
        FileSystemPath = 0x80058000
    }

    [ComImport]
    [Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(ShellDisplayName sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport]
    [Guid("42F85136-DB7E-439C-85F1-E4075D135FC8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr filterSpec);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(FileOpenOptions options);
        void GetOptions(out FileOpenOptions options);
        void SetDefaultFolder(IShellItem folder);
        void SetFolder(IShellItem folder);
        void GetFolder(out IShellItem folder);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, uint alignment);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
    }

    [ComImport]
    [Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    [ClassInterface(ClassInterfaceType.None)]
    internal class FileOpenDialog { }

    public static class FolderPicker
    {
        private static readonly Guid ClientGuid =
            new Guid("721D38DA-7927-49A6-91E6-C3D4B0D2C475");
        private static readonly Guid ShellItemGuid =
            new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(
            string path, IntPtr bindContext, ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        public static string Pick(string title, string initialFolder, bool forceInitialFolder)
        {
            IFileDialog dialog = (IFileDialog)new FileOpenDialog();
            IShellItem initialItem = null;
            IShellItem result = null;
            try
            {
                Guid client = ClientGuid;
                dialog.SetClientGuid(ref client);

                FileOpenOptions options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FileOpenOptions.PickFolders |
                    FileOpenOptions.ForceFileSystem | FileOpenOptions.PathMustExist);
                dialog.SetTitle(title);
                dialog.SetOkButtonLabel("Select Folder");

                if (!String.IsNullOrWhiteSpace(initialFolder))
                {
                    try
                    {
                        Guid shellItem = ShellItemGuid;
                        SHCreateItemFromParsingName(initialFolder, IntPtr.Zero,
                            ref shellItem, out initialItem);
                        if (forceInitialFolder) dialog.SetFolder(initialItem);
                        else dialog.SetDefaultFolder(initialItem);
                    }
                    catch
                    {
                        // A missing remembered drive is exactly when the picker is
                        // needed. Windows' remembered/default location can take over.
                    }
                }

                int shown = dialog.Show(GetForegroundWindow());
                const int Cancelled = unchecked((int)0x800704C7);
                if (shown == Cancelled) return null;
                if (shown != 0) Marshal.ThrowExceptionForHR(shown);

                dialog.GetResult(out result);
                IntPtr raw;
                result.GetDisplayName(ShellDisplayName.FileSystemPath, out raw);
                try { return Marshal.PtrToStringUni(raw); }
                finally { Marshal.FreeCoTaskMem(raw); }
            }
            finally
            {
                if (result != null && !Object.ReferenceEquals(result, initialItem))
                    Marshal.FinalReleaseComObject(result);
                if (initialItem != null) Marshal.FinalReleaseComObject(initialItem);
                Marshal.FinalReleaseComObject(dialog);
            }
        }
    }
}
'@

if ($ValidateOnly) { exit 0 }

function Write-Result([string]$Value) {
  $pendingPath = "$ResultPath.tmp"
  [IO.File]::WriteAllText($pendingPath, $Value, [Text.UTF8Encoding]::new($false))
  if ([IO.File]::Exists($ResultPath)) { [IO.File]::Delete($ResultPath) }
  [IO.File]::Move($pendingPath, $ResultPath)
}

try {
  $selected = if ($TestMode) { $InitialFolder } else {
    [YbReference.FolderPicker]::Pick(
      $Title, $InitialFolder, $ForceInitialFolder.IsPresent)
  }
  $value = if ($null -eq $selected) { 'CANCEL' } else { "OK`n$selected" }
  Write-Result $value
} catch {
  Write-Result "ERROR`n$($_.Exception.Message)"
  exit 1
}
