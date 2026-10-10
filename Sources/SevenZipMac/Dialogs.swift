import AppKit
import ArchiveCore

final class FormDialog {
    let alert = NSAlert()
    let stack = NSStackView()
    var rows = 0
    var actionTargets: [AnyObject] = []
    init(_ title: String, message: String = "") {
        alert.messageText = L(title); alert.informativeText = L(message)
        alert.addButton(withTitle: L("Continue")); alert.addButton(withTitle: L("Cancel"))
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
    }
    func field(_ title: String, _ value: String = "", secure: Bool = false) -> NSTextField {
        let f = secure ? NSSecureTextField(string:value) : NSTextField(string:value)
        f.widthAnchor.constraint(equalToConstant:340).isActive = true; row(title,f); return f
    }
    func multiline(_ title: String, _ value: String) -> NSTextView {
        let text = NSTextView(frame:NSRect(x:0,y:0,width:330,height:90)); text.isRichText = false; text.font = .systemFont(ofSize:12); text.string = value; text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant:340).isActive = true; scroll.heightAnchor.constraint(equalToConstant:100).isActive = true; row(title,scroll); rows += 3; return text
    }
    func path(_ title: String, _ value: String, directory: Bool) -> NSTextField {
        let f = NSTextField(string:value); f.widthAnchor.constraint(equalToConstant:260).isActive = true
        let target = PathChooser(field:f,directory:directory); actionTargets.append(target)
        let browse = NSButton(title:L("Choose…"),target:target,action:#selector(PathChooser.choose)); browse.bezelStyle = .rounded
        let group = NSStackView(views:[f,browse]); group.spacing = 4; group.widthAnchor.constraint(equalToConstant:340).isActive = true; row(title,group); return f
    }
    func popup(_ title: String, _ choices: [String], selected: String = "") -> NSPopUpButton {
        let p = NSPopUpButton(); p.addItems(withTitles: choices.map(L)); for (item,value) in zip(p.itemArray,choices) { item.representedObject = value }; if let index = choices.firstIndex(of:selected) { p.selectItem(at:index) }
        p.widthAnchor.constraint(equalToConstant:340).isActive = true; row(title,p); return p
    }
    func check(_ title: String, _ value: Bool = false) -> NSButton {
        let b = NSButton(checkboxWithTitle:L(title),target:nil,action:nil); b.state = value ? .on : .off
        stack.addArrangedSubview(b); rows += 1; return b
    }
    func passwordVisibility(_ fields: [NSTextField]) {
        let control = PasswordVisibility(fields:fields); actionTargets.append(control)
        let check = self.check("Show password"); check.target = control; check.action = #selector(PasswordVisibility.toggle(_:))
    }
    func note(_ title: String) { let f = NSTextField(wrappingLabelWithString:L(title)); f.font = .systemFont(ofSize:11); f.textColor = .secondaryLabelColor; f.widthAnchor.constraint(equalToConstant:500).isActive = true; stack.addArrangedSubview(f); rows += 1 }
    func row(_ title: String, _ control: NSView) {
        let label = NSTextField(labelWithString:L(title)); label.widthAnchor.constraint(equalToConstant:145).isActive = true
        let s = NSStackView(views:[label,control]); s.spacing = 8; s.alignment = .centerY; stack.addArrangedSubview(s); rows += 1
    }
    func run() -> Bool {
        // Measure the actual controls instead of estimating height from row count.
        // Short forms fit directly in the alert; long forms scroll from the top.
        stack.removeFromSuperview()
        let content = FlippedFormView()
        content.addSubview(stack)
        let constraints = [stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:8),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:8),stack.widthAnchor.constraint(equalToConstant:500)]
        NSLayoutConstraint.activate(constraints)
        content.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 16
        content.setFrameSize(NSSize(width:516,height:height))
        let available = min(CGFloat(540),(NSScreen.main?.visibleFrame.height ?? 800) - 240)
        if height <= available {
            alert.accessoryView = content
        } else {
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:536,height:available))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.documentView = content; alert.accessoryView = scroll
            scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
