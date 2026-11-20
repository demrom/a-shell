//
//  SceneDelegate+TerminalView.swift
//  a-Shell
//
//  Created by Nicolas Holzschuch on 24/12/2025.
//  Copyright © 2025 AsheKube. All rights reserved.
//
import SwiftTerm // for the terminal window
import ios_system
import TipKit // for helpful tips

@_silgen_name("ashell_interrupt_foreground")
private func interruptForeground() -> Int32

#if HERDR_EMBEDDED
@_silgen_name("herdr_ios_resize")
private func herdrResize(_ cols: UInt16, _ rows: UInt16)
#endif

extension SceneDelegate {
    
    func longestCommonPrefix(_ strs: [String]) -> String {
        guard let first = strs.first else { return "" }
        
        var prefix = first
        
        for str in strs {
            while !str.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        
        return prefix
    }
    
    func fillAutocompleteSuggestions(command: String) {
        var mainCommand = command
        autocompleteSuggestions = []
        autocompletePosition = 0
        autocompleteOptions = false
        if (currentCommand != "") && (!currentCommand.hasPrefix("dash")) && (!currentCommand.hasPrefix("sh")) {
            // a command is running, suggestions are only from command history
            for suggestion in commandHistory {
                if suggestion.hasPrefix(command) {
                    var shortenedSugg = suggestion
                    shortenedSugg.removeFirst(command.count)
                    if !autocompleteSuggestions.contains(shortenedSugg) && (shortenedSugg.count > 0) {
                        autocompleteSuggestions.append(shortenedSugg)
                    }
                }
            }
            // the last command entered is the suggestion:
            autocompletePosition = autocompleteSuggestions.count - 1
        } else {
            // no commands are running:
            // suggestions are history + available commands
            for suggestion in history.reversed() { // reversed so the latest command appears first
                if suggestion.hasPrefix(command) {
                    var shortenedSugg = suggestion
                    shortenedSugg.removeFirst(command.count)
                    if !autocompleteSuggestions.contains(shortenedSugg) && (shortenedSugg.count > 0) {
                        autocompleteSuggestions.append(shortenedSugg)
                    }
                }
            }
            // Are we autocompleting a command or something else?
            // TODO: this creates problems for "\ " and quoted spaces. We just need first and last components.
            let commandParts = command.components(separatedBy: " ")
            // NSLog("commandParts: \(commandParts)")
            mainCommand = commandParts[0]
            var autocompleteCommands = false
            if (commandParts.count <= 1) || (commandParts.last!.contains("|")) {
                autocompleteCommands = true
                mainCommand = commandParts.last!
                if let alternateScreenRange = mainCommand.range(of: "|") { // case with ls|grep
                    mainCommand.removeSubrange(command.startIndex..<alternateScreenRange.upperBound)
                }
            } else {
                // case with "ls | grep"
                let beforeCurrentElement = commandParts[commandParts.count - 2]
                if (beforeCurrentElement.hasSuffix("|")) {
                    autocompleteCommands = true
                    mainCommand = commandParts.last!
                } else if (beforeCurrentElement.contains("|")) {
                    mainCommand = beforeCurrentElement
                    if let alternateScreenRange = mainCommand.range(of: "|") { // case with ls|grep
                        mainCommand.removeSubrange(mainCommand.startIndex..<alternateScreenRange.upperBound)
                    }
                } else {
                    var previousPart = ""
                    for part in commandParts.reversed() {
                        if (part.hasSuffix("|")) {
                            mainCommand = previousPart
                            break
                        } else if (part.contains("|")) {
                            mainCommand = part
                            if let alternateScreenRange = mainCommand.range(of: "|") { // case with ls|grep
                                mainCommand.removeSubrange(mainCommand.startIndex..<alternateScreenRange.upperBound)
                                break
                            }
                        }
                        previousPart = part
                    }
                }
            }
            if autocompleteCommands {
                // Autocompleting a command:
                // The aliases go first:
                if let aliasArray = aliasesAsArray() as? [String]? {
                    for suggestion in aliasArray! { // alphabetical order
                        if suggestion.hasPrefix(mainCommand) {
                            var shortenedSugg = suggestion
                            shortenedSugg.removeFirst(mainCommand.count)
                            if (!autocompleteSuggestions.contains(shortenedSugg)) && (!autocompleteSuggestions.contains(shortenedSugg + " ")) {
                                // add a space so we're ready with the arguments
                                autocompleteSuggestions.append(shortenedSugg + " ")
                            }
                        }
                    }
                }
                // Followed by the actual commands:
                for suggestion in commandsArray() { // alphabetical order
                    if suggestion.hasPrefix(mainCommand) {
                        var shortenedSugg = suggestion
                        shortenedSugg.removeFirst(mainCommand.count)
                        if (!autocompleteSuggestions.contains(shortenedSugg)) && (!autocompleteSuggestions.contains(shortenedSugg + " ")) {
                            // add a space so we're ready with the arguments, unless it's a directory:
                            if (!shortenedSugg.hasSuffix("/")) {
                                autocompleteSuggestions.append(shortenedSugg + " ")
                            } else {
                                autocompleteSuggestions.append(shortenedSugg)
                            }
                        }
                    }
                }
                // also list the matching files and directories in the current dir:
                var matchingDirectory = URL(fileURLWithPath: mainCommand)
                var filePrefix = ""
                if (!mainCommand.hasSuffix("/")) {
                    filePrefix = URL(fileURLWithPath: mainCommand).lastPathComponent
                    matchingDirectory = URL(fileURLWithPath: mainCommand).deletingLastPathComponent()
                }
                NSLog("directory: \(matchingDirectory) prefix: \(filePrefix)")
                var isDirectory: ObjCBool = false
                if FileManager().fileExists(atPath: matchingDirectory.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        let buf = stat.init()
                        let pbuf = UnsafeMutablePointer<stat>.allocate(capacity: 1)
                        pbuf.initialize(to: buf)
                        do {
                            var filePaths = try FileManager().contentsOfDirectory(atPath: matchingDirectory.path)
                            filePaths.sort() // alphabetical order
                            // Add all non hidden-files first, then all hidden files:
                            for file in filePaths {
                                if (!file.hasPrefix(filePrefix)) {
                                    continue
                                }
                                if (file.hasPrefix(".")) {
                                    continue
                                }
                                if !matchingDirectory.path.hasPrefix(Bundle.main.resourcePath!) {
                                    // We only check for exec status for files outside $APPDIR, because files inside $APPDIR cannot have the x bit set
                                    // On iOS, isExecutableFile() and access() always returns false so we use stat()
                                    let returnValue = stat((matchingDirectory.path + "/" + file).utf8CString, pbuf)
                                    if pbuf.pointee.st_mode & (S_IXOTH|S_IXUSR|S_IXGRP) == 0 {
                                        continue
                                    }
                                }
                                var newCommand = URL(fileURLWithPath: file).lastPathComponent
                                if (URL(fileURLWithPath: matchingDirectory.path + "/" + file).isDirectory) {
                                    newCommand.append("/")
                                }
                                // Do not add a command if it is already present:
                                var shortenedSugg = newCommand
                                shortenedSugg.removeFirst(filePrefix.count)
                                if (!autocompleteSuggestions.contains(shortenedSugg)) && (!autocompleteSuggestions.contains(shortenedSugg + " ")) {
                                    // add a space so we're ready with the arguments, unless it's a directory:
                                    if (!shortenedSugg.hasSuffix("/")) {
                                        autocompleteSuggestions.append(shortenedSugg + " ")
                                    } else {
                                        autocompleteSuggestions.append(shortenedSugg)
                                    }
                                }
                            }
                            for file in filePaths {
                                if (!file.hasPrefix(filePrefix)) {
                                    continue
                                }
                                if (!file.hasPrefix(".")) {
                                    continue
                                }
                                if !matchingDirectory.path.hasPrefix(Bundle.main.resourcePath!) {
                                    // We only check for exec status for files outside $APPDIR, because files inside $APPDIR cannot have the x bit set
                                    // On iOS, isExecutableFile() and access() always returns false so we use stat()
                                    let returnValue = stat((matchingDirectory.path + "/" + file).utf8CString, pbuf)
                                    if pbuf.pointee.st_mode & (S_IXOTH|S_IXUSR|S_IXGRP) == 0 {
                                        continue
                                    }
                                }
                                var newCommand = URL(fileURLWithPath: file).lastPathComponent
                                if (URL(fileURLWithPath: matchingDirectory.path + "/" + file).isDirectory) {
                                    newCommand.append("/")
                                }
                                // Do not add a command if it is already present:
                                var shortenedSugg = newCommand
                                shortenedSugg.removeFirst(filePrefix.count)
                                if (!autocompleteSuggestions.contains(shortenedSugg)) && (!autocompleteSuggestions.contains(shortenedSugg + " ")) {
                                    // add a space so we're ready with the arguments, unless it's a directory:
                                    if (!shortenedSugg.hasSuffix("/")) {
                                        autocompleteSuggestions.append(shortenedSugg + " ")
                                    } else {
                                        autocompleteSuggestions.append(shortenedSugg)
                                    }
                                }
                            }
                        } catch {
                            // The directory is unreadable, move to next one
                            NSLog("Can not list content of directory: \(mainCommand)")
                        }
                    }
                }
            } else {
                // We have already entered a command:
                let futureCommand = aliasedCommand(mainCommand)
                let commandOperatesOn = operatesOn(futureCommand)
                let optionList = getoptString(futureCommand)
                let lastElement = commandParts.last
                var directoryForListing = lastElement
                if (futureCommand == "z") {
                    // Autocomplete by matching directories using regexps
                    // so "z a/b[tab]" will autocomplete to "cd auto/blocking"
                    // or create a list of all previously used directories that match a/b
                    var keys: [String]
                    NSLog("regexp, before: \(directoryForListing)")
                    if let directoryForListing = directoryForListing?.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "/", with: ".*/.*") {
                        NSLog("regexp, after: \(directoryForListing)")
                        do {
                            let regex = try NSRegularExpression(pattern: directoryForListing, options: [])
                            // select keys from dictionary that match argument. Using partial match.
                            let result = directoriesUsed.filter( { regex.matches(in: $0.key, range: NSRange($0.key.startIndex..<$0.key.endIndex, in: $0.key)).count > 0 } )
                            if (result.count == 0) {
                                // No matches in history. Search local directory, same regexp.
                                let filePaths = try FileManager().contentsOfDirectory(atPath: FileManager().currentDirectoryPath)
                                var result = filePaths.filter( { regex.matches(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)).count > 0 } )
                                if (result.count > 1) {
                                    let localDirCompact = String(cString: ios_getBookmarkedVersion(FileManager().currentDirectoryPath.utf8CString)) + "/"
                                    result = result.sorted(by: { current, next in rankDirectory(dir: current, base: localDirCompact) > rankDirectory(dir: next, base: localDirCompact)})
                                }
                            }
                            keys = result.keys.sorted()
                            keys = keys.sorted(by: { current, next in rankDirectory(dir: current, base: nil) > rankDirectory(dir: next, base: nil)})
                            for key in keys {
                                autocompleteSuggestions.append(key.replacingOccurrences(of: " ", with: "\\ "))
                            }
                            return
                        } catch {
                            NSLog("Error getting Z files from directory: \(directoryForListing): \(error.localizedDescription)")
                        }
                    }
                } else if (lastElement?.first == "-") {
                    // options, like "-l"
                    if (optionList != nil) {
                        for i in 0..<optionList!.count {
                            var option = String(optionList![optionList!.index(optionList!.startIndex, offsetBy: i)])
                            if (option != ":") {
                                if (i < optionList!.count - 1) {
                                    // if an option is followed by ":", then it expects an argument, so we add a space:
                                    let nextChar = optionList![optionList!.index(optionList!.startIndex, offsetBy: i + 1)]
                                    if (nextChar == ":") {
                                        option = option + " "
                                    }
                                }
                                if (!lastElement!.contains(option)) && (!command.contains("-" + String(option))) {
                                    autocompleteOptions = true
                                    autocompleteSuggestions.append(String(option))
                                }
                            }
                        }
                    }
                } else if (lastElement?.first == "$") {
                    // environment variable
                    if (lastElement!.contains("/")) {
                        let directoryComponents = lastElement!.split(separator: "/", maxSplits: 1)
                        var environmentVariable = String(directoryComponents[0])
                        environmentVariable.removeFirst()
                        if directoryComponents.count == 1 {
                            if environmentVariable.hasSuffix("/") {
                                environmentVariable.removeLast()
                            }
                            directoryForListing = String(cString: ios_getenv(environmentVariable)) + "/"
                        } else {
                            directoryForListing = String(cString: ios_getenv(environmentVariable)) + "/" + String(directoryComponents[1])
                        }
                    } else {
                        let environmentVariables = environmentAsArray()
                        for envVar in environmentVariables! {
                            if let envVarString = envVar as? String {
                                let variableName = "$" + envVarString
                                if variableName.hasPrefix(lastElement!) {
                                    let envVarParts = envVarString.split(separator: "=", maxSplits: 1)
                                    var shortenedSugg = String(envVarParts[0])
                                    var pointsToDirectory = false
                                    if (envVarParts.count > 0) {
                                        if URL(fileURLWithPath: String(envVarParts[1])).isDirectory {
                                            pointsToDirectory = true
                                        }
                                    }
                                    if (commandOperatesOn == "directory") && !pointsToDirectory {
                                        continue
                                    }
                                    if ((commandOperatesOn == "file") || (commandOperatesOn == "directory")) &&
                                        (envVarParts.count > 0) && pointsToDirectory {
                                        shortenedSugg += "/"
                                    }
                                    shortenedSugg.removeFirst(lastElement!.count - 1)
                                    if (!autocompleteSuggestions.contains(shortenedSugg)) {
                                        autocompleteSuggestions.append(shortenedSugg)
                                    }
                                }
                            }
                        }
                    }
                } else if (lastElement?.first == "~") {
                    let storedNamesDictionary = UserDefaults.standard.dictionary(forKey: "bookmarkNames") ?? [:]
                    if (lastElement!.contains("/")) {
                        let directoryComponents = lastElement!.split(separator: "/", maxSplits: 1)
                        var bookmarkName = String(directoryComponents[0])
                        bookmarkName.removeFirst()
                        if directoryComponents.count == 1 {
                            if (bookmarkName.hasSuffix("/")) {
                                bookmarkName.removeLast()
                            }
                            if let path = storedNamesDictionary[bookmarkName] as? String {
                                directoryForListing = path + "/"
                            } else {
                                NSLog("Unable to extract path for \(bookmarkName)")
                            }
                        } else {
                            let urlPath = storedNamesDictionary[bookmarkName]
                            let path = (urlPath as! String)
                            directoryForListing = path + "/" + String(directoryComponents[1])
                        }
                    } else {
                        var sortedKeys = storedNamesDictionary.keys.sorted() // alphabetical order
                        if (commandOperatesOn == "directory") {
                            // sort directories in order of use:
                            sortedKeys = sortedKeys.sorted(by: { current, next in rankDirectory(dir:"~" + current, base: nil) > rankDirectory(dir:"~" + next, base: nil)})
                        }
                        for key in sortedKeys {
                            var pointsToDirectory = false
                            if let path = storedNamesDictionary[key] as? String {
                                if (URL(fileURLWithPath: path).isDirectory) {
                                    pointsToDirectory = true
                                }
                            }
                            if (commandOperatesOn == "directory") && !pointsToDirectory {
                                continue
                            }
                            var bookmarkName = "~" + key
                            if bookmarkName.hasPrefix(lastElement!) {
                                if ((commandOperatesOn == "file") || (commandOperatesOn == "directory")) && pointsToDirectory {
                                    bookmarkName += "/"
                                }
                                bookmarkName.removeFirst(lastElement!.count)
                                bookmarkName = bookmarkName.replacingOccurrences(of: " ", with: "\\ ")
                                if (!autocompleteSuggestions.contains(bookmarkName)) {
                                    autocompleteSuggestions.append(bookmarkName)
                                }
                            }
                        }
                    }
                }
                if (!autocompleteOptions) {
                    // add the content of the directory in directoryForListing
                    var prefix = ""
                    if let directoryForListing = directoryForListing {
                        var directory = directoryForListing
                        if (directoryForListing == "") {
                            directory = "."
                        }
                        var matchingPath = URL(fileURLWithPath: directoryForListing).lastPathComponent
                        if URL(fileURLWithPath: directoryForListing).isDirectory {
                            matchingPath = ""
                            if !directory.hasSuffix("/") && (directoryForListing != "") {
                                prefix = "/"
                            }
                        } else {
                            directory.removeLast(matchingPath.count)
                            if (directory == "") {
                                directory = "."
                            }
                        }
                        do {
                            var filePaths = try FileManager().contentsOfDirectory(atPath: directory)
                            filePaths.sort() // alphabetical order
                            if (commandOperatesOn == "directory") {
                                // sort directories in order of use:
                                var directoryForSorting = directory
                                if (directoryForSorting == ".") {
                                    if (directoryForSorting == ".") {
                                        directoryForSorting = FileManager().currentDirectoryPath
                                    } else if (directoryForSorting.hasPrefix("./")) {
                                        directoryForSorting = directoryForSorting.replacingOccurrences(of: "./", with: FileManager().currentDirectoryPath + "/")
                                    } else {
                                        directoryForSorting = FileManager().currentDirectoryPath + "/" + directoryForSorting
                                    }
                                }
                                let localDirCompact = String(cString: ios_getBookmarkedVersion(directoryForSorting.utf8CString))
                                filePaths = filePaths.sorted(by: { current, next in rankDirectory(dir:current, base: localDirCompact) > rankDirectory(dir:next, base: localDirCompact)})
                                // NSLog("after sorting: \(filePaths)")
                            }
                            // Add all non hidden-files first, then all hidden files:
                            for filePath in filePaths {
                                let fullPath = directory + "/" + filePath
                                // NSLog("path = \(fullPath) , isDirectory: \(URL(fileURLWithPath: fullPath).isDirectory)")
                                let isDirectory = URL(fileURLWithPath: fullPath).isDirectory
                                if (commandOperatesOn == "directory") && !isDirectory {
                                    continue
                                }
                                var filePath = fullPath
                                if (isDirectory) {
                                    filePath += "/"
                                }
                                filePath.removeFirst(directory.count + 1)
                                if filePath.hasPrefix(".") {
                                    continue
                                }
                                // NSLog("Checking \(filePath) against \"\(matchingPath)\": \(filePath.hasPrefix(matchingPath))")
                                if (matchingPath == "") {
                                    filePath = prefix + filePath
                                    filePath = filePath.replacingOccurrences(of: " ", with: "\\ ")
                                    if (!autocompleteSuggestions.contains(filePath)) {
                                        autocompleteSuggestions.append(filePath)
                                    }
                                } else if filePath.hasPrefix(matchingPath) {
                                    var shortenedSugg = filePath
                                    shortenedSugg.removeFirst(matchingPath.count)
                                    shortenedSugg = shortenedSugg.replacingOccurrences(of: " ", with: "\\ ")
                                    // NSLog("Adding \"\(shortenedSugg)\"")
                                    if (!autocompleteSuggestions.contains(shortenedSugg)) {
                                        autocompleteSuggestions.append(shortenedSugg)
                                    }
                                }
                            }
                            for filePath in filePaths {
                                let fullPath = directory + "/" + filePath
                                // NSLog("path = \(fullPath) , isDirectory: \(URL(fileURLWithPath: fullPath).isDirectory)")
                                let isDirectory = URL(fileURLWithPath: fullPath).isDirectory
                                if (commandOperatesOn == "directory") && !isDirectory {
                                    continue
                                }
                                var filePath = fullPath
                                if (isDirectory) {
                                    filePath += "/"
                                }
                                filePath.removeFirst(directory.count + 1)
                                if !filePath.hasPrefix(".") {
                                    continue
                                }
                                if (matchingPath == "") {
                                    filePath = prefix + filePath
                                    filePath = filePath.replacingOccurrences(of: " ", with: "\\ ")
                                    if (!autocompleteSuggestions.contains(filePath)) {
                                        autocompleteSuggestions.append(filePath)
                                    }
                                } else if filePath.hasPrefix(matchingPath) {
                                    var shortenedSugg = filePath
                                    shortenedSugg.removeFirst(matchingPath.count)
                                    shortenedSugg = shortenedSugg.replacingOccurrences(of: " ", with: "\\ ")
                                    if (!autocompleteSuggestions.contains(shortenedSugg)) {
                                        autocompleteSuggestions.append(shortenedSugg)
                                    }
                                }
                            }
                        }
                        catch {
                            NSLog("unable to list files in \(directory): \(error)")
                        }
                    }
                    
                }
            }
        }
    }
    
    // prints a string for autocomplete and move the rest of the command around, even if it is over multiple lines.
    // keep the command as it is until autocomplete has been accepted.
    func printAutocompleteString(suggestion: String) {
        // clear entire buffer, then reprint
        terminalView?.feed(text: escape + "[0J"); // delete display after cursor
        terminalView?.clearToEndOfLine()
        if (terminalView!.tintColor.getBrightness() > terminalView!.backgroundColor!.getBrightness()) {
            // We are in dark mode. Use yellow font for higher contrast
            terminalView?.feed(text: escape + "[33m")  // yellow
        } else {
            // light mode
            terminalView?.feed(text: escape + "[32m")  // yellow
            
        }
        terminalView?.feed(text: suggestion)
        terminalView?.feed(text: escape + "[39m")  // back to normal foreground color
    }
    
    func updateAutocomplete(text: String) {
        // remove all suggestions that don't fit the new string
        let currentSuggestion = autocompleteSuggestions[autocompletePosition]
        if (!autocompleteOptions) {
            autocompleteSuggestions.removeAll(where: { !$0.hasPrefix(text) })
        } else {
            // - remove suggestions that are not options and don't match
            // - keep suggestions that are not options and match (but shorten them)
            // - if there is a suggestion that is an option, and matches, and expects and argument, remove all other options but keep history
            // - (options will be approximated as "suggestions that are one letter or one letter + space)
            // if there are suggestions from history that fit the new case, keep them and keep autocomplete
            var optionExpectsArgument = false
            for s in autocompleteSuggestions {
                if s == text + " " {
                    optionExpectsArgument = true
                    break
                }
            }
            var optionMatch = text
            if (optionExpectsArgument) {
                optionMatch += " "
            }
            autocompleteSuggestions.removeAll(where: { $0 == optionMatch })
            if (optionExpectsArgument) {
                autocompleteSuggestions.removeAll(where: { !$0.hasPrefix(optionMatch) })
                commandBeforeCursor += " "
                terminalView?.feed(text: " ")
                autocompleteOptions = false
                if (autocompleteSuggestions.count < 1) {
                    autocompleteRunning = false
                } else {
                    autocompletePosition = 0
                    for i in 0..<autocompleteSuggestions.count {
                        var shortenedSugg = autocompleteSuggestions[i]
                        if (shortenedSugg == currentSuggestion) {
                            autocompletePosition = i
                        }
                        shortenedSugg.removeFirst(optionMatch.count)
                        autocompleteSuggestions[i] = shortenedSugg
                    }
                }
                return
            } else {
                autocompleteSuggestions.removeAll(where: { !$0.hasPrefix(optionMatch) && (
                    ($0.count > 1) &&
                    !(($0.count == 2) && ($0.hasSuffix(" ")))
                )})
            }
        }
        switch (autocompleteSuggestions.count) {
        case 0:
            stopAutocomplete()
        case 1:
            // erase everything
            terminalView?.feed(text: escape + "[0J"); // delete display after cursor
            terminalView?.clearToEndOfLine()
            var suggestion = autocompleteSuggestions[0]
            suggestion.removeFirst(text.count)
            commandBeforeCursor += suggestion
            terminalView?.feed(text: suggestion)
            terminalView?.saveCursorPosition()
            terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
            terminalView?.restoreCursorPosition()
            autocompleteRunning = false
        default:
            autocompletePosition = min (autocompletePosition, autocompleteSuggestions.count - 1)
            for i in 0..<autocompleteSuggestions.count {
                var shortenedSugg = autocompleteSuggestions[i]
                if (shortenedSugg == currentSuggestion) {
                    autocompletePosition = i
                }
                // Shorten all suggestions that are not an option
                if !autocompleteOptions || !((shortenedSugg.count == 1) || ((shortenedSugg.count == 2) && shortenedSugg.hasSuffix(" "))) {
                    shortenedSugg.removeFirst(text.count)
                    autocompleteSuggestions[i] = shortenedSugg
                }
            }
            let prefix = longestCommonPrefix(autocompleteSuggestions)
            for i in 0..<autocompleteSuggestions.count {
                var shortenedSugg = autocompleteSuggestions[i]
                shortenedSugg.removeFirst(prefix.count)
                autocompleteSuggestions[i] = shortenedSugg
            }
            commandBeforeCursor += prefix
            terminalView?.feed(text: prefix) // prints the rest of the line
            terminalView?.saveCursorPosition()
            printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
            terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
            terminalView?.restoreCursorPosition()
            autocompleteRunning = true
        }
    }
    
    func stopAutocomplete() {
        autocompleteRunning = false
        autocompleteSuggestions = []
        autocompletePosition = 0
        terminalView?.feed(text: escape + "[0J"); // delete display after cursor
        terminalView?.clearToEndOfLine()
        terminalView?.saveCursorPosition()
        terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
        terminalView?.restoreCursorPosition()
    }
    
    func findNextWord(string: String) -> String {
        let regex = try? NSRegularExpression(pattern: "(\\b)", options: [])
        let results = regex?.matches(in: string, options: [], range: NSRange(string.startIndex..., in: string))
        var returnValue = ""
        var offset = 0
        if let matches = results {
            for match in matches {
                let range = match.range
                let subString = string[string.index(string.startIndex, offsetBy:offset)..<string.index(string.startIndex, offsetBy: range.lowerBound)]
                returnValue += subString
                if (subString != " ") && subString != "/" && subString != "" {
                    return returnValue
                }
                offset = range.upperBound
            }
        }
        // If there's no word boundary, return the entire string:
        return string
    }
    
    private func title(_ button: UIBarButtonItem) -> String? {
        if let possibleTitles = button.possibleTitles {
            for attemptedTitle in possibleTitles {
                if (attemptedTitle.count > 0) {
                    return attemptedTitle
                }
            }
        }
        return button.title
    }
    
    // TerminalViewDelegate stubs:
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        #if HERDR_EMBEDDED
        herdrResize(UInt16(clamping: newCols), UInt16(clamping: newRows))
        #endif
        if (newRows != height) || (newCols != width) {
            ios_setWindowSize(Int32(newCols), Int32(newRows), self.persistentIdentifier?.toCString())
        }
        if (newRows != height) {
            height = newRows
            setenv("LINES", "\(height)".toCString(), 1)
            ios_setenv("LINES", "\(height)".toCString(), 1)
        }
        if (newCols != width) {
            width = newCols
            setenv("COLUMNS", "\(width)".toCString(), 1)
            ios_setenv("COLUMNS", "\(width)".toCString(), 1)
        }
    }
    
    // None of these are called.
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
        // Nope
    }
    
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        NSLog("hostCurrentDirectoryUpdate: \(directory)")
    }
    
    private func synchronizeRecalledInputContext(_ source: SwiftTerm.TerminalView) {
        guard source.markedTextRange == nil,
              let range = source.textRange(from: source.beginningOfDocument, to: source.endOfDocument) else { return }
        // History already changed the host editor. Update UIKit without sending it again.
        let receiver = source.terminalDelegate
        source.terminalDelegate = nil
        defer { source.terminalDelegate = receiver }
        source.replace(range, withText: commandBeforeCursor + commandAfterCursor)
        if let caret = source.position(from: source.beginningOfDocument, offset: commandBeforeCursor.utf16.count) {
            source.selectedTextRange = source.textRange(from: caret, to: caret)
        }
    }

    func send(source: SwiftTerm.TerminalView, inputString: String) {
        if inputString.contains("\r") || inputString.contains("\n") { editorToolbar.closeSymbols() }
        var string = inputString
        // print("string: \(string)")
        // TODO: move this above, don't do data -> String -> data!
        // NSLog("received string: \"\(string)\"")
        switch (string) {
        case endOfTransmission: // also control-D: delete character after cursor
            // Stop standard input for the command:
            if (currentCommand != "") {
                guard stdin_file_input != nil else {
                    // no command running, maybe it ended without us knowing:
                    printPrompt()
                    return
                }
                if (javascriptRunning) {
                    // send the current input to WebAssembly, then terminate the command:
                    // Anything after the cursor is ignored
                    webView?.evaluateJavaScript("inputString += '\(commandBeforeCursor + string)'; commandIsRunning;") { (result, error) in
                        // if let error = error { print(error) }
                        if let result = result as? Bool {
                            if (!result) {
                                self.endWebAssemblyCommand(error: 0, message: "")
                            }
                        }
                    }
                    commandBeforeCursor = ""
                    commandAfterCursor = ""
                    return
                } else {
                    do {
                        try stdin_file_input?.close()
                    }
                    catch {
                        // NSLog("Could not close stdin input.")
                    }
                    stdin_file_input = nil
                    commandBeforeCursor = ""
                    commandAfterCursor = ""
                    printPrompt()
                    return
                }
            } else {
                fallthrough // case where control D acts as delete
            }
        case escape + "[3~":   // Delete key
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            if (commandAfterCursor.count > 0) {
                if let firstChar = commandAfterCursor.first {
                    commandAfterCursor.removeFirst()
                    terminalView?.clearToEndOfLine()
                    terminalView?.saveCursorPosition()
                    if (commandAfterCursor.count > 0) {
                        terminalView?.feed(text: commandAfterCursor)
                    } else {
                        terminalView?.feed(text: " ")
                    }
                    terminalView?.restoreCursorPosition()
                    // August 2026: the cursor is moved back to the end of the line,
                    // unless we add these lines.
                    terminalView?.getTerminal().updateFullScreen()
                    terminalView?.updateDisplay()
                }
            }
        case interrupt:
            if autocompleteRunning {
                stopAutocomplete()
            } else {
                if (currentCommand != "") && (!javascriptRunning) {
                    // Calling ios_kill while executing webAssembly or JavaScript is a bad idea.
                    // Do we have a way to interrupt JS execution in WkWebView?
                    // Make sure we're on the right session:
                    ios_switchSession(self.persistentIdentifier?.toCString())
                    ios_setContext(self.shellContext?.bytes)
                    // Then send interrupt to the running command:
                    _ = asml_interrupt_session(self.persistentIdentifier?.toCString())
                    if interruptForeground() != 0 { ios_kill() } // Preserve the stock fallback for commands without a foreground job.
                }
                if (currentCommand == "") {
                    // disable auto-complete menu if running
                    // don't execute command, move to next line, print prompt
                    commandBeforeCursor = ""
                    commandAfterCursor = ""
                    terminalView?.feed(text: "\r\n")
                    printPrompt()
                }
            }
        case "\u{0008}": // control H - delete
            fallthrough
        case deleteBackward:
            // send arrow-left, then delete-char, but only if there is something to delete:
            if (terminalView!.selectionActive) {
                terminalView?.deleteSelection()
            } else if autocompleteRunning {
                stopAutocomplete()
            } else {
                if (commandBeforeCursor.count > 0) {
                    terminalView?.moveUpIfNeeded()
                    if let lastChar = commandBeforeCursor.last {
                        // NSLog("deleting: \"\(lastChar)\"")
                        commandBeforeCursor.removeLast()
                        let characterWidth = NSAttributedString(string: String(lastChar), attributes: [.font: terminalView?.font]).size().width
                        if (characterWidth > 1.4 * basicCharWidth) {
                            // "large" characters: delete two columns
                            terminalView?.feed(text: escape + "[D")
                            terminalView?.feed(text: escape + "[P")
                        }
                        terminalView?.feed(text: escape + "[D")
                        terminalView?.feed(text: escape + "[P")
                    }
                }
                if (commandAfterCursor.count > 0) {
                    // redraw the end of the line
                    terminalView?.saveCursorPosition()
                    terminalView?.clearToEndOfLine()
                    terminalView?.feed(text: commandAfterCursor)
                    terminalView?.restoreCursorPosition()
                    // July 2026: the cursor is moved back to the end of the line,
                    // unless we add these lines.
                    terminalView?.getTerminal().updateFullScreen()
                    terminalView?.updateDisplay()
                }
            }
        case tabulation: // autocomplete
            // NSLog("received tab. Autocomplete running: \(autocompleteRunning)")
            if (autocompleteRunning) {
                if (autocompleteOptions) {
                    // insert the option, keep running autocomplete:
                    let string = autocompleteSuggestions[autocompletePosition]
                    commandBeforeCursor += string
                    terminalView?.feed(text: string) // prints the string
                    updateAutocomplete(text: string)
                } else {
                    commandBeforeCursor += autocompleteSuggestions[autocompletePosition]
                    terminalView?.feed(text: autocompleteSuggestions[autocompletePosition])
                    if (autocompleteSuggestions[autocompletePosition].hasSuffix("/")) {
                        autocompleteRunning = false
#if DEACTIVATED
                        // single suggestion, is a directory: fill again but don't force
                        fillAutocompleteSuggestions(command: commandBeforeCursor)
                        // NSLog("suggestions: \(autocompleteSuggestions)")
                        if (autocompleteSuggestions.count > 0) {
                            terminalView?.saveCursorPosition()
                            printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                            terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                            terminalView?.restoreCursorPosition()
                            autocompleteRunning = true
                        } else {
                            autocompleteRunning = false
                        }
#endif
                    } else {
                        autocompleteSuggestions = []
                        autocompletePosition = 0
                        autocompleteRunning = false
                        var currentCommandVoiceOver = commandBeforeCursor
                        if (commandAfterCursor.count > 0) {
                            currentCommandVoiceOver += " insertion point "
                            currentCommandVoiceOver += commandAfterCursor
                        }
                        UIAccessibility.post(notification: .announcement, argument: currentCommandVoiceOver)
                    }
                }
            } else {
                // standard version, first time we press tab
                fillAutocompleteSuggestions(command: commandBeforeCursor)
                // Check if all suggestions start with the same substring:
                let commonPrefix = longestCommonPrefix(autocompleteSuggestions)
                for i in 0..<autocompleteSuggestions.count {
                    var shortenedSugg = autocompleteSuggestions[i]
                    shortenedSugg.removeFirst(commonPrefix.count)
                    autocompleteSuggestions[i] = shortenedSugg
                }
                NSLog("suggestions: \(autocompleteSuggestions)")
                if (commandBeforeCursor.hasPrefix("z ")) {
                    commandBeforeCursor = "cd "
                    terminalView?.moveToBeginningOfLine()
                    terminalView?.saveCursorPosition()
                    terminalView?.clearToEndOfLine()
                    terminalView?.feed(text: commandBeforeCursor)
                }
                commandBeforeCursor += commonPrefix
                terminalView?.feed(text: commonPrefix)
                if (autocompleteSuggestions.count > 1) {
                    terminalView?.saveCursorPosition()
                    printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                    terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                    terminalView?.restoreCursorPosition()
                    autocompleteRunning = true
                } else if (commonPrefix.hasSuffix("/")) {
                    autocompleteRunning = false
#if DEACTIVATED
                    // Single suggestion, is a directory: fill again but don't force acceptance.
                    fillAutocompleteSuggestions(command: commandBeforeCursor)
                    if (autocompleteSuggestions.count > 0) {
                        terminalView?.saveCursorPosition()
                        printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                        terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                        terminalView?.restoreCursorPosition()
                        autocompleteRunning = true
                    } else {
                        autocompleteRunning = false
                    }
#endif
                }
                if (!autocompleteRunning) {
                    var currentCommandVoiceOver = commandBeforeCursor
                    if (commandAfterCursor.count > 0) {
                        currentCommandVoiceOver += " insertion point "
                        currentCommandVoiceOver += commandAfterCursor
                    }
                    UIAccessibility.post(notification: .announcement, argument: currentCommandVoiceOver)
                }
            }
            synchronizeRecalledInputContext(source)
        case "\u{0010}": // control P
            fallthrough
        case escape + "OA": // up arrow (application mode)
            fallthrough
        case escape + "[A": // up arrow
            if (autocompleteRunning) {
                autocompletePosition -= 1
                if (autocompletePosition < 0) {
                    autocompletePosition = autocompleteSuggestions.count - 1
                }
                terminalView?.saveCursorPosition()
                printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                terminalView?.restoreCursorPosition()
            } else {
                if (currentCommand == "") {
                    NSLog("Up arrow, position= \(historyPosition) count= \(history.count)")
                    if (historyPosition > 0) {
                        historyPosition -= 1
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.feed(text: history[historyPosition])
                        commandBeforeCursor = history[historyPosition]
                        commandAfterCursor = ""
                        synchronizeRecalledInputContext(source)
                        delayedVoiceOver(message: commandBeforeCursor)
                    }
                } else {
                    NSLog("Up arrow, position= \(commandHistoryPosition) count= \(commandHistory.count)")
                    if (commandHistoryPosition > 0) {
                        commandHistoryPosition -= 1
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView!.setPromptEnd() // Required? Why?
                        terminalView?.feed(text: commandHistory[commandHistoryPosition])
                        commandBeforeCursor = commandHistory[commandHistoryPosition]
                        commandAfterCursor = ""
                        synchronizeRecalledInputContext(source)
                        delayedVoiceOver(message: commandBeforeCursor)
                    }
                }
            }
        case "\u{000E}": // control N
            fallthrough
        case escape + "OB": // down arrow (application mode)
            fallthrough
        case escape + "[B": // down arrow
            if (autocompleteRunning) {
                autocompletePosition += 1
                if (autocompletePosition > autocompleteSuggestions.count - 1) {
                    autocompletePosition = 0
                }
                terminalView?.saveCursorPosition()
                printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                terminalView?.restoreCursorPosition()
            } else {
                if (currentCommand == "") {
                    NSLog("Down arrow, position= \(historyPosition) count= \(history.count)")
                    if (historyPosition < history.count - 1) {
                        historyPosition += 1
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        if (historyPosition < history.count) {
                            terminalView?.feed(text: history[historyPosition])
                            commandBeforeCursor = history[historyPosition]
                            commandAfterCursor = ""
                            synchronizeRecalledInputContext(source)
                            delayedVoiceOver(message: commandBeforeCursor)
                        }
                    } else {
                        historyPosition = history.count
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.getTerminal().updateFullScreen() // force redraw
                        terminalView?.updateDisplay()
                        commandBeforeCursor = ""
                        commandAfterCursor = ""
                        synchronizeRecalledInputContext(source)
                        delayedVoiceOver(message: "empty line")
                    }
                } else {
                    NSLog("Down arrow, position= \(commandHistoryPosition) count= \(commandHistory.count)")
                    if (commandHistoryPosition < commandHistory.count - 1) {
                        commandHistoryPosition += 1
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        if (commandHistoryPosition < commandHistory.count) {
                            NSLog("sending \(commandHistory[commandHistoryPosition])")
                            terminalView?.feed(text: commandHistory[commandHistoryPosition])
                            commandBeforeCursor = commandHistory[commandHistoryPosition]
                            commandAfterCursor = ""
                            synchronizeRecalledInputContext(source)
                            delayedVoiceOver(message: commandBeforeCursor)
                        }
                    } else {
                        commandHistoryPosition = commandHistory.count
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.getTerminal().updateFullScreen() // force redraw
                        terminalView?.updateDisplay()
                        commandBeforeCursor = ""
                        commandAfterCursor = ""
                        synchronizeRecalledInputContext(source)
                        delayedVoiceOver(message: " empty line ")
                    }
                }
            }
        case "\u{0002}": // control B
            fallthrough
        case escape + "OD": // left arrow (application mode)
            fallthrough
        case escape + "[D": // left arrow
            if (terminalView!.selectionActive) {
                terminalView?.moveToBeginningOfSelection()
                if autocompleteRunning {
                    stopAutocomplete()
                }
            } else if autocompleteRunning {
                stopAutocomplete()
            } else {
                if (commandBeforeCursor.count > 0) {
                    if let lastChar = commandBeforeCursor.last {
                        commandBeforeCursor.removeLast()
                        commandAfterCursor = String(lastChar) + commandAfterCursor
                        terminalView?.moveUpIfNeeded()
                        let characterWidth = NSAttributedString(string: String(lastChar), attributes: [.font: terminalView?.font]).size().width
                        if (characterWidth > 1.4 * basicCharWidth) {
                            terminalView?.feed(text: escape + "[D")
                        }
                        terminalView?.feed(text: escape + "[D")
                        delayedVoiceOver(message: String(lastChar))
                    }  else {
                        delayedVoiceOver(message: " beginning of line ")
                    }
                } else {
                    delayedVoiceOver(message: " beginning of line")
                }
            }
        case "\u{0006}": // control F
            fallthrough
        case escape + "OC": // right arrow (application mode)
            fallthrough
        case escape + "[C": // right arrow
            if (terminalView!.selectionActive) {
                terminalView?.moveToEndOfSelection()
                if autocompleteRunning {
                    stopAutocomplete()
                }
            } else if autocompleteRunning {
                // autocomplete up to the next word boundary
                let string = findNextWord(string: autocompleteSuggestions[autocompletePosition])
                commandBeforeCursor += string
                terminalView?.feed(text: string) // prints the string
                updateAutocomplete(text: string)
                synchronizeRecalledInputContext(source)
#if DEACTIVATED
                if (commandBeforeCursor.hasSuffix("/") && (!autocompleteRunning || (autocompleteSuggestions[autocompletePosition].count == 0))) {
                    // We completed a directory. Let's list the content:
                    fillAutocompleteSuggestions(command: commandBeforeCursor)
                    if (autocompleteSuggestions.count > 0) {
                        terminalView?.saveCursorPosition()
                        printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                        terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                        terminalView?.restoreCursorPosition()
                        autocompleteRunning = true
                    } else {
                        autocompleteRunning = false
                    }
                }
#endif
            } else {
                if (commandAfterCursor.count > 0) {
                    if let firstChar = commandAfterCursor.first {
                        commandAfterCursor.removeFirst()
                        commandBeforeCursor = commandBeforeCursor + String(firstChar)
                        terminalView?.moveDownIfNeeded()
                        let characterWidth = NSAttributedString(string: String(firstChar), attributes: [.font: terminalView?.font]).size().width
                        if (characterWidth > 1.4 * basicCharWidth) {
                            terminalView?.feed(text: escape + "[C")
                        }
                        terminalView?.feed(text: escape + "[C")
                        if (commandAfterCursor.count > 0) {
                            delayedVoiceOver(message: String(commandAfterCursor.first!))
                        } else {
                            delayedVoiceOver(message: " end of line ")
                        }
                    }
                } else {
                    delayedVoiceOver(message: " end of line ")
                    NSLog("Cannot move right")
                }
            }
        case escape + "[1;3A":  // Alt-up arrow
            fallthrough
        case escape + "[1;5A":  // Control-up arrow (external keyboard)
            if (autocompleteRunning) {
                autocompletePosition -= 5
                if (autocompletePosition < 0) {
                    autocompletePosition = autocompleteSuggestions.count - autocompletePosition
                    if (autocompletePosition < 0) {
                        autocompletePosition = 0
                    }
                }
                if (autocompletePosition >= autocompleteSuggestions.count) {
                    autocompletePosition = autocompleteSuggestions.count - 1
                }
                terminalView?.saveCursorPosition()
                printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                terminalView?.restoreCursorPosition()
            } else {
                if (currentCommand == "") {
                    NSLog("Control-up arrow, position= \(historyPosition) count= \(history.count)")
                    if (historyPosition > 0) {
                        historyPosition = max(0, historyPosition - 5)
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.feed(text: history[historyPosition])
                        commandBeforeCursor = history[historyPosition]
                        commandAfterCursor = ""
                        delayedVoiceOver(message: commandBeforeCursor)
                    }
                } else {
                    NSLog("Control-up arrow, position= \(commandHistoryPosition) count= \(commandHistory.count)")
                    if (commandHistoryPosition > 0) {
                        commandHistoryPosition = max(0, commandHistoryPosition - 5)
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView!.setPromptEnd() // Required? Why?
                        terminalView?.feed(text: commandHistory[commandHistoryPosition])
                        commandBeforeCursor = commandHistory[commandHistoryPosition]
                        commandAfterCursor = ""
                        delayedVoiceOver(message: commandBeforeCursor)
                    }
                }
            }
        case escape + "[1;3B":  // Alt-down arrow
            fallthrough
        case escape + "[1;5B":  // Control-down arrow (external keyboard)
            if (autocompleteRunning) {
                autocompletePosition += 5
                if (autocompletePosition > autocompleteSuggestions.count - 1) { // cycle through
                    autocompletePosition = autocompletePosition - autocompleteSuggestions.count
                    if (autocompletePosition > autocompleteSuggestions.count - 1) {
                        autocompletePosition = autocompleteSuggestions.count - 1
                    }
                }
                terminalView?.saveCursorPosition()
                printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                terminalView?.restoreCursorPosition()
            } else {
                if (currentCommand == "") {
                    NSLog("control-down arrow, position= \(historyPosition) count= \(history.count)")
                    if (historyPosition < history.count - 1) {
                        historyPosition = min(history.count, historyPosition + 5)
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        if (historyPosition < history.count) {
                            terminalView?.feed(text: history[historyPosition])
                            commandBeforeCursor = history[historyPosition]
                            commandAfterCursor = ""
                            delayedVoiceOver(message: commandBeforeCursor)
                        }
                    } else {
                        historyPosition = history.count
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.getTerminal().updateFullScreen() // force redraw
                        terminalView?.updateDisplay()
                        commandBeforeCursor = ""
                        commandAfterCursor = ""
                        delayedVoiceOver(message: "empty line")
                    }
                } else {
                    NSLog("control-down arrow, position= \(commandHistoryPosition) count= \(commandHistory.count)")
                    if (commandHistoryPosition < commandHistory.count - 1) {
                        commandHistoryPosition = min(commandHistoryPosition + 5, commandHistory.count)
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        if (commandHistoryPosition < commandHistory.count) {
                            NSLog("sending \(commandHistory[commandHistoryPosition])")
                            terminalView?.feed(text: commandHistory[commandHistoryPosition])
                            commandBeforeCursor = commandHistory[commandHistoryPosition]
                            commandAfterCursor = ""
                            delayedVoiceOver(message: commandBeforeCursor)
                        }
                    } else {
                        commandHistoryPosition = commandHistory.count
                        terminalView?.moveToBeginningOfLine()
                        terminalView?.clearToEndOfLine()
                        terminalView?.getTerminal().updateFullScreen() // force redraw
                        terminalView?.updateDisplay()
                        commandBeforeCursor = ""
                        commandAfterCursor = ""
                        delayedVoiceOver(message: " empty line ")
                    }
                }
            }
        case escape + "[1;3D":  // Alt-left arrow, move to previous word
            fallthrough
        case escape + "[1;5D":  // Control-left arrow (external keyboard)
            fallthrough
        case escape + "b":      // Alt-left arrow (SwiftTerm version)
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            while (commandBeforeCursor.count > 0) {
                if let lastChar = commandBeforeCursor.last {
                    commandBeforeCursor.removeLast()
                    commandAfterCursor = String(lastChar) + commandAfterCursor
                    terminalView?.moveUpIfNeeded()
                    let characterWidth = NSAttributedString(string: String(lastChar), attributes: [.font: terminalView?.font]).size().width
                    if (characterWidth > 1.4 * basicCharWidth) {
                        terminalView?.feed(text: escape + "[D")
                    }
                    terminalView?.feed(text: escape + "[D")
                    if !lastChar.isLetter {
                        break
                    }
                }
            }
            if (commandAfterCursor.count > 0) {
                delayedVoiceOver(message: String(commandAfterCursor.first!))
            } else {
                delayedVoiceOver(message: " beginning of line ")
            }
        case escape + "[1;3C":  // Alt-right arrow, move to next word
            fallthrough
        case escape + "[1;5C":  // Control-right arrow (external keyboard)
            fallthrough
        case escape + "f":      // Alt-right arrow (SwiftTerm version)
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            while (commandAfterCursor.count > 0) {
                if let firstChar = commandAfterCursor.first {
                    commandAfterCursor.removeFirst()
                    commandBeforeCursor = commandBeforeCursor + String(firstChar)
                    terminalView?.moveDownIfNeeded()
                    let characterWidth = NSAttributedString(string: String(firstChar), attributes: [.font: terminalView?.font]).size().width
                    if (characterWidth > 1.4 * basicCharWidth) {
                        terminalView?.feed(text: escape + "[C")
                    }
                    terminalView?.feed(text: escape + "[C")
                    if !firstChar.isLetter {
                        break
                    }
                }
            }
            if (commandAfterCursor.count > 0) {
                delayedVoiceOver(message: String(commandAfterCursor.first!))
            } else {
                delayedVoiceOver(message: " end of line ")
            }
        case "\u{0018}": // control X, stop autocomplete
            fallthrough
        case "\u{001A}": // control Z, stop autocomplete
            fallthrough
        case escape:    // escape, stop autocomplete
            if (autocompleteRunning) {
                stopAutocomplete()
            }
        case "\u{0001}": // control A, move to beginning of line
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            commandAfterCursor = commandBeforeCursor + commandAfterCursor
            commandBeforeCursor = ""
            terminalView?.moveToBeginningOfLine()
            terminalView?.getTerminal().updateFullScreen()
            terminalView?.updateDisplay()
            UIAccessibility.post(notification: .announcement, argument: "insertion point " + commandAfterCursor)
        case "\u{0005}": // control E, move to end of line
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            commandBeforeCursor = commandBeforeCursor + commandAfterCursor
            commandAfterCursor = ""
            terminalView?.moveToEndOfLine()
            terminalView?.getTerminal().updateFullScreen()
            terminalView?.updateDisplay()
            UIAccessibility.post(notification: .announcement, argument: commandBeforeCursor + " insertion point")
        case "\u{000B}": // control K: kill until end of line
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            terminalView?.clearToEndOfLine()
            commandAfterCursor = ""
            terminalView?.getTerminal().updateFullScreen()
            terminalView?.updateDisplay()
            UIAccessibility.post(notification: .announcement, argument: commandBeforeCursor + " insertion point")
        case "\u{0015}": // control U: kill from cursor to beginning of the line
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            commandBeforeCursor = ""
            terminalView?.moveToBeginningOfLine()
            terminalView?.saveCursorPosition()
            terminalView?.clearToEndOfLine()
            if (commandAfterCursor.count > 0) {
                terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
            }
            terminalView?.restoreCursorPosition()
            terminalView?.getTerminal().updateFullScreen() // force redraw
            terminalView?.updateDisplay()
            UIAccessibility.post(notification: .announcement, argument: "insertion point " + commandAfterCursor)
        case escape + "\u{0008}": // alt delete on external keyboard
            fallthrough
        case escape + "\u{007F}": // alt delete on keyboard: delete (backward) until the beginning of current word
            NSLog("alt-delete received")
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            while (commandBeforeCursor.count > 0) {
                if let lastChar = commandBeforeCursor.last {
                    commandBeforeCursor.removeLast()
                    terminalView?.moveUpIfNeeded()
                    let characterWidth = NSAttributedString(string: String(lastChar), attributes: [.font: terminalView?.font]).size().width
                    if (characterWidth > 1.4 * basicCharWidth) {
                        terminalView?.feed(text: escape + "[D")
                        terminalView?.feed(text: escape + "[P")
                    }
                    terminalView?.feed(text: escape + "[D")
                    terminalView?.feed(text: escape + "[P")
                    if !lastChar.isLetter {
                       break
                    }
                }
            }
            var currentCommandVoiceOver = commandBeforeCursor
            if (commandAfterCursor.count > 0) {
                currentCommandVoiceOver += " insertion point "
                currentCommandVoiceOver += commandAfterCursor
            }
            UIAccessibility.post(notification: .announcement, argument: currentCommandVoiceOver)
        case "\u{0017}": // control W: delete (backward) until the next space
            fallthrough
        case escape + "\u{0017}": // control W: delete (backward) until the next space
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            // remove all white spaces at the end:
            while (commandBeforeCursor.count > 0) {
                if let lastChar = commandBeforeCursor.last {
                    if !lastChar.isWhitespace {
                        break
                    }
                    commandBeforeCursor.removeLast()
                    terminalView?.moveUpIfNeeded()
                    terminalView?.feed(text: escape + "[D")
                    terminalView?.feed(text: escape + "[P")
                } else {
                    break
                }
            }
            // then remove all non-white space characters until a white space:
            while (commandBeforeCursor.count > 0) {
                if let lastChar = commandBeforeCursor.last {
                    if lastChar.isWhitespace {
                        break
                    }
                    commandBeforeCursor.removeLast()
                    terminalView?.moveUpIfNeeded()
                    let characterWidth = NSAttributedString(string: String(lastChar), attributes: [.font: terminalView?.font]).size().width
                    if (characterWidth > 1.4 * basicCharWidth) {
                        terminalView?.feed(text: escape + "[D")
                        terminalView?.feed(text: escape + "[P")
                    }
                    terminalView?.feed(text: escape + "[D")
                    terminalView?.feed(text: escape + "[P")
                } else {
                    break
                }
            }
            var currentCommandVoiceOver = commandBeforeCursor
            if (commandAfterCursor.count > 0) {
                currentCommandVoiceOver += " insertion point "
                currentCommandVoiceOver += commandAfterCursor
            }
            UIAccessibility.post(notification: .announcement, argument: currentCommandVoiceOver)
            terminalView?.currentCommandVoiceOver = currentCommandVoiceOver
        case "\u{000C}":  // control L: clear screen
            clearScreen()
            commandBeforeCursor = ""
            commandAfterCursor = ""
            printPrompt()
        case carriageReturn:
            if (autocompleteRunning) {
                // validate current suggestion
                // overwrite suggestion in default color
                terminalView?.feed(text: autocompleteSuggestions[autocompletePosition])
                commandBeforeCursor += autocompleteSuggestions[autocompletePosition]
                autocompleteSuggestions = []
                autocompletePosition = 0
                autocompleteRunning = false
            }
            if (currentCommand == "") {
                let commandLine = (commandBeforeCursor + commandAfterCursor).trimmingCharacters(in: .whitespaces)
                commandBeforeCursor = ""
                commandAfterCursor = ""
                terminalView?.saveCursorPosition() // for VoiceOver
                executeCommand(command: commandLine)
                windowPrintedContent += lastUsedPrompt + commandLine + "\n\r"
                terminalView?.feed(text: "\n\r")
            } else {
                let commandLine = (commandBeforeCursor + commandAfterCursor).trimmingCharacters(in: .whitespaces)
                commandBeforeCursor = ""
                commandAfterCursor = ""
                terminalView?.saveCursorPosition() // for VoiceOver
                terminalView?.feed(text: "\n\r")
                windowPrintedContent += commandLine + "\n\r"
                // webAssembly commands:
                stdinString = commandLine + "\n"
                NSLog("webAssembly: \(stdinString)")
                if (javascriptRunning && (thread_stdin_copy != nil)) {
                    // non-interactive WebAssembly commands:
                    webView?.evaluateJavaScript("inputString += '\(stdinString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n"))'; commandIsRunning;") { (result, error) in
                        // if let error = error { print(error) }
                        if let result = result as? Bool {
                            if (!result) {
                                self.endWebAssemblyCommand(error: 0, message: "")
                            }
                        }
                    }
                }
                guard let data = (commandLine + "\n").data(using: .utf8) else { return }
                guard stdin_file_input != nil else { return }
                // store command in local command history, reset if it's different:
                if (currentCommand != lastCommand) {
                    lastCommand = currentCommand
                    commandHistory = []
                    commandHistoryPosition = 0
                }
                if (commandHistory.last != commandLine) && (commandLine != "") {
                    commandHistory.append(commandLine)
                    while (commandHistory.count > 100) {
                        commandHistory.removeFirst()
                    }
                }
                commandHistoryPosition = commandHistory.count
                // TODO: don't send data if pipe already closed (^D followed by another key)
                // (store a variable that says the pipe has been closed)
                stdin_file_input?.write(data)
            }
        case " ": // space: end autocomplete
            if (autocompleteRunning) {
                stopAutocomplete()
            }
            fallthrough
        default:
            // remove the Copy/Paste/etc menu if it is visible
            // Default, send to term
            if (terminalView!.selectionActive) {
                terminalView?.deleteSelection()
            }
            commandBeforeCursor += string
            terminalView?.feed(text: string) // prints the string
            if autocompleteRunning {
                updateAutocomplete(text: string)
                synchronizeRecalledInputContext(source)
#if DEACTIVATED
                if (commandBeforeCursor.hasSuffix("/") && (!autocompleteRunning || (autocompleteSuggestions[autocompletePosition].count == 0))) {
                    // We just completed a directory. Let's list the content:
                    fillAutocompleteSuggestions(command: commandBeforeCursor)
                    if (autocompleteSuggestions.count > 0) {
                        terminalView?.saveCursorPosition()
                        printAutocompleteString(suggestion: autocompleteSuggestions[autocompletePosition])
                        terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                        terminalView?.restoreCursorPosition()
                        autocompleteRunning = true
                    } else {
                        autocompleteRunning = false
                    }
                }
#endif
            } else {
                if (commandAfterCursor.count > 0) {
                    // redraw the end of the line
                    terminalView?.saveCursorPosition()
                    terminalView?.clearToEndOfLine()
                    terminalView?.feed(text: commandAfterCursor) // prints the rest of the line
                    terminalView?.restoreCursorPosition()
                }
            }
        }
        // Send the current command to VoiceOver, only if running autocomplete:
        if UIAccessibility.isVoiceOverRunning {
            var currentCommandVoiceOver = ""
            // Only speak the command when autocomplete is running:
            if (autocompleteRunning) && (autocompleteSuggestions[autocompletePosition].count > 0) {
                if (commandBeforeCursor.count > 0) {
                    currentCommandVoiceOver = commandBeforeCursor
                }
                currentCommandVoiceOver += " autocomplete suggestion " + autocompleteSuggestions[autocompletePosition]
                if (commandAfterCursor.count > 0) {
                    currentCommandVoiceOver += " end suggestion "
                    currentCommandVoiceOver += commandAfterCursor
                }
                NSLog("voiceOver: \(currentCommandVoiceOver)")
                delayedVoiceOver(message: currentCommandVoiceOver)
            } else if (commandBeforeCursor.count > 0) || (commandAfterCursor.count > 0) {
                currentCommandVoiceOver = commandBeforeCursor + " insertion point " + commandAfterCursor
            }
            terminalView?.currentCommandVoiceOver = currentCommandVoiceOver
        }
    }
    
    #if HERDR_EMBEDDED
    @objc func nativeControlModifierReset(_ notification: Notification) {
        controlOn = false
        var buttons = editorToolbar.items ?? []
        for group in (terminalView?.inputAssistantItem.leadingBarButtonGroups ?? []) + (terminalView?.inputAssistantItem.trailingBarButtonGroups ?? []) {
            buttons.append(contentsOf: group.barButtonItems)
        }
        for button in buttons where title(button) == "control" {
            button.isSelected = false
        }
    }
    #endif

    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        if data.contains(13) || data.contains(10) { editorToolbar.closeSymbols() }
        // This is where I treat the incoming keypress
        if (currentCommand != "") && (commandBeforeCursor == "") && (commandAfterCursor == "") {
            // Sets the position of the end of the prompt for commands inside commands:
            terminalView!.setPromptEnd()
        }
        // remove the copy-paste-select menu if it is visible:
        if UIMenuController.shared.isMenuVisible {
            UIMenuController.shared.hideMenu()
        }
        // if control is pressed, we have to change the data
        var myData = data
        #if !HERDR_EMBEDDED
        if (controlOn) {
            // a) switch control off
            controlOn = false
            if (!useSystemToolbar) {
                for button in editorToolbar.items! {
                    if title(button) == "control" {
                        button.isSelected = controlOn
                        break
                    }
                }
                editorToolbar.setNeedsLayout()
            } else {
                var foundControl = false
                if let leftButtonGroups = terminalView?.inputAssistantItem.leadingBarButtonGroups {
                    for leftButtonGroup in leftButtonGroups {
                        for button in leftButtonGroup.barButtonItems {
                            if title(button) == "control" {
                                foundControl = true
                                button.isSelected = controlOn
                                break
                            }
                        }
                    }
                }
                if (!foundControl) {
                    if let rightButtonGroups = terminalView?.inputAssistantItem.trailingBarButtonGroups {
                        for rightButtonGroup in rightButtonGroups {
                            for button in rightButtonGroup.barButtonItems {
                                if title(button) == "control" {
                                    button.isSelected = controlOn
                                    break
                                }
                            }
                        }
                    }
                }
            }
            // b) extract control code:
            // b1) change arrows into control-arrows
            if ((data.count > 2) &&
                (data[0] == 27) &&  // escape
                ((data[1] == 91) || (data[1] == 79)) &&  // "[" or "O"
                ((data[2] >= 65) && (data[2] <= 68))) // A, B, C or D
            {
                // it's an arrow, let's make it control-arrow:
                // escape + "[1;3" + direction
                myData[0] = 27 // escape
                myData[1] = 91 // [
                myData.insert(49, at: 2) // 1
                myData.insert(59, at: 3) // ;
                myData.insert(51, at: 4) // 3
                // myData[5] should now be data[2] (A,B, C or D)
                NSLog("control-arrow: \(myData)")
            } else if (data.count > 0) {
                // It's not an arrow, make it a control-character:
                // control-delete (on screen keyboard) is mapped to alt-delete
                if (myData[0] == 0x7f) {
                    myData.insert(27, at: 0) // escape + 0x7f
                } else if (myData[0] > 96) { // control + a-z
                    myData[0] -= 96
                } else if (myData[0] > 64) { // control + A-Z
                    myData[0] -= 64
                }
                NSLog("control-character: \(myData)")
                // Q: what should I do if this cannot be converted to UTF8?
            }
        }
        #endif
        // if a command is running, send the data directly (except for webAssembly commands, who need a string)
        if (currentCommand != "") {
            // Node owns command streams, not a terminal signal-generating process.
            // A surrounding interactive Dash otherwise forwards these as bytes.
            if myData.count == 1, let key = myData.first, key == 3 || key == 4 {
                ios_switchSession(self.persistentIdentifier?.toCString())
                ios_setContext(self.shellContext?.bytes)
                if let program = ios_progname(), String(cString: program) == "node" || (key == 3 && ["npm", "npx"].contains(String(cString: program))) {
                    send(source: source, inputString: key == 3 ? interrupt : endOfTransmission)
                    return
                }
            }
            // If there is an interactive command running, we send the data to its stdin thread
            // active pager (interactive command): gets all the input sent through TTY:
            if (ios_activePager() != 0) {
                if (tty_file_input != nil) {
                    let savedSession = ios_getContext()
                    ios_switchSession(self.persistentIdentifier?.toCString())
                    ios_setContext(self.shellContext?.bytes)
                    ios_setStreams(self.stdin_file, self.stdout_file, self.stdout_file)
                    do {
                        try tty_file_input?.write(contentsOf: myData)
                    }
                    catch {
                        NSLog("Could not write data to tty?: \(myData)")
                    }
                    // We can get a session context that is not a valid UUID (InExtension, shSession...)
                    // In that case, don't switch back to it:
                    if let stringPointer = UnsafeMutablePointer<CChar>(OpaquePointer(savedSession)) {
                        let savedSessionIdentifier = String(cString: stringPointer)
                        if let uuid = UUID(uuidString: savedSessionIdentifier) {
                            ios_switchSession(savedSession)
                            ios_setContext(savedSession)
                        }
                    }
                }
                return
            }
            // from here on, we can assume ios_activePager() == 0
            // Special case: help() and license() in ipython are not interactive.
            var helpRunningInIpython = false
            if (currentCommand.hasPrefix("ipython") || currentCommand.hasPrefix("isympy")) {
                if let lastLine = terminalView?.getLastPrompt() {
                    if (lastLine.hasSuffix("help> ") ||
                        lastLine.hasSuffix("Hit Return for more, or q (and Return) to quit: ") ||
                        lastLine.hasSuffix("Do you really want to exit ([y]/n)? ")) {
                        helpRunningInIpython = true
                    }
                }
            }
            // interactive command: send the data directly
            if (interactiveCommandRunning || terminalView!.isCurrentBufferAlternate) && !helpRunningInIpython {
                ios_switchSession(self.persistentIdentifier?.toCString())
                ios_setContext(self.shellContext?.bytes);
                ios_setStreams(self.stdin_file, self.stdout_file, self.stdout_file)
                if (javascriptRunning && (thread_stdin_copy != nil)) {
                    // interactive WebAssembly commands
                    if let string = String (bytes: myData, encoding: .utf8) {
                        webView?.evaluateJavaScript("inputString += '\(string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n"))'; commandIsRunning;") { (result, error) in
                            // if let error = error { print(error) }
                            if let result = result as? Bool {
                                if (!result) {
                                    self.endWebAssemblyCommand(error: 0, message: "")
                                }
                            }
                        }
                        return
                    }
                }
                if (!javascriptRunning && executeWebAssemblyCommandsRunning) {
                    // There seems to be cases where the webassembly command did not terminate properly.
                    // We catch it here:
                    webView?.evaluateJavaScript("commandIsRunning;") { (result, error) in
                        // if let error = error { print(error) }
                        if let result = result as? Bool {
                            if (!result) {
                                self.endWebAssemblyCommand(error: 0, message: "")
                            }
                        }
                    }
                }
                // A pipe has no kernel foreground-job signals. Consume ETX only
                // when the runtime can target the published foreground Git job.
                if !javascriptRunning && myData.count == 1 && myData.first == 3 && interruptForeground() == 0 { return }
                // Interactive commands (not WebAssembly): just send the input to them. Allows Vim to map control-D to down half a page.
                guard stdin_file_input != nil else { return }
                // TODO: don't send data if pipe already closed (^D followed by another key)
                // (store a variable that says the pipe has been closed)
                // NSLog("Writing (interactive) \(command) to stdin")
                do {
                    try stdin_file_input?.write(contentsOf: myData)
                }
                catch {
                    NSLog("Could not write data to stdin?: \(myData)")
                }
                if let string = String (bytes: myData, encoding: .utf8) {
                    lastKeyboardInput += string
                }
                return
            }
        }
        // if no commands are running, or if they're not interactive, check for button events:
        // terminal sending button event: it sends escape + "[M " + coordinates and coordinates
        // are not necessarily convertible into UTF8 characters.
        if (data.count > 5) {
            var cursorTrackingRow = 0
            var cursorTrackingColumn = 0
            let dataSlice = data[0..<3] // first three characters
            if let string = String(bytes: dataSlice, encoding: .utf8) {
                if (string == escape + "[M") {
                    cursorTrackingRow = Int(data[5]) - 32 //  Int(tracking.last?.asciiValue ?? 32) - 32
                    cursorTrackingColumn = Int(data[4]) - 32 // Int(tracking[tracking.index(tracking.startIndex, offsetBy: 1)].asciiValue ?? 32) - 32
                    // data[3] - 32: is the button pressed. Almost always 0, so ' '.
                    if (autocompleteRunning) {
                        stopAutocomplete()
                    }
                    if let distance = terminalView?.setCursorPosition(x: cursorTrackingColumn - 1, y: cursorTrackingRow - 1) {
                        let command = commandBeforeCursor + commandAfterCursor
                        if (distance <= 0) || command.count == 0 {
                            // beginning of line
                            commandBeforeCursor = ""
                            commandAfterCursor = command
                            terminalView?.moveToBeginningOfLine()
                        } else {
                            NSLog("tracking, command: \(command) distance: \(distance)")
                            var length = 0
                            commandBeforeCursor = ""
                            for c in command {
                                let characterWidth = NSAttributedString(string: String(c), attributes: [.font: terminalView?.font]).size().width
                                if (characterWidth > 1.4 * basicCharWidth) {
                                    length += 2
                                    // "large" characters: takes two columns
                                } else {
                                    length += 1
                                }
                                NSLog("character: \(c) length: \(length) distance: \(distance)")
                                commandBeforeCursor += String(c)
                                if (length >= distance) {
                                    break
                                }
                            }
                            if (command.count > commandBeforeCursor.count) {
                                commandAfterCursor = command
                                commandAfterCursor.removeFirst(commandBeforeCursor.count)
                            }
                            NSLog("\(commandBeforeCursor) -- \(commandAfterCursor)")
                        }
                    }
                    return
                }
            }
        }
        if (data.count >= 5) {
            // Kitty keyboard and primary device-attributes replies are not editor input.
            // Interactive commands receive them above; late replies after exit are discarded.
            if (data[0] == 0x1b) && (data[1] == 0x5b) && (data[2] == 0x3f) && ((data[data.count-1] == 0x75) || (data[data.count-1] == 0x63)) {
                return
            }
        }
        
        if let string = String(bytes: myData, encoding: .utf8) {
            // most frequent case:
            send(source: source, inputString: string)
        } else {
            // could not convert, try with other encodings
            var conversionFound = false
            for encoding in [String.Encoding.isoLatin1, .isoLatin2, .iso2022JP, .japaneseEUC, .macOSRoman, .shiftJIS, .windowsCP1250, .ascii] {
                if let string = String(bytes: myData, encoding: encoding) {
                    conversionFound = true
                    send(source: source, inputString: string)
                    break
                }
            }
            if (!conversionFound) {
                // still could not convert, try with substrings.r
                NSLog("Failure of conversion, data: \(myData)")
                let max = myData.count
                var start = 0
                while start < max - 1 {
                    for i in 0...max-start-1 {
                        // going from start to max - 1, then start to max - 2, ... until start to start.
                        // last value: start..<start+1
                        let dataSlice = myData[start..<(max - i)]
                        if let string = String(bytes: dataSlice, encoding: .utf8) {
                            NSLog("sending string: \(string)")
                            send(source: source, inputString: string)
                            // New starting point is after the end of the string that worked:
                            // minus one because there's a plus one after that:
                            start = max - i - 1
                            break // break out of the for loop, next step in the while loop
                        }
                    }
                    // whether or not it worked, move the starting point by 1 and retry:
                    start += 1
                }
            }
        }
    }
    
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {
        //
    }
    
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {
        if let fixedup = link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = NSURLComponents(string: fixedup) {
                if let nested = url.url {
                    if let browserEnvVar = ios_getenv("BROWSER") {
                        let browser = (String(utf8String: browserEnvVar) ?? "safari").lowercased()
                        NSLog("nested: \(nested) string: \(nested.absoluteString)")
                        openurl_internal(browser: browser, url: nested)
                    } else {
                        UIApplication.shared.open (nested)
                    }
                }
            }
        }
    }
    
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let str = String (bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
    
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {
        //
    }
    
    @objc
    func zoomGestureHandler (_ gestureRecognizer:  UIPinchGestureRecognizer) {
        if gestureRecognizer.state == .began {
            zoomGestureInitialSize = terminalFontSize ?? factoryFontSize
            if (terminalFontSize == nil) {
                terminalFontSize = factoryFontSize
            }
        }
        if gestureRecognizer.state == .began || gestureRecognizer.state == .changed {
            terminalFontSize = zoomGestureInitialSize * Float(1 + (gestureRecognizer.scale - 1) / 5)
            NSLog("scaling gesture: scale= \(gestureRecognizer.scale) fontsize= \(terminalFontSize!)")
            if let terminalFont = UIFont(name: terminalFontName ?? factoryFontName, size: CGFloat(terminalFontSize!)) {
                terminalView?.font = terminalFont
                basicCharWidth = NSAttributedString(string: "m", attributes: [.font: self.terminalView?.font]).size().width
                terminalView?.getTerminal().updateFullScreen()
                terminalView?.updateDisplay()
            }
        }
    }

    @objc
    // handling two-fingers swipe. One-fingers swipe are handled by the system
    // (and select text in Vim, scroll elsewhere)
    func scrollGestureHandler (_ gestureRecognizer:  UIPanGestureRecognizer) {
        if (gestureRecognizer.state == .ended) || (gestureRecognizer.state == .cancelled) {
            return
        }
        guard gestureRecognizer.view != nil else { return }
        let piece = gestureRecognizer.view!
        // Get the changes in the X and Y directions relative to
        // the superview's coordinate space.
        let translation = gestureRecognizer.translation(in: piece.superview)
        let velocity = gestureRecognizer.velocity(in: piece.superview)
        NSLog("scrolling translation detected: \(translation) velocity: \(velocity)")
        if (gestureRecognizer.state == .began) {
            scrollGestureOrigin = .zero
        }
        var scrollDisplacement: CGPoint = translation
        scrollDisplacement.x -= scrollGestureOrigin.x
        scrollDisplacement.y -= scrollGestureOrigin.y
        // --> Number of arrows to send must be proportional to distance.
        var verticalDisplacement = CGFloat(terminalFontSize ?? factoryFontSize)
        let horizontalDisplacement = basicCharWidth
        let vimRunning = currentCommand.hasPrefix("vim ") || currentCommand == "vim"
        let lessRunning = currentCommand.hasPrefix("less ")
        || currentCommand.contains("|less") || currentCommand.contains("| less")
        || currentCommand.hasPrefix("man ") || currentCommand.hasPrefix("perldoc ")
        if (lessRunning) {
            // only vertical displacement, and reversed
            if (scrollDisplacement.y > 0) {
                let steps = floor(scrollDisplacement.y / verticalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "up")
                }
                scrollGestureOrigin.y += steps * verticalDisplacement
                scrollGestureOrigin.x = translation.x
            } else {
                let steps = floor(-scrollDisplacement.y / verticalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "down")
                }
                scrollGestureOrigin.y -= steps * verticalDisplacement
                scrollGestureOrigin.x = translation.x
            }
            return
        }
        if (!vimRunning) {
            verticalDisplacement *= 2
        }
        NSLog("total translation detected: \(scrollDisplacement.x/horizontalDisplacement) \(scrollDisplacement.y/verticalDisplacement)")
        if abs(scrollDisplacement.x) > abs(scrollDisplacement.y) {
            // lateral gesture
            if (scrollDisplacement.x > 0) {
                let steps = floor(scrollDisplacement.x / horizontalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "right")
                }
                scrollGestureOrigin.x += steps * horizontalDisplacement
                scrollGestureOrigin.y = translation.y
            } else {
                let steps = floor(-scrollDisplacement.x / horizontalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "left")
                }
                scrollGestureOrigin.x -= steps * horizontalDisplacement
                scrollGestureOrigin.y = translation.y            }
        } else {
            // vertical gesture
            if (scrollDisplacement.y > 0) {
                let steps = floor(scrollDisplacement.y / verticalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "down")
                }
                scrollGestureOrigin.y += steps * verticalDisplacement
                scrollGestureOrigin.x = translation.x
            } else {
                let steps = floor(-scrollDisplacement.y / verticalDisplacement)
                for _ in 0..<Int(steps) {
                    sendArrow(direction: "up")
                }
                scrollGestureOrigin.y -= steps * verticalDisplacement
                scrollGestureOrigin.x = translation.x
            }
        }
    }

    // VoiceOver and arrow buttons: speak the new command line with a slight delay.
    // Also applies to autocomplete suggestions since they can be cause by arrows.
    // We use the same timer as outputToTerminalView
    func delayedVoiceOver(message: String) {
        if (UIAccessibility.isVoiceOverRunning && !terminalView!.isCurrentBufferAlternate) {
            if (self.readContentTimer.isValid) {
                // restart the timer each time we add new content
                self.readContentTimer.invalidate()
            }
            self.readContentTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false, block: {_ in
                self.lastKeyboardInput = ""
                if (message.count > 0) {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            })
        }
    }
}

