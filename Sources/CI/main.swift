//
//  File.swift
//  
//
//  Created by ANTROPOV Evgeny on 19.05.2022.
//

import Foundation
import RunShell

setbuf(__stdoutp, nil)
do {
    let needsPodInstall = (try? shell("diff Podfile.lock Pods/Manifest.lock")) == nil

    // Могут быть проблемы с авторизацией при доступе к artifactory. Возможно, потребуется вынести в .gitlab-ci.yaml
    if (try? shell("CI_PIPELINE=TRUE bundle check")) == nil {
        try shell("CI_PIPELINE=TRUE bundle install")
    }
    let homeDirURL = URL(fileURLWithPath: NSHomeDirectory())
    
    if needsPodInstall {
        if (
            (try? shell("CI_PIPELINE=TRUE bundle exec pod repo-art list | grep cocoapods-art")) == nil ||
            !FileManager.default.fileExists(atPath: "\(homeDirURL.path)/.cocoapods/repos-art/cocoapods-art/.artpodrc")
        ) {
            _ = try? shell("CI_PIPELINE=TRUE bundle exec pod repo-art remove cocoapods-art")
            try shell("CI_PIPELINE=TRUE bundle exec pod repo-art add cocoapods-art \"https://artifactory.raiffeisen.ru/artifactory/api/pods/cocoapods\"")
        } else {
            print("HomeDir - \(homeDirURL.path)")
            let artifactoryUpdateTime = fileModificationDate(path: "\(homeDirURL.path)/.cocoapods/repos-art/cocoapods-art")
            if let artifactoryUpdateTime = artifactoryUpdateTime,
               Date().timeIntervalSince(artifactoryUpdateTime) > 5 * 24 * 60 * 60 {
                print("Artifactory needs to be updates: \(artifactoryUpdateTime)")
                try shell("CI_PIPELINE=TRUE bundle exec pod repo-art update cocoapods-art")
            } else {
                print("Artifactory already updated: \(String(describing: artifactoryUpdateTime))")
            }
        }
    }

    try shell("tuist generate -n")
} catch {
    fatalError(error.localizedDescription)
}

func fileModificationDate(path: String) -> Date? {
    do {
        let attr = try FileManager.default.attributesOfItem(atPath: path)
        return attr[FileAttributeKey.modificationDate] as? Date
    } catch {
        return nil
    }
}
