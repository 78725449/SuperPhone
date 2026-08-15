//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016, 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

import CoreFoundation
import Darwin
import Foundation

@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ persona_id: uid_t,
    _ flags: UInt32
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ persona_id: uid_t
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ persona_id: uid_t
) -> Int32

private let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = UInt32(1)

public extension TaskProcess {
    @objc(TRTaskTerminationReason)
    enum TerminationReason: Int {
        case exit
        case uncaughtSignal
    }

    @objc(TRQualityOfService)
    enum QualityOfService: Int {
        case userInteractive
        case userInitiated
        case utility
        case background
        case `default`
    }
}

private extension NSObject {
    static func unretainedReference<R: NSObject>(_ value: UnsafeRawPointer) -> R {
        unsafeBitCast(value, to: R.self)
    }

    static func unretainedReference<R: NSObject>(_ value: UnsafeMutableRawPointer) -> R {
        unretainedReference(UnsafeRawPointer(value))
    }

    func withRetainedReference<T, R>(_ work: (UnsafePointer<T>) -> R) -> R {
        let selfPtr = Unmanaged.passRetained(self).toOpaque().assumingMemoryBound(to: T.self)
        return work(selfPtr)
    }

    func withRetainedReference<T, R>(_ work: (UnsafeMutablePointer<T>) -> R) -> R {
        let selfPtr = Unmanaged.passRetained(self).toOpaque().assumingMemoryBound(to: T.self)
        return work(selfPtr)
    }

    func withUnretainedReference<T, R>(_ work: (UnsafePointer<T>) -> R) -> R {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque().assumingMemoryBound(to: T.self)
        return work(selfPtr)
    }

    func withUnretainedReference<T, R>(_ work: (UnsafeMutablePointer<T>) -> R) -> R {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque().assumingMemoryBound(to: T.self)
        return work(selfPtr)
    }
}

private func _NSErrorWithErrno(_ posixErrno: Int32, reading: Bool, path: String? = nil, url: URL? = nil, extraUserInfo: [String: Any]? = nil) -> NSError {
    let cocoaError: CocoaError.Code = if reading {
        switch posixErrno {
        case EFBIG: .fileReadTooLarge
        case ENOENT: .fileReadNoSuchFile
        case EPERM, EACCES: .fileReadNoPermission
        case ENAMETOOLONG: .fileReadUnknown
        default: .fileReadUnknown
        }
    } else {
        switch posixErrno {
        case ENOENT: .fileNoSuchFile
        case EPERM, EACCES: .fileWriteNoPermission
        case ENAMETOOLONG: .fileWriteInvalidFileName
        case EDQUOT, ENOSPC: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        case EEXIST: .fileWriteFileExists
        default: .fileWriteUnknown
        }
    }

    var userInfo = extraUserInfo ?? [String: Any]()
    if let path {
        userInfo[NSFilePathErrorKey] = path as NSString
    } else if let url {
        userInfo[NSURLErrorKey] = url
    }

    userInfo[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(posixErrno))

    return NSError(domain: NSCocoaErrorDomain, code: cocoaError.rawValue, userInfo: userInfo)
}

private extension FileManager {
    func __fileSystemRepresentation(withPath path: String) throws -> UnsafePointer<UInt8> {
        let len = CFStringGetMaximumSizeOfFileSystemRepresentation(path as CFString)
        if len != kCFNotFound {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: len)
            buf.initialize(repeating: 0, count: len)
            if (path as NSString).getFileSystemRepresentation(buf, maxLength: len) {
                return UnsafePointer(buf)
            }
            buf.deinitialize(count: len)
            buf.deallocate()
        }
        throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadInvalidFileName.rawValue, userInfo: [NSFilePathErrorKey: path])
    }

    func _fileSystemRepresentation<ResultType>(withPath path: String, _ body: (UnsafePointer<UInt8>) throws -> ResultType) throws -> ResultType {
        let fsRep = try __fileSystemRepresentation(withPath: path)
        defer { fsRep.deallocate() }
        return try body(fsRep)
    }

    func _fileSystemRepresentation<ResultType>(withPath path1: String, andPath path2: String, _ body: (UnsafePointer<UInt8>, UnsafePointer<UInt8>) throws -> ResultType) throws -> ResultType {
        let fsRep1 = try __fileSystemRepresentation(withPath: path1)
        defer { fsRep1.deallocate() }
        let fsRep2 = try __fileSystemRepresentation(withPath: path2)
        defer { fsRep2.deallocate() }

        return try body(fsRep1, fsRep2)
    }
}

