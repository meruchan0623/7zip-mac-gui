The optional Finder Sync extension provides a 7zip submenu under the
current user's home folder and /Volumes. Build with:

    scripts/build-app.sh --finder-extension

After installing the containing app, explicitly enable the extension in macOS
System Settings → Extensions (on newer macOS, General → Login Items & Extensions
→ Finder). Locations and wording vary by macOS release. Inspect registration:

    pluginkit -m -v -i local.sevenzip.mac.finder

The extension's Objective-C principal is SevenZipFinderSync. Its executable is
linked against the system NSExtensionMain, not a standalone NSApplication main.
It forwards selected paths through validated sevenzipmac URLs; the containing
application performs all archive operations.

A registration listing is not proof of activation or a visible Finder menu.
The extension is locally ad-hoc signed; distributed builds need an appropriate
signing identity and provisioning. Apple explicitly states that Finder Sync is
intended for file synchronization apps, not general Finder customization:
https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html

Finder Services are the supported default integration and do not depend on this
optional extension. Enable 7zip entries under Keyboard → Keyboard
Shortcuts → Services, then right-click selected files → Services.

The submenu reads the GUI uiLanguage preference whenever it opens (Simplified
Chinese, Traditional Chinese, or English). Read-only access to the containing
app preference domain is declared in the extension sandbox entitlements.
macOS Services labels are localized by macOS rather than this submenu.