struct CompressionDialogResult { var output: URL; var options: CompressionOptions; var createExtractor = false }
func compressionDialog(inputs: [URL], proposed: URL?, password initialPassword: String = "", allowSourceDeletion: Bool = true) -> CompressionDialogResult? {
    let defaults = UserDefaults.standard
    let form = FormDialog("Add to Archive",message:"\(inputs.count) input item(s). Advanced values are validated before the engine starts.")
    let base = proposed ?? inputs[0].deletingLastPathComponent().appendingPathComponent(inputs[0].deletingPathExtension().lastPathComponent + ".7z")
    let path = form.path("Archive",base.path,directory:false)
    let format = form.popup("Format",["7z","zip","tar","gzip","bzip2","xz","wim"],selected:["gz":"gzip","bz2":"bzip2" ][proposed?.pathExtension ?? ""] ?? proposed?.pathExtension ?? defaults.string(forKey:"format") ?? "7z")
    let level = form.popup("Compression level",["0 — Store","1 — Fastest","3 — Fast","5 — Normal","7 — Maximum","9 — Ultra"],selected:defaults.string(forKey:"levelLabel") ?? "5 — Normal")
    let method = form.popup("Method",["Automatic","LZMA2","LZMA","PPMd","BZip2","Deflate","Deflate64","Copy"])
    let dictionary = form.field("Dictionary size",defaults.string(forKey:"dictionary") ?? "",secure:false); dictionary.placeholderString = L("e.g. 64m, empty = automatic")
    let word = form.field("Word size"); word.placeholderString = L("e.g. 64, empty = automatic")
    let solid = form.popup("Solid block size",["on","off","16m","64m","256m","1g","4g"],selected:defaults.string(forKey:"solid") ?? "on")
    let threads = form.field("CPU threads",String(defaults.integer(forKey:"threads"))); threads.placeholderString = L("0 = automatic")
    let pathMode = form.popup("Path storage",["Relative paths","Full paths without root","Absolute paths"],selected:defaults.string(forKey:"compressionPathModeLabel") ?? "Relative paths")
    let memory = form.field("Compression memory budget",defaults.string(forKey:"compressionMemoryLimit") ?? ""); memory.placeholderString = L("e.g. p60 or 512m; empty = automatic")
    let latest = form.check("Set archive time to the latest file time",defaults.bool(forKey:"archiveTimeLatest"))
    let volume = form.field("Split volumes"); volume.placeholderString = L("e.g. 100m, empty = single archive")
    let extractor = form.check("Create a macOS self-extracting .app")
    let extractorTarget = ExtractorOptionController(volume:volume,option:extractor); form.actionTargets.append(extractorTarget); volume.delegate = extractorTarget; extractorTarget.update()
    form.note("The extractor is a macOS application containing the archive. Split volumes cannot be used.")
    let update = form.popup("Update mode",UpdateMode.allCases.map(\.rawValue))
    let password = form.field("Password",initialPassword,secure:true); let repeatPassword = form.field("Repeat password",initialPassword,secure:true)
    form.passwordVisibility([password,repeatPassword])
    let encryption = form.popup("Encryption",["AES256","AES192","AES128","ZipCrypto"])
    let headers = form.check("Encrypt file names (7z only)",proposed != nil && !initialPassword.isEmpty)
    let shared = form.check("Compress files open for writing")
    let deleteSources = form.check("Delete source files after successful compression (permanent)")
    deleteSources.isEnabled = allowSourceDeletion
    if !allowSourceDeletion { form.note("Source deletion is unavailable when placing staged copies into an archive subfolder. Add at the archive root to use the engine's source deletion option.") }
    let symbolic = form.check("Store symbolic links as links",true)
    let hard = form.check("Store hard links as links")
    let preserveAccess = form.check("Preserve source file access times")
    let modification = form.popup("Modification time",["Default","Store","Omit"])
    let creation = form.popup("Creation time",["Default","Store","Omit"])
    let access = form.popup("Access time",["Default","Store","Omit"])
    let precision = form.popup("Time precision",["Automatic","Windows 100 ns","Unix seconds","DOS 2 seconds","Nanoseconds","Seconds","Milliseconds","Microseconds","100 nanoseconds","Exact nanoseconds"])
    let exclusions = form.field("Exclude patterns"); exclusions.placeholderString = L("One pattern per semicolon, e.g. *.tmp;.DS_Store")
    let parameters = form.field("Method parameters"); parameters.placeholderString = L("e.g. -mmt=4 -mtc=on -mta=on (method switches only)")
    let formatTarget = CompressionFormatController(format:format,method:method,solid:solid,headers:headers,encryption:encryption,password:password,repeatPassword:repeatPassword,dictionary:dictionary,word:word,path:path,symbolic:symbolic,hard:hard,timestamps:[modification,creation,access],precision:precision,memory:memory)
    form.actionTargets.append(formatTarget); format.target = formatTarget; format.action = #selector(CompressionFormatController.update); precision.target = formatTarget; precision.action = #selector(CompressionFormatController.update); method.target = formatTarget; method.action = #selector(CompressionFormatController.update); formatTarget.update()
    form.note("gzip, bzip2 and xz accept one file. Passwords remain in memory only. Synchronize removes archive entries absent from the input.")
    while form.run() {
        guard password.stringValue == repeatPassword.stringValue else { showError(UIError(message:"Passwords do not match.")); continue }
        guard !path.stringValue.isEmpty, let count = Int(threads.stringValue), count >= 0 else { showError(UIError(message:"Provide an archive path and a nonnegative thread count.")); continue }
        var options = CompressionOptions(); options.format = format.selectedValue!; options.level = Int(level.selectedValue!.prefix(1))!
        options.method = method.indexOfSelectedItem == 0 ? "" : method.selectedValue!
        options.dictionary = dictionary.stringValue; options.wordSize = word.stringValue; options.solid = solid.selectedValue!
        options.pathMode = [.relative,.full,.absolute][pathMode.indexOfSelectedItem]; options.memoryLimit = memory.isEnabled ? memory.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) : ""; options.setArchiveTimeToLatest = latest.state == .on
        options.threads = count; options.volumeSize = volume.stringValue; options.password = password.stringValue; options.encryptionMethod = encryption.selectedValue!
        options.encryptHeaders = headers.state == .on; options.compressShared = shared.state == .on
        options.deleteSourcesAfterCompression = deleteSources.state == .on
        if options.deleteSourcesAfterCompression && !confirm("Permanently delete source files?","After successful compression, 7-Zip will permanently delete source files from the \(inputs.count) selected item(s), including files inside selected folders. They will not go to Trash.",destructive:true) { continue }
        options.storeSymbolicLinks = symbolic.state == .on; options.storeHardLinks = hard.state == .on; options.preserveAccessTime = preserveAccess.state == .on
        options.updateMode = UpdateMode(rawValue:update.selectedValue!)!
        options.exclusions = exclusions.stringValue.split(separator:";").map(String.init); options.parameters = parameters.stringValue
        options.modificationTime = [.automatic,.store,.omit][modification.indexOfSelectedItem]; options.creationTime = [.automatic,.store,.omit][creation.indexOfSelectedItem]; options.accessTime = [.automatic,.store,.omit][access.indexOfSelectedItem]
        options.timePrecision = ArchiveTimePrecision(rawValue:precision.selectedValue.flatMap(Int.init) ?? -1) ?? .automatic
        if options.updateMode == .synchronize && !confirm("Synchronize archive?","Entries not present in the selected inputs can be removed.",destructive:true) { continue }
        var output = URL(fileURLWithPath:(path.stringValue as NSString).expandingTildeInPath)
        if proposed == nil && output.pathExtension == "7z" && options.format != "7z" { output = output.deletingPathExtension().appendingPathExtension(options.format) }
        defaults.set(pathMode.selectedValue,forKey:"compressionPathModeLabel"); defaults.set(options.memoryLimit,forKey:"compressionMemoryLimit"); defaults.set(options.setArchiveTimeToLatest,forKey:"archiveTimeLatest")
        defaults.set(options.format,forKey:"format"); defaults.set(level.selectedValue,forKey:"levelLabel"); defaults.set(options.dictionary,forKey:"dictionary"); defaults.set(options.solid,forKey:"solid"); defaults.set(count,forKey:"threads")
        if extractor.state == .on && (!volume.stringValue.isEmpty || Bundle.main.bundleURL.pathExtension != "app") { showError(UIError(message:"A macOS extractor requires a bundled application and a single-volume archive.")); continue }
        return CompressionDialogResult(output:output,options:options,createExtractor:extractor.state == .on)
    }
    return nil
}
func extractionDialog(archive: URL, selected: [String], password: String) -> ExtractionOptions? {
    let defaults = UserDefaults.standard
    let form = FormDialog("Extract Archive",message:archive.lastPathComponent)
    let dest = form.path("Destination",archive.deletingLastPathComponent().path,directory:true)
    let separate = form.check("Extract into an archive-named subfolder",defaults.object(forKey:"separateExtractFolder") == nil || defaults.bool(forKey:"separateExtractFolder"))
    let remap = form.check("Map absolute archive paths into the destination",defaults.bool(forKey:"remapAbsolutePaths"))
    form.note("Absolute paths are mapped inside the chosen destination; original disk roots are never used.")
    let paths = form.popup("Paths",["Full paths","Flat (all files in one folder)"],selected:defaults.bool(forKey:"flatExtract") ? "Flat (all files in one folder)" : "Full paths")
    let collision = form.popup("Existing files",["Skip","Overwrite","Rename extracted file","Rename existing file","Ask for each conflict"],selected:defaults.string(forKey:"overwriteLabel") ?? "Skip")
    let eliminate = form.check("Eliminate duplicate root folder")
    let pass = form.field("Password",password,secure:true)
    form.passwordVisibility([pass])
    let selection = form.check("Extract selected entries only (\(selected.count))",!selected.isEmpty); selection.isEnabled = !selected.isEmpty
    form.note("Every entry and destination is checked before extraction. Overwrite replaces destination files; rename policies preserve both versions.")
    guard form.run(), !dest.stringValue.isEmpty else { return nil }
    var destination = URL(fileURLWithPath:(dest.stringValue as NSString).expandingTildeInPath)
    if separate.state == .on { destination.appendPathComponent(archive.deletingPathExtension().lastPathComponent,isDirectory:true) }
    var options = ExtractionOptions(destination:destination)
    options.remapAbsolutePaths = remap.state == .on
    options.fullPaths = paths.indexOfSelectedItem == 0; options.overwrite = [.skip,.overwrite,.renameExtracted,.renameExisting,.ask][collision.indexOfSelectedItem]
    options.eliminateDuplicateRoot = eliminate.state == .on; options.password = pass.stringValue; options.selectedPaths = selection.state == .on ? selected : []
    if options.overwrite == .overwrite && !confirm("Overwrite existing files?","Files at the destination with the same names will be replaced.",destructive:true) { return nil }
    defaults.set(separate.state == .on,forKey:"separateExtractFolder"); defaults.set(options.remapAbsolutePaths,forKey:"remapAbsolutePaths")
    defaults.set(!options.fullPaths,forKey:"flatExtract"); defaults.set(collision.selectedValue,forKey:"overwriteLabel")
    return options
}