// BEGIN native agents Terminal.swift
import UIKit
import SwiftTerm
import ios_system

// All terminal access stays on the same main thread as human keyboard input.
// Compatibility only; relay owns the only listener.
final class AgentsTerminal {
    static let shared = AgentsTerminal()
    func commandWhenActive(_ argument: String) { command(argument, scene: TermTerminal.shared.scene()) }
    func command(_ argument: String, scene: SceneDelegate?) {
        let action = argument.isEmpty || argument == "reload" ? "on" : argument
        let (_, message) = Relay.shared.command(action)
        scene?.terminalView?.feed(text: message.replacingOccurrences(of: "\n", with: "\r\n"))
    }
    func stop() { _ = Relay.shared.command("off") }
}

@_cdecl("ashell_agents")
public func ashellAgents(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let argument = argc > 1 ? String(cString: argv![1]!) : ""
    DispatchQueue.main.async {
        AgentsTerminal.shared.commandWhenActive(argument)
    }
    return 0
}
import Foundation
import CoreFoundation

// The command and HTTP transport share this request contract. UIKit and Herdr
// are adapters at the boundary; neither transport owns terminal operations.
struct TermRequest: Codable, Sendable {
    let verb: String
    var window: String?
    var pane: String?
    var text: String?
    var bytes: Data?
    var keys: [String] = []
    var delays: [Int] = []
    var lines: Int?
    var timeout: Double = 30
    var columns: Int?
    var rows: Int?
    var json = false
    var colors = false

