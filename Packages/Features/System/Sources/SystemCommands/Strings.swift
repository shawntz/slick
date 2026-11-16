import Foundation
import Kit

/// Every string a person reads in this feature, in one place so it can be translated later.
/// Command, action, section, empty-state, toast and HUD titles, buttons and menu items use title
/// case, as macOS menus do. Everything else is a plain sentence that says what will happen or what
/// happened. Key combinations come from `KeyCombo.displayString`.
nonisolated enum Strings {
    // MARK: - Feature

    static let featureName = "System"
    static let featureSummary =
        "Sleep, lock or restart your Mac, empty the Trash, change the volume and quit stuck processes."

    static func errorCode(_ code: Int32) -> String {
        "macOS returned error \(code)."
    }

    static let protectedMessage = "macOS needs this process to keep your session running."

    // MARK: - Power and session

    enum Power {
        static let sleep = "Sleep"
        static let sleepKeywords = ["suspend", "standby", "nap", "power"]
        static let sleepDisplays = "Sleep Displays"
        static let sleepDisplaysKeywords = [
            "sleepdisplays", "display off", "screen off", "monitor off", "blank screen",
        ]
        static let lockScreen = "Lock Screen"
        static let lockScreenKeywords = ["lock", "lock mac", "away", "secure"]
        static let startScreenSaver = "Start Screen Saver"
        static let startScreenSaverKeywords = ["screensaver", "screen saver"]
        static let logOut = "Log Out"
        static let logOutKeywords = ["logout", "log off", "sign out", "end session"]
        static let restart = "Restart"
        static let restartKeywords = ["reboot", "restart mac", "relaunch"]
        static let shutDown = "Shut Down"
        static let shutDownKeywords = ["shutdown", "power off", "turn off", "halt"]

        static let sessionMessage = "Your apps will quit. An app with unsaved changes may ask you to save first."
        static let logOutQuestion = "Log out now?"
        static let restartQuestion = "Restart your Mac now?"
        static let shutDownQuestion = "Shut down your Mac now?"

        static let loggingOut = "Logging Out"
        static let restarting = "Restarting"
        static let shuttingDown = "Shutting Down"

        static func words(for request: PowerRequest) -> FailureWords {
            switch request {
            case .sleep:
                FailureWords(
                    failed: "Your Mac Could Not Go to Sleep", unavailable: "Sleep Is Not Available on This Mac")
            case .sleepDisplays:
                FailureWords(
                    failed: "The Displays Could Not Go to Sleep",
                    unavailable: "Sleep Displays Is Not Available on This Mac")
            case .lockScreen:
                FailureWords(
                    failed: "The Screen Could Not Be Locked",
                    unavailable: "Lock Screen Is Not Available in This Version of macOS",
                    unavailableMessage: "macOS no longer has the function the app uses to lock the screen. Press "
                        + KeyCombo(.q, [.control, .command]).displayString + " to lock it instead.")
            case .startScreenSaver:
                FailureWords(
                    failed: "The Screen Saver Could Not Start",
                    unavailable: "The Screen Saver Is Not Available on This Mac")
            case .logOut:
                FailureWords(failed: "Could Not Log Out", unavailable: "Log Out Is Not Available Right Now")
            case .restart:
                FailureWords(failed: "Could Not Restart", unavailable: "Restart Is Not Available Right Now")
            case .shutDown:
                FailureWords(failed: "Could Not Shut Down", unavailable: "Shut Down Is Not Available Right Now")
            }
        }
    }

    // MARK: - Housekeeping

    enum Trash {
        static let openTitle = "Open Trash"
        static let openKeywords = ["trash", "show trash", "bin", "deleted files"]
        static let notOpened = "The Trash Could Not Be Opened"
        static let title = "Empty Trash"
        static let keywords = ["emptytrash", "delete trash", "clear trash", "bin", "rubbish"]
        static let alreadyEmpty = "The Trash Is Already Empty"
        static let question = "Empty the Trash?"
        static let confirm = "Empty Trash"
        static let stillEmptying = "Finder Is Still Emptying the Trash"
        static let words = FailureWords(
            failed: "The Trash Could Not Be Emptied", unavailable: "Empty Trash Is Not Available on This Mac",
            notFound: "Finder Is Not Running")

        /// The question's message, with the number of items when Finder gave one.
        static func message(items: Int?) -> String {
            switch items {
            case nil: "Every item in the Trash will be deleted forever. You can't undo this."
            case 1: "The item in the Trash will be deleted forever. You can't undo this."
            case let count?: "The \(count) items in the Trash will be deleted forever. You can't undo this."
            }
        }

        static func emptied(items: Int?) -> String {
            switch items {
            case nil: "Emptied the Trash"
            case 1: "Deleted 1 Item from the Trash"
            case let count?: "Deleted \(count) Items from the Trash"
            }
        }
    }

    enum Eject {
        static let title = "Eject All Disks"
        static let keywords = ["ejectall", "eject", "unmount", "drives", "volumes", "disk images"]
        static let nothingToEject = "No Disks to Eject"
        static let confirm = "Eject"
        static let words = FailureWords(
            failed: "Could Not Eject the Disks", unavailable: "Eject All Disks Is Not Available on This Mac")

        static func question(disks: Int) -> String {
            disks == 1 ? "Eject 1 disk?" : "Eject \(disks) disks?"
        }

        static func message(names: [String], locale: Locale) -> String {
            "This ejects " + names.formatted(.list(type: .and).locale(locale)) + "."
        }

        static func ejected(names: [String], locale: Locale) -> String {
            "Ejected " + names.formatted(.list(type: .and).locale(locale))
        }

        static func notEjected(names: [String], locale: Locale) -> String {
            "Could Not Eject " + names.formatted(.list(type: .and).locale(locale))
        }

        static let notEjectedReason = "A disk in use cannot be ejected. Quit the apps that use it and try again."
    }

    enum HiddenFiles {
        static let title = "Toggle Hidden Files"
        static let keywords = [
            "show hidden files", "hide hidden files", "dotfiles", "invisible files", "finder", "show all files",
        ]
        static let words = FailureWords(
            failed: "Finder's Hidden Files Setting Could Not Be Changed",
            unavailable: "Finder Is Not Available on This Mac")

        /// What the HUD says once the setting is written. Finder applies it when it restarts; a
        /// busy Finder that did not quit applies it the next time it opens.
        static func done(shows: Bool, finderRestarted: Bool) -> String {
            switch (shows, finderRestarted) {
            case (true, true): "Finder Now Shows Hidden Files"
            case (false, true): "Finder Now Hides Hidden Files"
            case (true, false): "Finder Shows Hidden Files the Next Time It Opens"
            case (false, false): "Finder Hides Hidden Files the Next Time It Opens"
            }
        }
    }

    // MARK: - Appearance

    enum Appearance {
        static let title = "Toggle Dark Mode"
        static let keywords = ["dark mode", "light mode", "appearance", "theme", "night mode"]
        // scenarios/system-commands.json checks the dark one.
        static let dark = "Switched to Dark Mode"
        static let light = "Switched to Light Mode"
        static let words = FailureWords(
            failed: "The Appearance Could Not Be Changed", unavailable: "System Events Is Not Available on This Mac")
    }

    // MARK: - Sound

    enum Sound {
        static let mute = "Mute"
        static let muteKeywords = ["silence", "sound off", "quiet", "volume"]
        static let unmute = "Unmute"
        static let unmuteKeywords = ["sound on", "volume"]
        static let toggleMute = "Toggle Mute"
        static let toggleMuteKeywords = ["mute", "unmute", "sound", "volume"]
        static let volumeUp = "Volume Up"
        static let volumeUpKeywords = ["volup", "louder", "increase volume", "sound up"]
        static let volumeDown = "Volume Down"
        static let volumeDownKeywords = ["voldown", "quieter", "softer", "decrease volume", "sound down"]
        static let setVolume = "Set Volume"
        static let setVolumeKeywords = ["volume", "sound level", "loudness"]
        static let levelPlaceholder = "0 to 100"

        static let muted = "Sound Muted"
        static let unmuted = "Sound Unmuted"

        static func volume(_ percent: Int) -> String {
            "Volume \(percent)%"
        }

        static let invalidLevel = "Enter a Volume from 0 to 100"
        static let invalidLevelHint = "For example, 40 or 40%."
        static let noOutput = "No Sound Output to Change"
        static let noVolumeControl = "This Output Device Has No Volume Control"
        static let cannotMute = "This Output Device Cannot Be Muted"
        static let volumeWords = FailureWords(failed: "The Volume Could Not Be Changed", unavailable: noVolumeControl)
        static let muteWords = FailureWords(failed: "The Sound Could Not Be Muted or Unmuted", unavailable: cannotMute)
    }

    // MARK: - Processes

    enum Processes {
        static let title = "Kill Process"
        static let keywords = [
            "force quit", "task manager", "activity monitor", "processes", "cpu", "memory", "top", "end task",
        ]
        static let searchPlaceholder = "Search processes"
        static let section = "Processes"
        static let empty = "No Processes"
        static let sortTitle = "Sort By"

        static func sortOption(_ sort: ProcessSort) -> String {
            switch sort {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .name: "Name"
            }
        }

        static func subtitle(pid: Int32) -> String {
            "PID \(pid)"
        }

        /// The title of a process whose name the system does not give.
        static func unnamed(pid: Int32) -> String {
            "Process \(pid)"
        }

        static func cpu(_ percent: Double, locale: Locale) -> String {
            percent.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "% CPU"
        }

        static func memory(_ bytes: UInt64, locale: Locale) -> String {
            let megabytes = Double(bytes) / 1_048_576
            if megabytes >= 1_024 {
                return (megabytes / 1_024).formatted(.number.precision(.fractionLength(2)).locale(locale)) + " GB"
            }
            return megabytes.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " MB"
        }

        static let quit = "Quit Process"
        static let forceQuit = "Force Quit Process"
        static let copyPID = "Copy Process ID"
        static let copiedPID = "Copied Process ID"
        static let refresh = "Refresh"

        static func quitQuestion(_ name: String) -> String {
            "Quit \(name)?"
        }

        static func quitMessage(isApplication: Bool) -> String {
            isApplication
                ? "The app may ask you to save changes first."
                : "The process is asked to stop, and gets a moment to finish its work."
        }

        static func forceQuitQuestion(_ name: String) -> String {
            "Force quit \(name)?"
        }

        static func forceQuitMessage(_ name: String) -> String {
            "\(name) stops at once. Anything it has not saved is lost."
        }

        static let quitConfirm = "Quit"
        static let forceQuitConfirm = "Force Quit"

        static func askedToQuit(_ name: String) -> String {
            "Asked \(name) to Quit"
        }

        static func forcedToQuit(_ name: String) -> String {
            "Forced \(name) to Quit"
        }

        static func words(quitting name: String) -> FailureWords {
            FailureWords(
                failed: "Could Not Quit \(name)", unavailable: "Could Not Quit \(name)",
                notFound: "\(name) Has Already Quit")
        }
    }

    // MARK: - Settings

    enum Settings {
        static let sound = "Sound"
        static let volumeStep = "Volume step"
        static let volumeStepInfo = "How far Volume Up and Volume Down move the volume."

        static func volumeStepOption(_ step: VolumeStep) -> String {
            switch step {
            case .keys: "Same as the Volume Keys"
            case .fivePercent: "5 Percent"
            case .tenPercent: "10 Percent"
            }
        }

        static let disks = "Disks"
        static let ejectsNetworkVolumes = "Eject network volumes"
        static let ejectsNetworkVolumesInfo = "Eject All Disks also disconnects from servers."
        static let neverEject = "Never eject"
        static let neverEjectPlaceholder = "Disk name"
        static let neverEjectInfo =
            "Eject All Disks leaves disks with these names mounted. Use * for any text, as in Backup*."

        static let processes = "Kill Process"
        static let sortBy = "Sort by"
        static let sortByInfo =
            "The order the list opens in. Press \(KeyCombo(.p, .command).displayString) in the list to change it there."
        static let refresh = "Refresh every"
        static let refreshInfo = "The list updates CPU and memory use this often while it is open."

        static func refreshOption(_ refresh: ProcessRefresh) -> String {
            switch refresh {
            case .oneSecond: "1 Second"
            case .twoSeconds: "2 Seconds"
            case .fiveSeconds: "5 Seconds"
            }
        }

        static let showsBackground = "Show background processes"
        static let showsBackgroundInfo = "Turn this off to list only apps with a Dock icon."

        static let permissions = "Permissions"
        static let finderInfo = "Empty Trash needs it, because Finder counts and empties the Trash."
        static let systemEventsInfo =
            "Toggle Dark Mode needs it, because macOS changes the appearance through System Events."
        static let loginWindowInfo = "Log Out, Restart and Shut Down may need it on some Macs."
        static let confirmationsNote =
            "Log Out, Restart, Shut Down, Empty Trash and quitting a process always ask before they run."
    }

    // MARK: - Permission reasons

    enum Reasons {
        static let finder = "Count and empty the Trash through Finder."
        static let systemEvents = "Switch between light and dark appearance through System Events."
        static let loginWindow = "Ask macOS to log out, restart or shut down."
    }
}