final class ProgressController: NSWindowController, NSWindowDelegate {
    let control = OperationControl()
    let progress = NSProgressIndicator()
    let status = NSTextField(labelWithString:L("Preparing…"))
    let log = NSTextView()
    let timing = NSTextField(labelWithString: "")
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var finishedAt: TimeInterval?
    private var lastFraction: Double = 0
    private var segmentStart: TimeInterval = 0
    private var timingTimer: Timer?
    let pauseButton = NSButton(title:L("Pause"),target:nil,action:nil)
    let cancelButton = NSButton(title:L("Cancel"),target:nil,action:nil)
    var paused = false
    var running = true
    var cancellationRequested = false
    var displayBuffer = ConsoleDisplayBuffer()
    var progressTail = ""
    var onFinished: (() -> Void)?
    init(title: String) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:430),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = L(title); window.minSize = NSSize(width:500,height:300)
        super.init(window:window); window.delegate = self
        progress.isIndeterminate = true; progress.style = .bar; progress.startAnimation(nil)
        log.isEditable = false; log.isSelectable = true; log.font = .monospacedSystemFont(ofSize:11,weight:.regular); log.textContainerInset = NSSize(width:8,height:8)
        let scroll = NSScrollView(); scroll.documentView = log; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        pauseButton.target = self; pauseButton.action = #selector(togglePause); cancelButton.target = self; cancelButton.action = #selector(cancel)
        let buttons = NSStackView(views:[pauseButton,cancelButton]); buttons.orientation = .horizontal
        timing.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); timing.textColor = .secondaryLabelColor
        let stack = NSStackView(views:[status,progress,timing,scroll,buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),progress.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220)])
        window.center()
        timingTimer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in self?.updateTiming() }
        if let timingTimer { RunLoop.main.add(timingTimer,forMode:.common) }; updateTiming()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timingTimer?.invalidate() }
    private var activeElapsed: TimeInterval {
        max(0,(finishedAt ?? pausedAt ?? ProcessInfo.processInfo.systemUptime) - startedAt - pausedDuration)
    }
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite,seconds >= 0 else { return "—" }
        let total = Int(min(seconds,Double(Int.max - 1)))
        return String(format:"%02d:%02d:%02d",total / 3600,(total % 3600) / 60,total % 60)
    }
    private func recordProgress(_ value: Double) {
        let clamped = min(1,max(0,value))
        if clamped < lastFraction { segmentStart = activeElapsed }
        lastFraction = clamped; updateTiming()
    }
    private func updateTiming() {
        let elapsed = activeElapsed
        let elapsedText = LF("Elapsed: %@",Self.durationText(elapsed))
        guard running else { timing.stringValue = elapsedText; return }
        let estimate = lastFraction > 0 && lastFraction < 1 ? Self.durationText(max(0,elapsed - segmentStart) * (1 - lastFraction) / lastFraction) : lastFraction >= 1 ? "00:00:00" : "—"
        timing.stringValue = elapsedText + " · " + LF("Estimated remaining: %@",estimate)
    }
    func append(_ text: String) {
        guard !text.isEmpty else { return }
        let progressText = progressTail + text
        if let regex = try? NSRegularExpression(pattern:"(\\d{1,3})%"), let match = regex.matches(in:progressText,range:NSRange(progressText.startIndex...,in:progressText)).last, let range = Range(match.range(at:1),in:progressText), let value = Double(progressText[range]), value <= 100 {
            progress.isIndeterminate = false; progress.doubleValue = value; recordProgress(value / 100); if !paused { status.stringValue = "\(Int(value))%" }
        }
        progressTail = String(progressText.suffix(12))
        appendDisplay(displayBuffer.consume(text))
    }
    func appendDisplay(_ text: String) {
        guard !text.isEmpty else { return }
        log.textStorage?.append(NSAttributedString(string:text))
        if let storage = log.textStorage, storage.length > 2_000_000 { storage.deleteCharacters(in:NSRange(location:0,length:storage.length - 1_500_000)) }
        log.scrollToEndOfDocument(nil)
    }
    func fraction(_ value: Double) { let normalized = min(1,max(0,value)); progress.isIndeterminate = false; progress.doubleValue = normalized * 100; recordProgress(normalized); status.stringValue = "\(Int(normalized * 100))%" }
    func finish(_ result: CommandResult) { finish(message:result.warning ? "Completed with warnings — review the log" : "Completed successfully",error:result.warning) }
    func finish(message: String, error: Bool = false) {
        appendDisplay(displayBuffer.finishLine()); running = false; progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = error ? progress.doubleValue : 100
        finishedAt = pausedAt ?? ProcessInfo.processInfo.systemUptime; timingTimer?.invalidate(); timingTimer = nil; updateTiming()
        status.stringValue = L(message); status.textColor = error ? .systemOrange : .systemGreen
        pauseButton.isEnabled = false; cancelButton.isEnabled = true; cancelButton.title = L("Close"); onFinished?()
    }
    @objc func togglePause() {
        paused.toggle()
        if paused { pausedAt = ProcessInfo.processInfo.systemUptime; control.pause() }
        else { if let pausedAt { pausedDuration += ProcessInfo.processInfo.systemUptime - pausedAt }; pausedAt = nil; control.resume() }
        pauseButton.title = L(paused ? "Resume" : "Pause"); status.stringValue = L(paused ? "Paused" : "Running…"); updateTiming()
    }
    func requestCancel() { cancellationRequested = true; control.cancel(); status.stringValue = L("Cancelling…"); pauseButton.isEnabled = false; cancelButton.isEnabled = false }
    @objc func cancel() { if running { requestCancel() } else { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if running { if confirm("Cancel operation?","The operation will stop and its own partial files will be cleaned up where possible.") { requestCancel(); return true }; return false }
        return true
    }
}