    static let help = """
    Usage: term <command> [--window ID] [--pane ID] [--json]
    Script and debug your own programs in another terminal or Herdr pane.
    Commands:
      windows                     List terminal windows and activation state
      panes                       List Herdr panes
      screen [--colors]           Read the visible terminal; --colors returns JSON
                                  cells with exact color indices/RGB and styles
      scrollback [--lines N]       Read terminal history
      type TEXT | --key KEY...     Type text or keyboard keys (enter, esc, ctrl-c,
                                  up, down, pgdn, pgup, home, end, tab, ...)
      keys BYTES                  Send raw UTF-8 or escapes: \\e \\n \\r \\t \\xHH \\\\
      paste TEXT                  Send bracketed paste when enabled
      wait --text REGEX [--timeout SECONDS]
                                  Wait for matching visible text; timeout exits 124
      size | cursor | state       Read geometry, cursor or command/session state
      resize COLSxROWS            Resize the target and notify its program
      clear                       Clear the visible display
      shot FILE.png               Save the rendered target
    Run from a different pane, window, script, Shortcuts or the agents bridge.
    Select a window explicitly when several are available; --pane selects a
    Herdr pane without changing keyboard focus. All reads accept --json.
    Anything running in a-Shell can read and type into its terminals.
    """

    struct Invalid: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func parse(_ arguments: [String]) throws -> TermRequest {
        guard let verb = arguments.first else { throw Invalid("missing command; use term --help") }
        let verbs = ["windows", "panes", "screen", "scrollback", "type", "keys", "paste", "wait", "size", "resize", "cursor", "clear", "state", "shot"]
        guard verbs.contains(verb) else { throw Invalid("unknown command: \(verb)") }
        var request = TermRequest(verb: verb)
        var positional: [String] = []
        var index = 1
        var literal = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if literal { positional.append(argument); continue }
            if argument == "--" { literal = true; continue }
            if argument == "--json" { request.json = true; continue }
            if argument == "--colors", verb == "screen" { request.colors = true; request.json = true; continue }
            if !argument.hasPrefix("--") { positional.append(argument); continue }
            guard index < arguments.count else { throw Invalid("missing value for \(argument)") }
            let value = arguments[index]
            index += 1
            switch argument {
            case "--window": request.window = value
            case "--pane": request.pane = value
            case "--key" where verb == "type": request.keys.append(value)
            case "--text" where verb == "wait": request.text = value
            case "--lines" where verb == "scrollback":
                guard let count = Int(value), (1...100000).contains(count) else { throw Invalid("--lines must be 1...100000") }
                request.lines = count
            case "--timeout" where verb == "wait":
                guard let seconds = Double(value), seconds.isFinite, (0...3600).contains(seconds) else { throw Invalid("--timeout must be 0...3600 seconds") }
                request.timeout = seconds
            default: throw Invalid("unsupported option for \(verb): \(argument)")
            }
        }
        switch verb {
        case "type", "keys", "paste", "shot":
            guard positional.count <= 1 else { throw Invalid("quote text as one argument") }
            if let text = positional.first { request.text = text }
            guard request.text != nil || (verb == "type" && !request.keys.isEmpty) else { throw Invalid("\(verb) requires text") }
            if verb == "keys" { request.bytes = try unescape(request.text!) }
        case "resize":
            guard positional.count == 1 else { throw Invalid("resize requires COLSxROWS") }
            let parts = positional[0].split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]), (1...1000).contains(cols), (1...1000).contains(rows) else { throw Invalid("resize requires COLSxROWS, each 1...1000") }
            request.columns = cols
            request.rows = rows
        default:
            guard positional.isEmpty else { throw Invalid("unexpected argument: \(positional[0])") }
        }
        if verb == "wait" {
            guard let pattern = request.text else { throw Invalid("wait requires --text REGEX") }
            _ = try NSRegularExpression(pattern: pattern)
        }
        return request
    }

    static func http(_ target: String, body: Data) throws -> TermRequest {
        guard let url = URLComponents(string: target) else { throw Invalid("invalid terminal URL") }
        let verb = String(url.path.dropFirst())
        let input: [String: Any]
        if body.isEmpty { input = [:] }
        else {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Invalid("expected a JSON object") }
            input = object
        }
        var arguments = [verb]
        let allowed = ["window", "pane", "text", "lines", "timeout", "columns", "rows", "keys", "delay_ms", "colors"]
        guard input.keys.allSatisfy({ allowed.contains($0) }) else { throw Invalid("unknown terminal request field") }
        var values = input
        for item in url.queryItems ?? [] {
            guard allowed.contains(item.name), item.name != "keys", item.name != "delay_ms", values[item.name] == nil, let value = item.value else { throw Invalid("invalid or repeated terminal query field: \(item.name)") }
            values[item.name] = value
        }
        for key in ["window", "pane", "lines", "timeout"] {
            if let value = values[key] { arguments += ["--" + key, String(describing: value)] }
        }
        if let colors = values["colors"] {
            let flag: Bool
            if let text = colors as? String, ["true", "false"].contains(text) { flag = text == "true" }
            else if let value = colors as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { flag = value.boolValue }
            else { throw Invalid("colors must be true or false for screen") }
            guard verb == "screen" else { throw Invalid("colors is only supported for screen") }
            if flag { arguments.append("--colors") }
        }
        if verb == "resize" {
            guard let columns = values["columns"], let rows = values["rows"] else { throw Invalid("resize requires columns and rows") }
            arguments.append("\(columns)x\(rows)")
        }
        // HTTP streams the PNG; only the CLI needs a destination pathname.
        if verb == "shot" { arguments += ["--", "http.png"] }
        if let text = values["text"] {
            guard let text = text as? String else { throw Invalid("text must be a string") }
            arguments += verb == "wait" ? ["--text", text] : ["--", text]
        }
        // Key options precede '--' so literal input cannot be parsed as flags.
        if let keys = values["keys"] {
            guard verb == "type", let keys = keys as? [String] else { throw Invalid("keys must be a string array for type") }
            arguments.insert(contentsOf: keys.flatMap { ["--key", $0] }, at: 1)
        }
        var request = try parse(arguments)
        if let delays = values["delay_ms"] {
            guard let delays = delays as? [Int] else { throw Invalid("delay_ms must be an integer array") }
            request.delays = delays
        }
        request.json = true
        return request
    }

    static func unescape(_ text: String) throws -> Data {
        var bytes: [UInt8] = []
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte != 92 { bytes.append(byte); continue }
            guard let escaped = iterator.next() else { throw Invalid("trailing backslash") }
            switch escaped {
            case 92: bytes.append(92)
            case 101: bytes.append(27)
            case 110: bytes.append(10)
            case 114: bytes.append(13)
            case 116: bytes.append(9)
            case 120:
                guard let a = iterator.next(), let b = iterator.next(), let value = UInt8(String(bytes: [a, b], encoding: .ascii) ?? "", radix: 16) else { throw Invalid("expected \\xHH") }
                bytes.append(value)
            default: throw Invalid("unknown byte escape")
            }
        }
        return Data(bytes)
    }
}

