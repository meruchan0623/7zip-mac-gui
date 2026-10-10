Run from any working directory:

    scripts/check-integration.sh
    scripts/build-app.sh
    scripts/build-app.sh --universal --finder-extension
    scripts/verify-app.sh
    scripts/install-app.sh

The default build targets Apple Silicon and produces build/7zip Mac.app.
--universal builds each architecture separately and combines the executables.
The original engine is retained byte-for-byte in Contents/Resources/Upstream;
the runnable engine copy is ad-hoc signed. Only generated build products have
download quarantine removed. Original upstream files remain untouched.

The app includes the engine, complete upstream manual and licenses, an icon,
archive type declarations, ten Services actions, and sevenzipmac URL handling.
Archive associations remain unchanged unless requested explicitly in the app.

Installation is an explicit separate command. It preserves an existing app with
the same identifier as a dated backup and refuses to replace a different app.
It updates Launch Services and Services registrations and opens the app. Optional
Finder Sync activation requires a separate user action; see FinderExtension.
Local signing is not Developer ID signing or notarization.