final class PathChooser: NSObject {
    weak var field: NSTextField?
    let directory: Bool
    init(field: NSTextField, directory: Bool) { self.field = field; self.directory = directory }
    @objc func choose() {
        guard let field else { return }
        let current = URL(fileURLWithPath:(field.stringValue as NSString).expandingTildeInPath)
        let selected = directory ? chooseDirectory("Choose Destination",initial:current) : saveURL("Choose Archive",name:current.lastPathComponent,initial:current.deletingLastPathComponent())
        if let selected { field.stringValue = selected.path }
    }
}

final class CompressionFormatController: NSObject {
    let format: NSPopUpButton, method: NSPopUpButton, solid: NSPopUpButton, encryption: NSPopUpButton
    let headers: NSButton
    let symbolic: NSButton, hard: NSButton
    let timestamps: [NSPopUpButton]
    let precision: NSPopUpButton
    let memory: NSTextField
    let password: NSTextField, repeatPassword: NSTextField, dictionary: NSTextField, word: NSTextField, path: NSTextField
    var previousFormat: String
    init(format: NSPopUpButton, method: NSPopUpButton, solid: NSPopUpButton, headers: NSButton, encryption: NSPopUpButton, password: NSTextField, repeatPassword: NSTextField, dictionary: NSTextField, word: NSTextField, path: NSTextField, symbolic: NSButton, hard: NSButton, timestamps: [NSPopUpButton], precision: NSPopUpButton, memory: NSTextField) {
        self.format = format; self.method = method; self.solid = solid; self.headers = headers; self.encryption = encryption; self.password = password; self.repeatPassword = repeatPassword; self.dictionary = dictionary; self.word = word; self.path = path; self.symbolic = symbolic; self.hard = hard; self.timestamps = timestamps; self.precision = precision; self.memory = memory
        previousFormat = format.selectedValue ?? "7z"
    }
    @objc func update() {
        let selected = format.selectedValue ?? "7z"
        let currentMethod = method.selectedValue
        let choices: [String]
        switch selected {
        case "7z": choices = ["Automatic","LZMA2","LZMA","PPMd","BZip2","Deflate","Copy"]
        case "zip": choices = ["Automatic","Deflate","Deflate64","BZip2","LZMA","PPMd","Copy"]
        case "gzip": choices = ["Automatic","Deflate"]
        case "bzip2": choices = ["Automatic","BZip2"]
        case "xz": choices = ["Automatic","LZMA2"]
        case "tar": choices = ["Automatic","gnu","pax"]
        default: choices = ["Automatic"]
        }
        method.removeAllItems(); method.addItems(withTitles:choices.map(L)); for (item,value) in zip(method.itemArray,choices) { item.representedObject = value }; if let currentMethod,let index = choices.firstIndex(of:currentMethod) { method.selectItem(at:index) }
        memory.isEnabled = ArchiveCommands.supportsMemoryLimit(format:selected)
        let currentPrecision = precision.selectedValue.flatMap(Int.init) ?? -1
        let available = ArchiveCommands.timePrecisions(format:selected,method:method.selectedValue ?? "")
        precision.removeAllItems()
        let labels: [ArchiveTimePrecision:String] = [.automatic:"Automatic",.windows100ns:"Windows 100 ns",.unixSeconds:"Unix seconds",.dosTwoSeconds:"DOS 2 seconds",.nanoseconds:"Nanoseconds",.seconds:"Seconds",.milliseconds:"Milliseconds",.microseconds:"Microseconds",.hundredNanoseconds:"100 nanoseconds",.exactNanoseconds:"Exact nanoseconds"]
        for value in available { precision.addItem(withTitle:L(labels[value]!)); precision.lastItem?.representedObject = String(value.rawValue) }
        precision.selectItem(at:available.firstIndex { $0.rawValue == currentPrecision } ?? 0)
        let chosen = available[precision.indexOfSelectedItem]
        for (kind,timestamp) in zip(["m","c","a"],timestamps) { timestamp.isEnabled = ArchiveCommands.supportsTimestamp(kind,format:selected,method:method.selectedValue ?? "",precision:chosen); if !timestamp.isEnabled { timestamp.selectItem(at:0) } }
        let linkFormats = ArchiveCommands.symbolicLinkFormats
        symbolic.isEnabled = linkFormats.contains(selected); hard.isEnabled = ArchiveCommands.hardLinkFormats.contains(selected)
        if !symbolic.isEnabled { symbolic.state = .off } else if !linkFormats.contains(previousFormat) { symbolic.state = .on }
        if !hard.isEnabled { hard.state = .off }
        solid.isEnabled = selected == "7z"; headers.isEnabled = selected == "7z"
        if !headers.isEnabled { headers.state = .off }
        let encrypted = selected == "7z" || selected == "zip"
        password.isEnabled = encrypted; repeatPassword.isEnabled = encrypted; encryption.isEnabled = selected == "zip"
        if !encrypted { password.stringValue = ""; repeatPassword.stringValue = "" }
        dictionary.isEnabled = ["7z","zip","xz","bzip2"].contains(selected); word.isEnabled = ["7z","zip","gzip"].contains(selected)
        if !dictionary.isEnabled { dictionary.stringValue = "" }; if !word.isEnabled { word.stringValue = "" }
        if previousFormat != selected {
            let current = URL(fileURLWithPath:path.stringValue)
            if current.pathExtension == previousFormat { path.stringValue = current.deletingPathExtension().appendingPathExtension(selected).path }
        }
        previousFormat = selected
    }
}

extension NSPopUpButton { var selectedValue: String? { (selectedItem?.representedObject as? String) ?? titleOfSelectedItem } }

final class PasswordVisibility: NSObject {
    let fields: [NSTextField]
    init(fields: [NSTextField]) { self.fields = fields }
    @objc func toggle(_ button: NSButton) {
        for field in fields {
            let value = field.stringValue; let font = field.font
            field.cell = button.state == .on ? NSTextFieldCell(textCell:value) : NSSecureTextFieldCell(textCell:value)
            field.stringValue = value; field.font = font; field.isEditable = true; field.isSelectable = true; field.isBezeled = true; field.drawsBackground = true
        }
    }
}


final class ExtractorOptionController: NSObject, NSTextFieldDelegate {
    let volume: NSTextField
    let option: NSButton
    init(volume: NSTextField, option: NSButton) { self.volume = volume; self.option = option }
    func controlTextDidChange(_ notification: Notification) { update() }
    func update() {
        option.isEnabled = Bundle.main.bundleURL.pathExtension == "app" && volume.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        if !option.isEnabled { option.state = .off }
    }
}

private final class FlippedFormView: NSView { override var isFlipped: Bool { true } }