#if os(iOS)
@objc protocol TermControlWire {
    func terminal(_ request: Data, reply: @escaping (Int, Data, String) -> Void)
}
#endif

struct TermResponse: Sendable {
    var status: Int
    var data: Data
    var contentType = "application/json; charset=utf-8"
    init(_ value: [String: Any]) { self.init(200, value) }
    init(_ status: Int, _ value: [String: Any]) {
        self.status = status
        self.data = (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? Data()
    }
    init(status: Int, data: Data, contentType: String = "application/json; charset=utf-8") {
        self.status = status
        self.data = data
        self.contentType = contentType
    }
    static func error(_ status: Int, _ message: String) -> TermResponse { TermResponse(status, ["error": message]) }

    func output(for request: TermRequest) -> Data {
        if request.json || contentType == "image/png" { return data + (contentType == "image/png" ? Data() : Data([10])) }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        let text: String
        if let error = value["error"] as? String { text = error }
        else if let rows = value["rows"] as? [String] { text = rows.joined(separator: "\n") }
        else if let history = value["text"] as? String { text = history }
        else if request.verb == "size" { text = "\(value["columns"] ?? 0)x\(value["height"] ?? 0)" }
        else { text = String(data: data, encoding: .utf8) ?? "" }
        return Data((text + "\n").utf8)
    }
}

enum TermCommand {
    // The real command entry captures its thread-local streams before hopping to UIKit.
    static func run(_ arguments: [String], perform: (TermRequest, @escaping (TermResponse) -> Void) -> Void, write: (Data, Bool) -> Void) -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            write(Data((TermRequest.help + "\n").utf8), false)
            return 0
        }
        do {
            let request = try TermRequest.parse(arguments)
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var response: TermResponse?
            perform(request) { result in
                lock.lock()
                defer { lock.unlock() }
                guard response == nil else { return }
                response = result
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + (request.verb == "wait" ? request.timeout : 10) + 15) == .success else {
                write(TermResponse.error(503, "terminal service did not reply").output(for: request), true)
                return 1
            }
            guard let response else { return 1 }
            if request.verb == "shot", response.status == 200 {
                try response.data.write(to: URL(fileURLWithPath: request.text!), options: .atomic)
                if request.json { write(TermResponse(["path": request.text!, "bytes": response.data.count]).data + Data([10]), false) }
            } else {
                write(response.output(for: request), response.status != 200)
            }
            return response.status == 200 ? 0 : response.status == 408 ? 124 : 1
        } catch {
            write(Data(("term: \(error.localizedDescription)\n").utf8), true)
            return 2
        }
    }
}
import Foundation

