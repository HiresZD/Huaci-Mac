-- All paths arrive as arguments; application/user paths are never script text.
on run arguments
    if (count of arguments) is not 1 then error "Missing installer mount path."
    set mountPath to item 1 of arguments
    set installerFolder to (POSIX file mountPath) as alias

    -- Finder automation is the only additional permission used. There is no
    -- System Events UI scripting and no change to global Finder preferences.
    with timeout of 8 seconds
        tell application "Finder"
            open installerFolder
            set installerWindow to container window of installerFolder
            set current view of installerWindow to icon view
            try
                set sidebar width of installerWindow to 0
            end try
            set toolbar visible of installerWindow to false
            set statusbar visible of installerWindow to false
            -- 640 pt wide, with approximately 400 pt of content below the
            -- compact title bar. Icon positions use content coordinates.
            set bounds of installerWindow to {200, 150, 840, 578}

            set viewOptions to icon view options of installerWindow
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set label position of viewOptions to bottom
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to false
            set background picture of viewOptions to file ".background:background.png" of installerFolder
            set position of item "Huaci.app" of installerFolder to {160, 216}
            set position of item "Applications" of installerFolder to {480, 216}
            update installerFolder without registering applications

            -- Closing and briefly reopening gives Finder an opportunity to
            -- persist this volume's view without affecting other windows.
            close installerWindow
            delay 0.2
            open installerFolder
            set installerWindow to container window of installerFolder
            update installerFolder without registering applications
            delay 0.2
            close installerWindow
        end tell
    end timeout
end run
