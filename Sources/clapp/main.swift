import ArgumentParser

struct CLAPPCleaner: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clapp",
        abstract: "CLAPP Cleaner — Command Line-based APP Cleaner",
        discussion: "Interactively list and uninstall macOS apps along with their associated library files.",
        version: "1.0.0"
    )

    @Flag(name: .shortAndLong, help: "Move deleted apps to Trash instead of permanently deleting them.")
    var trash = false

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt before deleting.")
    var yes = false

    @Flag(name: .long, help: "Include Apple first-party system apps in the list (hidden by default).")
    var showSystem = false

    mutating func run() throws {
        let ui = CleanerUI(useTrash: trash, skipConfirm: yes, showSystem: showSystem)
        ui.start()
    }
}

CLAPPCleaner.main()