#if HERDR_EMBEDDED
@_silgen_name("herdr_ios_terminal_json")
private func herdrTerminalJSON(_ input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("herdr_ios_terminal_free")
private func herdrTerminalFree(_ value: UnsafeMutablePointer<CChar>)
#endif

enum TermPane {
    static func perform(_ request: TermRequest, reply: @escaping (TermResponse) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            #if HERDR_EMBEDDED
            do {
                func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
                    let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params])
                    let text = String(decoding: data, as: UTF8.self)
                    guard let pointer = text.withCString({ herdrTerminalJSON($0) }) else { throw TermRequest.Invalid("Herdr returned no terminal response") }
                    defer { herdrTerminalFree(pointer) }
                    let value = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any] ?? [:]
                    if let error = value["error"] as? [String: Any] {
                        if error["code"] as? String == "timeout" { throw PaneTimeout() }
                        throw TermRequest.Invalid(error["message"] as? String ?? "Herdr terminal request failed")
                    }
                    guard let result = value["result"] as? [String: Any] else { throw TermRequest.Invalid("invalid Herdr terminal response") }
                    return result
                }
                if request.verb == "panes" { reply(TermResponse(try call("pane.list", [:]))); return }
                guard let pane = request.pane else { throw TermRequest.Invalid("select --pane ID from term panes") }
                var params: [String: Any] = ["pane": pane, "verb": request.verb, "keys": request.keys.map { key in
                    ["ctrl-c": "ctrl+c", "pgdn": "pagedown", "pgup": "pageup", "esc": "escape"][key.lowercased()] ?? key
                }]
                if let text = request.text { params["text"] = text }
                if let bytes = request.bytes { params["bytes"] = Array(bytes) }
                if let lines = request.lines { params["lines"] = lines }
                if let cols = request.columns { params["columns"] = cols }
                if let rows = request.rows { params["height"] = rows }
                if request.verb == "wait" {
                    _ = try call("pane.wait_for_output", ["pane_id": pane, "source": "visible", "match": ["type": "regex", "value": request.text ?? ""], "timeout_ms": Int(request.timeout * 1000)])
                    params["verb"] = "screen"
                }
                if request.verb == "type" {
                    let delays = request.delays.isEmpty ? Array(repeating: 0, count: request.keys.count) : request.delays
                    guard delays.count == request.keys.count, request.keys.count <= 256, delays.allSatisfy({ (0...2000).contains($0) }), delays.reduce(0, +) <= 10000 else { throw TermRequest.Invalid("invalid key delays") }
                    // Validate the entire sequence before sending its text.
                    var validation = params
                    validation["verb"] = "validate"
                    _ = try call("terminal.control", validation)
                    let keys = params["keys"] as? [String] ?? []
                    params["keys"] = [String]()
                    _ = try call("terminal.control", params)
                    params.removeValue(forKey: "text")
                    for (index, key) in keys.enumerated() {
                        if delays[index] > 0 { Thread.sleep(forTimeInterval: Double(delays[index]) / 1000) }
                        params["keys"] = [key]
                        _ = try call("terminal.control", params)
                    }
                    params["verb"] = "screen"
                }
                reply(TermResponse(try call("terminal.control", params)))
            } catch is PaneTimeout { reply(.error(408, "screen wait timed out")) }
            catch { reply(.error(409, error.localizedDescription)) }
            #else
            reply(.error(501, "Herdr is not embedded in this build"))
            #endif
        }
    }

    private struct PaneTimeout: Error {}
}
import UIKit
import SwiftTerm
import ios_system