private func WIFEXITED(_ status: Int32) -> Bool {
    _WSTATUS(status) == 0
}

private func _WSTATUS(_ status: Int32) -> Int32 {
    status & 0x7F
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    (_WSTATUS(status) != 0) && (_WSTATUS(status) != 0x7F)
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    (status >> 8) & 0xFF
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    status & 0x7F
}

private var managerThreadRunLoop: RunLoop?
private var managerThreadRunLoopIsRunning = false
private var managerThreadRunLoopIsRunningCondition = NSCondition()

let kCFSocketNoCallBack: CFOptionFlags = 0 // .noCallBack cannot be used because empty option flags are imported as unavailable.
let kCFSocketAcceptCallBack = CFSocketCallBackType.acceptCallBack.rawValue
let kCFSocketDataCallBack = CFSocketCallBackType.dataCallBack.rawValue

let kCFSocketSuccess = CFSocketError.success
let kCFSocketError = CFSocketError.error
let kCFSocketTimeout = CFSocketError.timeout

extension CFSocketError {
    init?(_ value: CFIndex) {
        self.init(rawValue: value)
    }
}

private func emptyRunLoopCallback(_: UnsafeMutableRawPointer?) {}

// Retain method for run loop source
private func runLoopSourceRetain(_ pointer: UnsafeRawPointer?) -> UnsafeRawPointer? {
    let ref = Unmanaged<AnyObject>.fromOpaque(pointer!).takeUnretainedValue()
    let retained = Unmanaged<AnyObject>.passRetained(ref)
    return unsafeBitCast(retained, to: UnsafeRawPointer.self)
}

// Release method for run loop source
private func runLoopSourceRelease(_ pointer: UnsafeRawPointer?) {
    Unmanaged<AnyObject>.fromOpaque(pointer!).release()
}

// Equal method for run loop source

private func runloopIsEqual(_ a: UnsafeRawPointer?, _: UnsafeRawPointer?) -> DarwinBoolean {
    let unmanagedrunLoopA = Unmanaged<AnyObject>.fromOpaque(a!)
    guard let runLoopA = unmanagedrunLoopA.takeUnretainedValue() as? RunLoop else {
        return false
    }

    let unmanagedRunLoopB = Unmanaged<AnyObject>.fromOpaque(a!)
    guard let runLoopB = unmanagedRunLoopB.takeUnretainedValue() as? RunLoop else {
        return false
    }

    guard runLoopA == runLoopB else {
        return false
    }

    return true
}

// Equal method for process in run loop source
private func processIsEqual(_ a: UnsafeRawPointer?, _: UnsafeRawPointer?) -> DarwinBoolean {
    let unmanagedProcessA = Unmanaged<AnyObject>.fromOpaque(a!)
    guard let processA = unmanagedProcessA.takeUnretainedValue() as? TaskProcess else {
        return false
    }

    let unmanagedProcessB = Unmanaged<AnyObject>.fromOpaque(a!)
    guard let processB = unmanagedProcessB.takeUnretainedValue() as? TaskProcess else {
        return false
    }

    guard processA == processB else {
        return false
    }

    return true
}

