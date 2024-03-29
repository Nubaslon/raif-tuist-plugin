//
//  ContentViewModel.swift
//  
//
//  Created by ANTROPOV Evgeny on 26.05.2022.
//

import Foundation
import RunShell
import AppKit

class ContentViewModel: ObservableObject {
    enum CheckoutType {
        case version(String)
        case master
    }
    @Published var buildType = UserDefaults.standard.integer(forKey: "buildType") {
        didSet {
            UserDefaults.standard.set(buildType, forKey: "buildType")
        }
    }
    @Published var allPods: [PodDependecy]
    @Published var isGenerating = false
    @Published var enteredLogin = ""
    @Published var enteredPassword = ""
    @Published var credentionals: (login: String, password: String)?
    
    var initialPods: [PodDependecy]
    var dependecyRawList: String
    
    init() {
        do {
            let pwd = FileManager.default.currentDirectoryPath
            dependecyRawList = try String(contentsOf: URL(fileURLWithPath: pwd + "/PodDeps/dependecy.rb"), encoding: .utf8)
            
            
            let nameRange = NSRange(
                dependecyRawList.startIndex..<dependecyRawList.endIndex,
                in: dependecyRawList
            )
            
            // Create A NSRegularExpression
            let capturePattern = #"pod_constructor :name => '([a-zA-Z0-9\.\/]*)',((?!pod_constructor).)*:dev_pod => (false|true)"#
            let captureRegex = try! NSRegularExpression(
                pattern: capturePattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            
            // Find the matching capture groups
            let matches = captureRegex.matches(
                in: dependecyRawList,
                options: [],
                range: nameRange
            )
            
            guard matches.count != 0 else {
                // Handle exception
                throw "Failed to parse dependecy.rb"
            }
            
            var dependecies: [PodDependecy] = []
            for match in matches {
                let rawIndex = Range(match.range(at: 0), in: dependecyRawList)!
                let raw = dependecyRawList[rawIndex]
                let name = dependecyRawList[Range(match.range(at: 1), in: dependecyRawList)!]
                dependecies.append(
                    PodDependecy(
                        name: String(name),
                        rawData: raw.components(separatedBy: "\n"),
                        startLine: dependecyRawList.distance(from: dependecyRawList.startIndex, to: rawIndex.lowerBound),
                        endLine: dependecyRawList.distance(from: dependecyRawList.startIndex, to: rawIndex.upperBound)
                    )
                )
            }
            allPods = dependecies.sorted(by: {$0.name < $1.name })
            initialPods = dependecies.sorted(by: {$0.name < $1.name })
            credentionals = try? getSavedCredentionals()
        }
        catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func generatePod() {
        NSApplication.shared.hide(nil)
        isGenerating = true
        let toUpdatePods = Array(Set(allPods).subtracting(Set(initialPods))).sorted(by: {$0.startLine > $1.startLine})
        var updatedPods = dependecyRawList
        for pod in toUpdatePods {
            updatedPods = updatedPods.replacingCharacters(in: updatedPods.index(updatedPods.startIndex, offsetBy: pod.startLine) ..< updatedPods.index(updatedPods.startIndex, offsetBy: pod.endLine), with: pod.generatedData)
        }
        let pwd = FileManager.default.currentDirectoryPath
        try! updatedPods.write(to: URL(fileURLWithPath: pwd + "/PodDeps/dependecy.rb"), atomically: true, encoding: .utf8)
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let flagshipVersion = self.allPods.first(where: { $0.name == "Flagship" })?.version ?? "0.0"
                let scriptsFlagshipVersion = ((try? shell("cat scripts/generator.version")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if flagshipVersion != scriptsFlagshipVersion {
                    try? shell("rm ./scripts/generator")
                    try? shell("rm ./scripts/generator.version")
                    // TODO: Выпилить, брать нужные файлы из пода или поставлять с монолитом, то есть положить в гит.
                    try? shell("git clone https://${FLAGSHIP_GITLAB_API_NAME}:${FLAGSHIP_GITLAB_API_TOKEN}@gitlabci.raiffeisen.ru/mobile_development/ios-kit/ios-flagship.git")
                    try? shell("cp ./ios-flagship/Sources/generator scripts")
                    try? shell("cd ios-flagship && git describe --tags --abbrev=0 > ../scripts/generator.version")
                    try? shell("rm -rf ios-flagship")
                }
                try shell("rm -Rf _Prebuild")
                try shell("rm -Rf _Prebuild_delta")
                try shell("rm -Rf Pods")
                try? shell("rm -Rf ~/Library/Developer/Xcode/DerivedData/*")
                if (try? shell("bundle check")) == nil {
                    try shell("bundle install")
                }
                try shell("./scripts/generator -e _Prebuild")
                try shell("tuist generate -n")
                switch(self.buildType){
                case 0:
                    guard let credentionals = self.credentionals,!credentionals.login.isEmpty && !credentionals.password.isEmpty else { fatalError() }
                    print("Run Command: ARTIFACTORY_LOGIN=\(credentionals.login) ARTIFACTORY_PASSWORD=\(credentionals.password.map({_ in "*"}).joined(separator: "")) bundle exec pod binary fetch --repo-update")
                    try shell("ARTIFACTORY_LOGIN=\(credentionals.login) ARTIFACTORY_PASSWORD=\(credentionals.password) bundle exec pod binary fetch --repo-update", print: false)
                    try shell("bundle exec pod install")
                case 1:
                    try shell("TYPE=TEST bundle exec pod install --repo-update")
                case 2:
                    try shell("bundle exec pod install --repo-update")
                default:
                    try shell("TYPE=STATIC bundle exec pod install --repo-update")
                }
                try shell("open RMobile.xcworkspace")
            } catch {
                fflush(__stdoutp)
                try! FileHandle.standardOutput.write(contentsOf: "Fatal error".data(using: .utf8)!)
                print("Fatal error")
                print(error.localizedDescription)
                fflush(__stdoutp)
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }                
            }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    
    func closeXcode() {
        try? shell("kill $(ps aux | grep 'Xcode' | awk '{print $2}')")
        try? shell("kill -9 $(ps aux | grep 'Xcode' | awk '{print $2}')")
        try? shell("killall -9 \"Xcode\"")
    }
    
    func checkout(pod: PodDependecy, to destination: CheckoutType) throws {
        if !FileManager.default.fileExists(atPath: pod.localRepoPath + "/.git") {            
            let specPath = try shell("bundle exec pod spec which --regex ^\(pod.name)$ --show-all | grep raiffeisen | head -1 | xargs echo -n")
            let gitURL = try shell("ruby -rcocoapods -e 'puts (eval File.read(\"\(specPath)\")).source[:git]'").trimmingCharacters(in: .newlines)
            try shell("/usr/bin/git clone \(gitURL) \(pod.localRepoPath)")
        } else {
            try shell("/usr/bin/git -C \(pod.localRepoPath) fetch origin --progress --tags")
        }
        switch(destination){
        case .master:
            try shell("/usr/bin/git -C \(pod.localRepoPath) checkout master")
            try shell("/usr/bin/git -C \(pod.localRepoPath) pull origin master")
        case .version(let version):
            try shell("/usr/bin/git -C \(pod.localRepoPath) checkout tags/\(version)")
        }
        
    }
    
    func saveCredentionals() {
        try? saveCredentionals(login: enteredLogin, password: enteredPassword)
        credentionals = (login: enteredLogin, password: enteredPassword)
    }
    
    private func saveCredentionals(login: String, password: String) throws {
        enum SaveError: Error {
            case unexpectedStatus(OSStatus)
        }
        let query: [String: AnyObject] = [
            // kSecAttrService,  kSecAttrAccount, and kSecClass
            // uniquely identify the item to save in Keychain
            kSecAttrService as String: "artifactory.raiffeisen.ru" as AnyObject,
            kSecAttrLabel as String: "tuist cli" as AnyObject,
            kSecAttrServer as String: "artifactory.raiffeisen.ru" as AnyObject,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrAccount as String: login as AnyObject,
            kSecClass as String: kSecClassInternetPassword,
            
            // kSecValueData is the item value to save
            kSecValueData as String: password as AnyObject
        ]
        
        // SecItemAdd attempts to add the item identified by
        // the query to keychain
        var status = SecItemAdd(
            query as CFDictionary,
            nil
        )
        
        // Update key, if exists
        if status == errSecDuplicateItem {
            let attributes: [String: AnyObject] = [
                kSecValueData as String: password as AnyObject
            ]
            status = SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )
        }
        
        // Any status other than errSecSuccess indicates the
        // save operation failed.
        print(status)
        guard status == errSecSuccess else {
            throw SaveError.unexpectedStatus(status)
        }
        
    }
    
    private func getSavedCredentionals() throws -> (login: String, password: String)  {
        enum GettingError: Error {
            case itemNotFound
            case invalidItemFormat
            case unexpectedStatus(OSStatus)
        }
        let query: [String: AnyObject] = [
            kSecAttrService as String: "artifactory.raiffeisen.ru" as AnyObject,
            kSecAttrLabel as String: "tuist cli" as AnyObject,
            kSecAttrServer as String: "artifactory.raiffeisen.ru" as AnyObject,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecClass as String: kSecClassInternetPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue,
            kSecReturnAttributes as String: kCFBooleanTrue
        ]
        
        // SecItemCopyMatching will attempt to copy the item
        // identified by query to the reference itemCopy
        var itemCopy: AnyObject?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &itemCopy
        )
        
        guard status != errSecItemNotFound else {
            throw GettingError.itemNotFound
        }
        
        guard status == errSecSuccess else {
            throw GettingError.unexpectedStatus(status)
        }
        
        guard let dic = itemCopy as? NSDictionary else {
            throw GettingError.invalidItemFormat
        }
        print("Found password in \(dic[kSecAttrLabel] ?? "none")(\(dic[kSecAttrServer] ?? "none"))")
        let username = (dic[kSecAttrAccount] as? String) ?? ""
        let passwordData = (dic[kSecValueData] as? Data) ?? Data()
        
        guard let password = String(data: passwordData, encoding: .utf8), !username.isEmpty else {
            throw GettingError.invalidItemFormat
        }
        guard !username.isEmpty && !password.isEmpty else {
            throw GettingError.itemNotFound
        }
        return (login: username, password: password)
    }
}

struct PodDependecy: Identifiable, Equatable, Hashable {
    init(name: String, rawData: [String], startLine: Int, endLine: Int) {
        self.name = name
        self.startLine = startLine
        self.endLine = endLine
        self.components = rawData.reduce([String:String]()) { preResult, element in
            var result = preResult
            let components = element.components(separatedBy: "=>")
            guard let key = components.first, let value = components.last else {
                return preResult
            }
            result[key.trimmingCharacters(in: .whitespaces)] = value.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .init(charactersIn: "\",'"))
            return result
        }
    }
    var id: String { return name }
    var name: String
    var startLine: Int
    var endLine: Int
    private var components: [String: String]
    