// Main-thread ownership matches UIKit keyboard input and terminal output.
final class TermTerminal {
    static let shared = TermTerminal()
    private var typing: Set<String> = []
    private var screens: [String: Data] = [:]
    private var sequences: [String: UInt64] = [:]

    private func scenes() -> [SceneDelegate] {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.filter { $0.terminalView != nil }
    }

    private func connected(_ scene: SceneDelegate, _ view: TerminalView) -> Bool {
        scenes().contains { $0 === scene } && scene.terminalView === view
    }

    private func visible(_ scene: SceneDelegate) -> Bool {
        guard let window = scene.terminalView?.window, !window.isHidden, window.alpha > 0 else { return false }
        return window.windowScene?.activationState == .foregroundActive || window.windowScene?.activationState == .foregroundInactive
    }

    func scene(window: String? = nil) -> SceneDelegate? {
        let terminals = scenes()
        let candidates: [SceneDelegate]
        if let window {
            candidates = terminals.filter { $0.persistentIdentifier == window }
        } else if terminals.count == 1 {
            candidates = terminals
        } else {
            candidates = terminals.filter { visible($0) }
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    func perform(_ request: TermRequest, reply: @escaping (TermResponse) -> Void) {
        precondition(Thread.isMainThread)
        if request.verb == "windows" {
            reply(TermResponse(["windows": scenes().map { scene -> [String: Any] in
                ["window": scene.persistentIdentifier ?? "", "foreground": visible(scene), "active": scene.terminalView?.window?.windowScene?.activationState == .foregroundActive, "command": scene.currentCommand]
            }]))
            return
        }
        let terminals = scenes()
        guard let scene = scene(window: request.window), let view = scene.terminalView else {
            if request.window == nil, !terminals.isEmpty {
                reply(TermResponse(409, ["error": "ambiguous terminal; select --window ID", "windows": terminals.map { $0.persistentIdentifier ?? "" }]))
            } else {
                reply(.error(503, "no connected terminal for the selected window"))
            }
            return
        }
        if request.verb == "shot", !visible(scene) {
            reply(.error(503, "background terminal screenshot unavailable: UIKit view rendering requires a foreground scene"))
            return
        }
        if request.pane != nil || request.verb == "panes" {
            guard scene.currentCommand.hasPrefix("herdr") else { reply(.error(409, "selected window is not running Herdr")); return }
            let identity = "\(scene.persistentIdentifier ?? "")/\(request.pane ?? "")"
            let sendsInput = ["type", "keys", "paste"].contains(request.verb)
            if sendsInput {
                guard !typing.contains(identity) else { reply(.error(409, "a key sequence is already running for this pane")); return }
                typing.insert(identity)
            }
            TermPane.perform(request) { response in
                DispatchQueue.main.async {
                    if sendsInput { self.typing.remove(identity) }
                    guard self.connected(scene, view) else { reply(.error(503, "target terminal disconnected")); return }
                    if request.verb == "shot", response.status == 200 {
                        guard self.visible(scene) else { reply(.error(503, "background terminal screenshot unavailable: UIKit view rendering requires a foreground scene")); return }
                        reply(self.paneImage(response, view))
                    } else if request.verb == "state", response.status == 200, var value = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                        value["foreground"] = self.visible(scene)
                        value["active"] = view.window?.windowScene?.activationState == .foregroundActive
                        value["window"] = scene.persistentIdentifier ?? ""
                        reply(TermResponse(value))
                    } else { reply(response) }
                }
            }
            return
        }
        let terminal = view.getTerminal()
        switch request.verb {
        case "screen": reply(snapshot(scene, view, colors: request.colors))
        case "scrollback":
            let last = terminal.buffer.yDisp + terminal.rows
            let first = max(0, last - (request.lines ?? last))
            let rows = (first..<last).map { terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + $0)?.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ") ?? "" }
            reply(TermResponse(["rows": rows, "window": scene.persistentIdentifier ?? ""]))
        case "size": reply(TermResponse(["columns": terminal.cols, "height": terminal.rows]))
        case "cursor":
            let cursor = terminal.getCursorLocation()
            reply(TermResponse(["row": cursor.y, "column": cursor.x]))
        case "state":
            reply(TermResponse(["foreground": visible(scene), "active": view.window?.windowScene?.activationState == .foregroundActive, "command": scene.currentCommand, "pid": scene.pid, "pid_kind": "ios_system session", "window": scene.persistentIdentifier ?? ""]))
        case "resize":
            guard let cols = request.columns, let rows = request.rows else { reply(.error(400, "resize requires geometry")); return }
            terminal.resize(cols: cols, rows: rows)
            scene.sizeChanged(source: view, newCols: cols, newRows: rows)
            reply(TermResponse(["columns": terminal.cols, "height": terminal.rows]))
        case "clear":
            view.feed(text: "\u{1b}[H\u{1b}[2J")
            reply(snapshot(scene, view))
        case "shot":
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in view.layer.render(in: context.cgContext) }
            guard let bytes = image.pngData() else { reply(.error(500, "PNG encoding failed")); return }
            reply(TermResponse(status: 200, data: bytes, contentType: "image/png"))
        case "wait": wait(request, scene, view, reply: reply)
        case "type", "keys", "paste": type(request, scene, view, reply: reply)
        default: reply(.error(400, "unknown terminal operation"))
        }
    }