@objc(TRTask)
open class TaskProcess: NSObject {
    private static func setup() {
        lazy var executeOnce: Void = {
            let thread = Thread {
                managerThreadRunLoop = RunLoop.current
                var emptySourceContext = CFRunLoopSourceContext()
                emptySourceContext.version = 0
                emptySourceContext.retain = runLoopSourceRetain
                emptySourceContext.release = runLoopSourceRelease
                emptySourceContext.equal = runloopIsEqual
                emptySourceContext.perform = emptyRunLoopCallback
                managerThreadRunLoop!.withUnretainedReference {
                    (refPtr: UnsafeMutablePointer<UInt8>) in
                    emptySourceContext.info = UnsafeMutableRawPointer(refPtr)
                }

                CFRunLoopAddSource(managerThreadRunLoop?.getCFRunLoop(), CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &emptySourceContext), CFRunLoopMode.defaultMode)

                managerThreadRunLoopIsRunningCondition.lock()

                CFRunLoopPerformBlock(managerThreadRunLoop?.getCFRunLoop(), RunLoop.Mode.default as CFTypeRef) {
                    managerThreadRunLoopIsRunning = true
                    managerThreadRunLoopIsRunningCondition.broadcast()
                    managerThreadRunLoopIsRunningCondition.unlock()
                }

                managerThreadRunLoop?.run()
                fatalError("TaskProcess manager run loop exited unexpectedly; it should run forever once initialized")
            }
            thread.start()
            managerThreadRunLoopIsRunningCondition.lock()
            while managerThreadRunLoopIsRunning == false {
                managerThreadRunLoopIsRunningCondition.wait()
            }
            managerThreadRunLoopIsRunningCondition.unlock()
        }()
        _ = executeOnce
    }

    // Create an TaskProcess which can be run at a later time
    // An TaskProcess can only be run once. Subsequent attempts to
    // run an TaskProcess will raise.
    // Upon process death a notification will be sent
    //   { Name = TaskProcess.didTerminateNotification; object = TaskProcess; }
    //

    @objc override public init() {}

    // These properties can only be set before a launch.
    private var _executable: URL?
    @objc open var executableURL: URL? {
        get { _executable }
        set {
            guard let url = newValue, url.isFileURL else {
                fatalError("must provide a launch path")
            }
            _executable = url
        }
    }

    private var _currentDirectoryPath = FileManager.default.currentDirectoryPath
    @objc open var currentDirectoryURL: URL? {
        get { _currentDirectoryPath == "" ? nil : URL(fileURLWithPath: _currentDirectoryPath, isDirectory: true) }
        set {
            // Setting currentDirectoryURL to nil resets to the current directory
            if let url = newValue {
                guard url.isFileURL else { fatalError("non-file URL argument") }
                _currentDirectoryPath = url.path
            } else {
                _currentDirectoryPath = FileManager.default.currentDirectoryPath
            }
        }
    }

    private var _userIdentifier: uid_t = getuid()
    @objc open var userIdentifier: uid_t {
        get { _userIdentifier }
        set { _userIdentifier = newValue }
    }

    private var _groupIdentifier: gid_t = getgid()
    @objc open var groupIdentifier: gid_t {
        get { _groupIdentifier }
        set { _groupIdentifier = newValue }
    }

    private var _processGroupIdentifier: pid_t = 0
    @objc open var processGroupIdentifier: pid_t {
        get { _processGroupIdentifier }
        set { _processGroupIdentifier = newValue }
    }

    @objc open var arguments: [String]?
    @objc open var environment: [String: String]? // if not set, use current
    @objc open var userInfo: [AnyHashable: Any]?

    @available(*, deprecated, renamed: "executableURL")
    @objc open var launchPath: String? {
        get { executableURL?.path }
        set { executableURL = (newValue != nil) ? URL(fileURLWithPath: newValue!) : nil }
    }

    @available(*, deprecated, renamed: "currentDirectoryURL")
    @objc open var currentDirectoryPath: String {
        get { _currentDirectoryPath }
        set { _currentDirectoryPath = newValue }
    }

    // Standard I/O channels; could be either a FileHandle or a Pipe

    @objc open var standardInput: Any? = FileHandle.standardInput {
        willSet {
            precondition(newValue is Pipe || newValue is FileHandle || newValue == nil,
                         "standardInput must be either Pipe or FileHandle")
        }
    }

    @objc open var standardOutput: Any? = FileHandle.standardOutput {
        willSet {
            precondition(newValue is Pipe || newValue is FileHandle || newValue == nil,
                         "standardOutput must be either Pipe or FileHandle")
        }
    }

    @objc open var standardError: Any? = FileHandle.standardError {
        willSet {
            precondition(newValue is Pipe || newValue is FileHandle || newValue == nil,
                         "standardError must be either Pipe or FileHandle")
        }
    }

    private class NonexportedCFRunLoopSourceContextStorage {
        var value: CFRunLoopSourceContext?
    }

    private class NonexportedCFRunLoopSourceStorage {
        var value: CFRunLoopSource?
    }

    private var _runLoopSourceContextStorage = NonexportedCFRunLoopSourceContextStorage()
    private final var runLoopSourceContext: CFRunLoopSourceContext? {
        get { _runLoopSourceContextStorage.value }
        set { _runLoopSourceContextStorage.value = newValue }
    }

    private var _runLoopSourceStorage = NonexportedCFRunLoopSourceStorage()
    private final var runLoopSource: CFRunLoopSource? {
        get { _runLoopSourceStorage.value }
        set { _runLoopSourceStorage.value = newValue }
    }

    fileprivate weak var runLoop: RunLoop? = nil

    private var processLaunchedCondition = NSCondition()

    // Actions

    @available(*, deprecated, renamed: "run")
    @objc open func launch() {
        do {
            try run()
        } catch let nserror as NSError {
            if let path = nserror.userInfo[NSFilePathErrorKey] as? String, path == currentDirectoryPath {
                // Foundation throws an NSException when changing the working directory fails,
                // and unfortunately launch() is not marked `throws`, so we get away with a
                // fatalError.
                switch CocoaError.Code(rawValue: nserror.code) {
                case .fileReadNoSuchFile:
                    fatalError("TaskProcess: The specified working directory does not exist.")
                case .fileReadNoPermission:
                    fatalError("TaskProcess: The specified working directory cannot be accessed.")
                default:
                    fatalError("TaskProcess: The specified working directory cannot be set.")
                }
            } else {
                fatalError(String(describing: nserror))
            }
        } catch {
            fatalError(String(describing: error))
        }
    }

    @objc(launchAndReturnError:)
    open func run() throws {
        func _throwIfPosixError(_ posixErrno: Int32) throws {
            if posixErrno != 0 {
                // When this is called, self.executableURL is already known to be non-nil
                let userInfo: [String: Any] = [NSURLErrorKey: self.executableURL!]
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(posixErrno), userInfo: userInfo)
            }
        }

        self.processLaunchedCondition.lock()
        defer {
            self.processLaunchedCondition.broadcast()
            self.processLaunchedCondition.unlock()
        }

        // Dispatch the manager thread if it isn't already running
        TaskProcess.setup()

        // Check that the process isnt run more than once
        guard hasStarted == false && hasFinished == false else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSExecutableLoadError, userInfo: [
                NSLocalizedDescriptionKey: "The process is launched more than once.",
            ])
        }

        // Ensure that the launch path is set
        guard let launchPath = self.executableURL?.path else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
                NSLocalizedDescriptionKey: "The launch path is not set.",
            ])
        }

        // Initial checks that the launchPath points to an executable file. posix_spawn()
        // can return success even if executing the program fails, eg fork() works but execve()
        // fails, so try and check as much as possible beforehand.
        try FileManager.default._fileSystemRepresentation(withPath: launchPath) { fsRep in
            var statInfo = stat()
            guard stat(fsRep, &statInfo) == 0 else {
                throw _NSErrorWithErrno(errno, reading: true, path: launchPath)
            }

            let isRegularFile: Bool = statInfo.st_mode & S_IFMT == S_IFREG
            guard isRegularFile == true else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
                    NSLocalizedDescriptionKey: "The launch path does not exist.",
                ])
            }

            guard access(fsRep, X_OK) == 0 else {
                throw _NSErrorWithErrno(errno, reading: true, path: launchPath)
            }
        }
        // Convert the arguments array into a posix_spawn-friendly format

        var args = [launchPath]
        if let arguments = self.arguments {
            args.append(contentsOf: arguments)
        }

        let argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?> = args.withUnsafeBufferPointer {
            let array: UnsafeBufferPointer<String> = $0
            let buffer = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: array.count + 1)
            buffer.initialize(from: array.map { $0.withCString(strdup) }, count: array.count)
            buffer[array.count] = nil
            return buffer
        }

        defer {
            for arg in argv ..< argv + args.count {
                free(UnsafeMutableRawPointer(arg.pointee))
            }
            argv.deallocate()
        }

        let env: [String: String] = if let e = environment {
            e
        } else {
            ProcessInfo.processInfo.environment
        }

        let nenv = env.count
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: 1 + nenv)
        envp.initialize(from: env.map { strdup("\($0)=\($1)") }, count: nenv)
        envp[env.count] = nil

        defer {
            for pair in envp ..< envp + env.count {
                free(UnsafeMutableRawPointer(pair.pointee))
            }
            envp.deallocate()
        }

        var taskSocketPair: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &taskSocketPair)
        var context = CFSocketContext()
        context.version = 0
        context.retain = runLoopSourceRetain
        context.release = runLoopSourceRelease
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let socket = CFSocketCreateWithNative(nil, taskSocketPair[0], CFOptionFlags(kCFSocketDataCallBack), {
            socket, _, _, _, info in

            let process: TaskProcess = NSObject.unretainedReference(info!)

            process.processLaunchedCondition.lock()
            while process.isRunning == false {
                process.processLaunchedCondition.wait()
            }

            process.processLaunchedCondition.unlock()

            var exitCode: Int32 = 0
            var waitResult: Int32 = 0

            repeat {
                waitResult = waitpid(process.processIdentifier, &exitCode, 0)
            } while (waitResult == -1) && (errno == EINTR)

            if WIFSIGNALED(exitCode) {
                process._terminationStatus = WTERMSIG(exitCode)
                process._terminationReason = .uncaughtSignal
            } else {
                assert(WIFEXITED(exitCode))
                process._terminationStatus = WEXITSTATUS(exitCode)
                process._terminationReason = .exit
            }

            // Signal waitUntilExit() and optionally invoke termination handler.
            process.terminateRunLoop()

            CFSocketInvalidate(socket)

        }, &context)

        CFSocketSetSocketFlags(socket, CFOptionFlags(kCFSocketCloseOnInvalidate))

        let source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, socket, 0)
        CFRunLoopAddSource(managerThreadRunLoop?.getCFRunLoop(), source, CFRunLoopMode.defaultMode)

        var fileActions: posix_spawn_file_actions_t?
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        try _throwIfPosixError(posix_spawn_file_actions_init(&fileActions))

        // File descriptors to duplicate in the child process. This allows
        // output redirection to NSPipe or NSFileHandle.
        var adddup2 = [Int32: Int32]()

        // File descriptors to close in the child process. A set so that
        // shared pipes only get closed once. Would result in EBADF on OSX
        // otherwise.
        var addclose = Set<Int32>()

        var _devNull: FileHandle?
        func devNullFd() throws -> Int32 {
            _devNull = try _devNull ?? FileHandle(forUpdating: URL(fileURLWithPath: "/dev/null", isDirectory: false))
            return _devNull!.fileDescriptor
        }

        switch standardInput {
        case let pipe as Pipe:
            adddup2[STDIN_FILENO] = pipe.fileHandleForReading.fileDescriptor
            addclose.insert(pipe.fileHandleForWriting.fileDescriptor)

        // nil or NullDevice map to /dev/null
        case let handle as FileHandle where handle === FileHandle.nullDevice: fallthrough

        case .none:
            adddup2[STDIN_FILENO] = try devNullFd()

        // No need to dup stdin to stdin
        case let handle as FileHandle where handle === FileHandle.standardInput: break

        case let handle as FileHandle:
            adddup2[STDIN_FILENO] = handle.fileDescriptor

        default: break
        }

        switch standardOutput {
        case let pipe as Pipe:
            adddup2[STDOUT_FILENO] = pipe.fileHandleForWriting.fileDescriptor
            addclose.insert(pipe.fileHandleForReading.fileDescriptor)

        // nil or NullDevice map to /dev/null
        case let handle as FileHandle where handle === FileHandle.nullDevice: fallthrough

        case .none:
            adddup2[STDOUT_FILENO] = try devNullFd()

        // No need to dup stdout to stdout
        case let handle as FileHandle where handle === FileHandle.standardOutput: break

        case let handle as FileHandle:
            adddup2[STDOUT_FILENO] = handle.fileDescriptor

        default: break
        }

        switch standardError {
        case let pipe as Pipe:
            adddup2[STDERR_FILENO] = pipe.fileHandleForWriting.fileDescriptor
            addclose.insert(pipe.fileHandleForReading.fileDescriptor)

        // nil or NullDevice map to /dev/null
        case let handle as FileHandle where handle === FileHandle.nullDevice: fallthrough

        case .none:
            adddup2[STDERR_FILENO] = try devNullFd()

        // No need to dup stderr to stderr
        case let handle as FileHandle where handle === FileHandle.standardError: break

        case let handle as FileHandle:
            adddup2[STDERR_FILENO] = handle.fileDescriptor

        default: break
        }

        for (new, old) in adddup2 {
            try _throwIfPosixError(posix_spawn_file_actions_adddup2(&fileActions, old, new))
        }
        for fd in addclose.filter({ $0 >= 0 }) {
            try _throwIfPosixError(posix_spawn_file_actions_addclose(&fileActions, fd))
        }

        var spawnAttrs: posix_spawnattr_t? = nil
        try _throwIfPosixError(posix_spawnattr_init(&spawnAttrs))

        // Unmask all signals.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        try _throwIfPosixError(posix_spawnattr_setsigmask(&spawnAttrs, &noSignals))

        // Reset all signals to default behavior.
        var mostSignals = sigset_t()
        sigfillset(&mostSignals)
        sigdelset(&mostSignals, SIGKILL)
        sigdelset(&mostSignals, SIGSTOP)
        try _throwIfPosixError(posix_spawnattr_setsigdefault(&spawnAttrs, &mostSignals))

        // Establish a separate process group.
        try _throwIfPosixError(posix_spawnattr_setpgroup(&spawnAttrs, processGroupIdentifier))

        // Set appropriate flags for the attributes above.
        var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        flags |= POSIX_SPAWN_SETPGROUP
        try _throwIfPosixError(posix_spawnattr_setflags(&spawnAttrs, Int16(flags)))

        // Set the persona for the spawned process.
        let changeUser = userIdentifier != getuid()
        let changeGroup = groupIdentifier != getgid()
        if changeUser || changeGroup {
            try _throwIfPosixError(posix_spawnattr_set_persona_np(&spawnAttrs, 99, UInt32(POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)))
            if changeUser {
                try _throwIfPosixError(posix_spawnattr_set_persona_uid_np(&spawnAttrs, userIdentifier))
            }
            if changeGroup {
                try _throwIfPosixError(posix_spawnattr_set_persona_gid_np(&spawnAttrs, groupIdentifier))
            }
        }

        let fileManager = FileManager()
        let previousDirectoryPath = fileManager.currentDirectoryPath
        if let dir = currentDirectoryURL?.path, !fileManager.changeCurrentDirectoryPath(dir) {
            throw _NSErrorWithErrno(errno, reading: true, url: currentDirectoryURL)
        }

        defer {
            // Reset the previous working directory path.
            fileManager.changeCurrentDirectoryPath(previousDirectoryPath)
        }

        // Launch
        var pid = pid_t()
        guard posix_spawn(&pid, launchPath, &fileActions, &spawnAttrs, argv, envp) == 0 else {
            throw _NSErrorWithErrno(errno, reading: true, path: launchPath)
        }
        posix_spawnattr_destroy(&spawnAttrs)

        // Close the write end of the input and output pipes.
        if let pipe = standardInput as? Pipe {
            pipe.fileHandleForReading.closeFile()
        }
        if let pipe = standardOutput as? Pipe {
            pipe.fileHandleForWriting.closeFile()
        }
        if let pipe = standardError as? Pipe {
            pipe.fileHandleForWriting.closeFile()
        }

        close(taskSocketPair[1])

        self.runLoop = RunLoop.current
        self.runLoopSourceContext = CFRunLoopSourceContext(version: 0,
                                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                                           retain: { runLoopSourceRetain($0) },
                                                           release: { runLoopSourceRelease($0) },
                                                           copyDescription: nil,
                                                           equal: { processIsEqual($0, $1) },
                                                           hash: nil,
                                                           schedule: nil,
                                                           cancel: nil,
                                                           perform: { emptyRunLoopCallback($0) })
        self.runLoopSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &runLoopSourceContext!)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.defaultMode)

        isRunning = true

        self.processIdentifier = pid
    }

    @objc open func interrupt() {
        precondition(hasStarted, "task not launched")
        kill(processIdentifier, SIGINT)
    }

    @objc open func terminate() {
        precondition(hasStarted, "task not launched")
        kill(processIdentifier, SIGTERM)
    }

    // Every suspend() has to be balanced with a resume() so keep a count of both.
    private var suspendCount = 0

    @objc open func suspend() -> Bool {
        if kill(processIdentifier, SIGSTOP) == 0 {
            suspendCount += 1
            return true
        } else {
            return false
        }
    }

    @objc open func resume() -> Bool {
        var success = true
        if suspendCount == 1 {
            success = kill(processIdentifier, SIGCONT) == 0
        }
        if success {
            suspendCount -= 1
        }
        return success
    }

    // status
    @objc open private(set) var processIdentifier: Int32 = 0
    @objc open private(set) var isRunning: Bool = false
    private var hasStarted: Bool { processIdentifier > 0 }
    private var hasFinished: Bool { !isRunning && processIdentifier > 0 }

    private var _terminationStatus: Int32 = 0
    @objc public var terminationStatus: Int32 {
        precondition(hasStarted, "task not launched")
        precondition(hasFinished, "task still running")
        return _terminationStatus
    }

    private var _terminationReason: TerminationReason = .exit
    @objc public var terminationReason: TerminationReason {
        precondition(hasStarted, "task not launched")
        precondition(hasFinished, "task still running")
        return _terminationReason
    }

    /**
     * A block to be invoked when the process underlying the TaskProcess terminates.  Setting the block to nil is valid, and stops the previous block from being invoked, as long as it hasn't started in any way.  The TaskProcess is passed as the argument to the block so the block does not have to capture, and thus retain, it.  The block is copied when set.  Only one termination handler block can be set at any time.  The execution context in which the block is invoked is undefined.  If the TaskProcess has already finished, the block is executed immediately/soon (not necessarily on the current thread).  If a terminationHandler is set on an TaskProcess, the TRTaskDidTerminateNotification notification is not posted for that process.  Also note that -waitUntilExit won't wait until the terminationHandler has been fully executed.  You cannot use this property in a concrete subclass of TaskProcess which hasn't been updated to include an implementation of the storage and use of it.
     */
    @objc open var terminationHandler: ((TaskProcess) -> Void)?
    @objc open var qualityOfService: QualityOfService = .default // read-only after the process is launched

    @objc(launchedTaskWithExecutableURL:arguments:error:terminationHandler:)
    open class func run(_ url: URL, arguments: [String], terminationHandler: ((TaskProcess) -> Void)? = nil) throws -> TaskProcess {
        let process = TaskProcess()
        process.executableURL = url
        process.arguments = arguments
        process.terminationHandler = terminationHandler
        try process.run()
        return process
    }

    @available(*, deprecated, renamed: "run(_:arguments:terminationHandler:)")
    // convenience; create and launch
    @objc(launchedTaskWithLaunchPath:arguments:)
    open class func launchedProcess(launchPath path: String, arguments: [String]) -> TaskProcess {
        let process = TaskProcess()
        process.launchPath = path
        process.arguments = arguments
        process.launch()

        return process
    }

    // poll the runLoop in defaultMode until process completes
    @objc open func waitUntilExit() {
        let runInterval = 0.05
        let currentRunLoop = RunLoop.current

        let runRunLoop: () -> Void = (currentRunLoop == self.runLoop)
            ? { currentRunLoop.run(mode: .default, before: Date(timeIntervalSinceNow: runInterval)) }
            : { currentRunLoop.run(until: Date(timeIntervalSinceNow: runInterval)) }
        // update .runLoop to allow early wakeup triggered by terminateRunLoop.
        self.runLoop = currentRunLoop

        while self.isRunning {
            runRunLoop()
        }

        self.runLoop = nil
        self.runLoopSource = nil
    }

    private func terminateRunLoop() {
        // Ensure that the run loop source is invalidated before we mark the process
        // as no longer running.  This serves as a semaphore to
        // `waitUntilExit` to decrement the `runLoopSource` retain count,
        // potentially releasing it.
        CFRunLoopSourceInvalidate(self.runLoopSource)
        let runloopToWakeup = self.runLoop
        self.isRunning = false

        // Wake up the run loop, *AFTER* clearing .isRunning to avoid an extra time out period.
        if let cfRunLoop = runloopToWakeup?.getCFRunLoop() {
            CFRunLoopWakeUp(cfRunLoop)
        }

        if let handler = self.terminationHandler {
            let thread = Thread { handler(self) }
            thread.start()
        } else {
            let thread = Thread { NotificationCenter.default.post(name: TaskProcess.didTerminateNotification, object: self) }
            thread.start()
        }
    }
}

public extension TaskProcess {
    @objc static let didTerminateNotification = NSNotification.Name(rawValue: "TRTaskDidTerminateNotification")
}