    var devPod: Bool {
        get {
            return components[":dev_pod"] == "true"
        }
        set {
            components[":dev_pod"] = "\(newValue)"
        }
    }
    
    var branch: String {
        get {
            components[":branch"] ?? ""
        }
        set {
            components[":branch"] = "\(newValue)"
        }
    }
    
    var version: String {
        get {
            components[":version"] ?? ""
        }
        set {
            components[":version"] = "\(newValue)"
        }
    }
    
    var settings: String {
        get {
            components[":settings"] ?? "{}"
        }
        set {
            components[":settings"] = "\(newValue)"
        }
    }
    
    var localRepoPath: String {
        get {
            components[":local_repo_path"] ?? ""
        }
        set {
            components[":local_repo_path"] = "\(newValue)"
        }
    }
    
    var testSpecs: String {
        get {
            components[":testspecs"] ?? "[]"
        }
        set {
            components[":testspecs"] = "\(newValue)"
        }
    }
    
    var ioName: String {
        get {
            components[":io"] ?? ""
        }
        set {
            components[":io"] = "\(newValue)"
        }
    }
    
    var generatedData: String {
        return """
pod_constructor :name => '\(name)', \(ioName.isEmpty ? "" : "\n                    :io => '\(ioName)',")
                    :version => '\(version)',
                    :settings => \(settings),
                    :branch => "\(branch)",
                    :testspecs => \(testSpecs),
                    :local_repo_path => '\(localRepoPath)',
                    :dev_pod => \(devPod)
"""
    }
}

extension String: Error {}