    private func paneImage(_ response: TermResponse, _ view: TerminalView) -> TermResponse {
        guard let value = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], let cells = value["cells"] as? [[[String: Any]]], let columns = value["columns"] as? Int, let rows = value["height"] as? Int else { return .error(500, "invalid rendered pane") }
        let font = view.font
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cellHeight = font.lineHeight
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            view.nativeBackgroundColor.setFill()
            UIRectFill(bounds)
            for (row, line) in cells.enumerated() {
                for (column, cell) in line.enumerated() {
                    let rect = CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
                    Self.color(cell["background"] as? String, fallback: view.nativeBackgroundColor).setFill()
                    UIRectFill(rect)
                }
            }
            // Paint all backgrounds before glyphs so a wide glyph survives its
            // following display cell; UIKit shapes combining characters together.
            for (row, line) in cells.enumerated() {
                for (column, cell) in line.enumerated() {
                    var traits: UIFontDescriptor.SymbolicTraits = []
                    if cell["bold"] as? Bool == true { traits.insert(.traitBold) }
                    if cell["italic"] as? Bool == true { traits.insert(.traitItalic) }
                    let styled = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
                    var foreground = Self.color(cell["foreground"] as? String, fallback: view.nativeForegroundColor)
                    if cell["dim"] as? Bool == true { foreground = foreground.withAlphaComponent(0.5) }
                    var attributes: [NSAttributedString.Key: Any] = [.font: styled, .foregroundColor: foreground]
                    if cell["underline"] as? Bool == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if cell["strike"] as? Bool == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    (cell["text"] as? String ?? " ").draw(at: CGPoint(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight), withAttributes: attributes)
                }
            }
            if let cursor = value["cursor"] as? [String: Any], cursor["visible"] as? Bool == true, let column = cursor["column"] as? Int, let row = cursor["row"] as? Int {
                view.caretColor.setStroke()
                UIRectFrame(CGRect(x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight))
            }
        }
        guard let png = image.pngData() else { return .error(500, "PNG encoding failed") }
        return TermResponse(status: 200, data: png, contentType: "image/png")
    }

    private static func color(_ name: String?, fallback: UIColor) -> UIColor {
        guard let name else { return fallback }
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 16) {
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let colors: [String: UIColor] = ["Black": .black, "Red": .red, "Green": .green, "Yellow": .yellow, "Blue": .blue, "Magenta": .magenta, "Cyan": .cyan, "Gray": .lightGray, "DarkGray": .darkGray, "White": .white]
        return colors[name] ?? fallback
    }

    private func snapshot(_ scene: SceneDelegate, _ view: TerminalView, colors: Bool = false) -> TermResponse {
        let terminal = view.getTerminal()
        let rows = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ") ?? "" }
        let cursor = terminal.getCursorLocation()
        let cells: [[Any]] = (0..<terminal.rows).map { row in
            (0..<terminal.cols).map { column -> Any in
                let text = terminal.getCharacter(col: column, row: row).map { $0 == "\0" ? " " : String($0) } ?? " "
                guard colors, let cell = terminal.getCharData(col: column, row: row) else { return text }
                let attribute = cell.attribute
                let style = attribute.style
                return ["text": text, "foreground": Self.cellColor(attribute.fg), "background": Self.cellColor(attribute.bg),
                    "bold": style.contains(.bold), "italic": style.contains(.italic), "dim": style.contains(.dim),
                    "underline": style.contains(.underline) || attribute.underlineStyle != .none, "strike": style.contains(.crossedOut),
                    "inverse": style.contains(.inverse), "invisible": style.contains(.invisible), "blink": style.contains(.blink)] as [String: Any]
            }
        }
        let window = scene.persistentIdentifier ?? ""
        var value: [String: Any] = ["rows": rows, "cells": cells, "columns": terminal.cols, "height": terminal.rows, "cursor": ["row": cursor.y, "column": cursor.x], "window": window, "pane": "main"]
        let content = TermResponse(value).data
        if screens[window] != content {
            screens[window] = content
            sequences[window, default: 0] += 1
        }
        value["seq"] = sequences[window, default: 0]
        return TermResponse(value)
    }

    private static func cellColor(_ color: Attribute.Color) -> String {
        switch color {
        case .ansi256(let code): return String(code)
        case .trueColor(let red, let green, let blue): return String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
        case .defaultColor, .defaultInvertedColor: return "Reset"
        }
    }

    private func type(_ request: TermRequest, _ scene: SceneDelegate, _ view: TerminalView, reply: @escaping (TermResponse) -> Void) {
        let identity = scene.persistentIdentifier ?? ""
        let keys = request.keys
        let delays = request.delays.isEmpty ? Array(repeating: 0, count: keys.count) : request.delays
        guard keys.count <= 256, delays.count == keys.count, delays.allSatisfy({ (0...2000).contains($0) }), delays.reduce(0, +) <= 10000 else {
            reply(.error(400, "delay_ms must match keys, each 0...2000 ms, total <=10000 ms, at most 256 keys")); return
        }
        let aliases = ["pgdn": "pagedown", "pgup": "pageup"]
        let normalized = keys.map { aliases[$0.lowercased()] ?? $0 }
        for key in normalized where view.getTerminal().encodeKeyboardKey(key, backspaceSendsControlH: view.backspaceSendsControlH) == nil {
            reply(.error(400, "unknown or unrepresentable key: \(key)")); return
        }
        guard !typing.contains(identity) else { reply(.error(409, "a key sequence is already running for this window")); return }
        typing.insert(identity)
        if request.verb == "keys" {
            let bytes = Array(request.bytes ?? Data((request.text ?? "").utf8))
            view.send(data: bytes[...])
        } else if request.verb == "paste" {
            let terminal = view.getTerminal()
            if terminal.bracketedPasteMode { view.send(data: Array("\u{1b}[200~".utf8)[...]) }
            view.send(data: Array((request.text ?? "").utf8)[...])
            if terminal.bracketedPasteMode { view.send(data: Array("\u{1b}[201~".utf8)[...]) }
        } else if let text = request.text {
            // The shell line editor recognizes Return only as a separate input.
            for character in text { view.insertText(String(character)) }
        }
        func step(_ index: Int) {
            guard self.connected(scene, view) else {
                self.typing.remove(identity)
                reply(.error(409, "target terminal disconnected")); return
            }
            if index == normalized.count {
                self.typing.remove(identity)
                reply(self.snapshot(scene, view)); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delays[index])) {
                guard self.connected(scene, view), let bytes = view.getTerminal().encodeKeyboardKey(normalized[index], backspaceSendsControlH: view.backspaceSendsControlH) else {
                    self.typing.remove(identity)
                    reply(.error(409, "target terminal or key mode changed")); return
                }
                if normalized[index].lowercased() == "enter", view.getTerminal().keyboardEnhancementFlags.isEmpty { view.insertText("\n") }
                else { view.send(data: bytes[...]) }
                step(index + 1)
            }
        }
        step(0)
    }

    private func wait(_ request: TermRequest, _ scene: SceneDelegate, _ view: TerminalView, reply: @escaping (TermResponse) -> Void) {
        guard let pattern = request.text, let regex = try? NSRegularExpression(pattern: pattern) else { reply(.error(400, "invalid --text regular expression")); return }
        var observer: NSObjectProtocol?
        var disconnectObserver: NSObjectProtocol?
        var finished = false
        var timeout: DispatchWorkItem?
        func complete(_ response: TermResponse) {
            guard !finished else { return }
            finished = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
            timeout?.cancel()
            reply(response)
        }
        func check() {
            guard self.connected(scene, view) else { complete(.error(503, "target terminal disconnected")); return }
            let snapshot = self.snapshot(scene, view)
            let object = try? JSONSerialization.jsonObject(with: snapshot.data) as? [String: Any]
            let text = (object?["rows"] as? [String] ?? []).joined(separator: "\n")
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { complete(snapshot) }
        }
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("AShellTerminalOutput"), object: view.getTerminal(), queue: .main) { _ in check() }
        disconnectObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: view.window?.windowScene, queue: .main) { _ in check() }
        timeout = DispatchWorkItem { complete(.error(408, "screen wait timed out")) }
        DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: timeout!)
        check()
    }
}

final class TermControlService: NSObject, TermControlWire {
    static let shared = TermControlService()
    func terminal(_ data: Data, reply: @escaping (Int, Data, String) -> Void) {
        do {
            let request = try JSONDecoder().decode(TermRequest.self, from: data)
            DispatchQueue.main.async {
                TermTerminal.shared.perform(request) { result in reply(result.status, result.data, result.contentType) }
            }
        } catch { reply(400, Data(error.localizedDescription.utf8), "text/plain; charset=utf-8") }
    }
}

@_cdecl("ashell_term")
public func ashellTerm(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard argc > 0, let argv else { return 2 }
    guard !Thread.isMainThread else { return 1 }
    let arguments = (1..<Int(argc)).map { String(cString: argv[$0]!) }
    // ios_system streams belong to this command thread, never the UI callback.
    let output = thread_stdout
    let error = thread_stderr
    return TermCommand.run(arguments, perform: { request, reply in
        DispatchQueue.main.async { TermTerminal.shared.perform(request, reply: reply) }
    }, write: { bytes, failed in
        guard let stream = failed ? error : output else { return }
        bytes.withUnsafeBytes { buffer in
            if let address = buffer.baseAddress { _ = fwrite(address, 1, buffer.count, stream) }
        }
        fflush(stream)
    })
}
