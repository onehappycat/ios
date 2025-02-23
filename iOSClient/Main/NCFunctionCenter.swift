//
//  NCFunctionCenter.swift
//  Nextcloud
//
//  Created by Marino Faggiana on 19/04/2020.
//  Copyright © 2020 Marino Faggiana. All rights reserved.
//
//  Author Marino Faggiana <marino.faggiana@nextcloud.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import NextcloudKit
import Queuer
import JGProgressHUD
import SVGKit
import Photos

@objc class NCFunctionCenter: NSObject, UIDocumentInteractionControllerDelegate, NCSelectDelegate {
    @objc public static let shared: NCFunctionCenter = {
        let instance = NCFunctionCenter()
        NotificationCenter.default.addObserver(instance, selector: #selector(downloadedFile(_:)), name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterDownloadedFile), object: nil)
        NotificationCenter.default.addObserver(instance, selector: #selector(uploadedFile(_:)), name: NSNotification.Name(rawValue: NCGlobal.shared.notificationCenterUploadedFile), object: nil)
        return instance
    }()

    let appDelegate = UIApplication.shared.delegate as! AppDelegate
    var viewerQuickLook: NCViewerQuickLook?
    var documentController: UIDocumentInteractionController?

    // MARK: - Download

    @objc func downloadedFile(_ notification: NSNotification) {

        guard let userInfo = notification.userInfo as NSDictionary?,
              let ocId = userInfo["ocId"] as? String,
              let selector = userInfo["selector"] as? String,
              let error = userInfo["error"] as? NKError,
              let account = userInfo["account"] as? String,
              account == appDelegate.account
        else { return }

        guard error == .success else {
            // File do not exists on server, remove in local
            if error.errorCode == NCGlobal.shared.errorResourceNotFound || error.errorCode == NCGlobal.shared.errorBadServerResponse {
                do {
                    try FileManager.default.removeItem(atPath: CCUtility.getDirectoryProviderStorageOcId(ocId))
                } catch { }
                NCManageDatabase.shared.deleteMetadata(predicate: NSPredicate(format: "ocId == %@", ocId))
                NCManageDatabase.shared.deleteLocalFile(predicate: NSPredicate(format: "ocId == %@", ocId))
                
            } else {
                NCContentPresenter.shared.messageNotification("_download_file_", error: error, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error, priority: .max)
            }
            return
        }
        guard let metadata = NCManageDatabase.shared.getMetadataFromOcId(ocId) else { return }

        switch selector {
        case NCGlobal.shared.selectorLoadFileQuickLook:
            let fileNamePath = NSTemporaryDirectory() + metadata.fileNameView
            CCUtility.copyFile(atPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView), toPath: fileNamePath)
            let viewerQuickLook = NCViewerQuickLook(with: URL(fileURLWithPath: fileNamePath), isEditingEnabled: true, metadata: metadata)
            self.appDelegate.window?.rootViewController?.present(viewerQuickLook, animated: true)

        case NCGlobal.shared.selectorLoadFileView:
            guard UIApplication.shared.applicationState == .active else { break }

            if metadata.contentType.contains("opendocument") && !NCUtility.shared.isRichDocument(metadata) {
                self.openDocumentController(metadata: metadata)
            } else if metadata.classFile == NKCommon.typeClassFile.compress.rawValue || metadata.classFile == NKCommon.typeClassFile.unknow.rawValue {
                self.openDocumentController(metadata: metadata)
            } else {
                if let viewController = self.appDelegate.activeViewController {
                    let imageIcon = UIImage(contentsOfFile: CCUtility.getDirectoryProviderStorageIconOcId(metadata.ocId, etag: metadata.etag))
                    NCViewer.shared.view(viewController: viewController, metadata: metadata, metadatas: [metadata], imageIcon: imageIcon)
                }
            }
            
        case NCGlobal.shared.selectorOpenIn:
            if UIApplication.shared.applicationState == .active {
                self.openDocumentController(metadata: metadata)
            }
            
        case NCGlobal.shared.selectorLoadOffline:
            NCManageDatabase.shared.setLocalFile(ocId: metadata.ocId, offline: true)
            
        case NCGlobal.shared.selectorPrint:
            printDocument(metadata: metadata)
            
        case NCGlobal.shared.selectorSaveAlbum:
            saveAlbum(metadata: metadata)

        case NCGlobal.shared.selectorSaveAlbumLivePhotoIMG, NCGlobal.shared.selectorSaveAlbumLivePhotoMOV:

            var metadata = metadata
            var metadataMOV = metadata
            guard let metadataTMP = NCManageDatabase.shared.getMetadataLivePhoto(metadata: metadata) else { break }

            if selector == NCGlobal.shared.selectorSaveAlbumLivePhotoIMG {
                metadataMOV = metadataTMP
            }

            if selector == NCGlobal.shared.selectorSaveAlbumLivePhotoMOV {
                metadata = metadataTMP
            }

            if CCUtility.fileProviderStorageExists(metadata) && CCUtility.fileProviderStorageExists(metadataMOV) {
                saveLivePhotoToDisk(metadata: metadata, metadataMov: metadataMOV)
            }

        case NCGlobal.shared.selectorSaveAsScan:
            saveAsScan(metadata: metadata)

        case NCGlobal.shared.selectorOpenDetail:
            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterOpenMediaDetail, userInfo: ["ocId": metadata.ocId])

        default:
            break
        }
    }

    func setMetadataAvalableOffline(_ metadata: tableMetadata, isOffline: Bool) {
        let serverUrl = metadata.serverUrl + "/" + metadata.fileName
        if isOffline {
            if metadata.directory {
                NCManageDatabase.shared.setDirectory(serverUrl: serverUrl, offline: false, account: self.appDelegate.account)
            } else {
                NCManageDatabase.shared.setLocalFile(ocId: metadata.ocId, offline: false)
            }
        } else if metadata.directory {
            NCManageDatabase.shared.setDirectory(serverUrl: serverUrl, offline: true, account: self.appDelegate.account)
            NCOperationQueue.shared.synchronizationMetadata(metadata, selector: NCGlobal.shared.selectorDownloadAllFile)
        } else {
            NCNetworking.shared.download(metadata: metadata, selector: NCGlobal.shared.selectorLoadOffline) { _, _ in }
            if let metadataLivePhoto = NCManageDatabase.shared.getMetadataLivePhoto(metadata: metadata) {
                NCNetworking.shared.download(metadata: metadataLivePhoto, selector: NCGlobal.shared.selectorLoadOffline) { _, _ in }
            }
        }
    }

    // MARK: - Upload

    @objc func uploadedFile(_ notification: NSNotification) {

        guard let userInfo = notification.userInfo as NSDictionary?,
              let error = userInfo["error"] as? NKError,
              let account = userInfo["account"] as? String,
              account == appDelegate.account
        else { return }

        if error != .success, error.errorCode != NSURLErrorCancelled, error.errorCode != NCGlobal.shared.errorRequestExplicityCancelled {
            NCContentPresenter.shared.messageNotification("_upload_file_", error: error, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error, priority: .max)
        }
    }

    // MARK: -

    func openShare(viewController: UIViewController, metadata: tableMetadata, indexPage: NCGlobal.NCSharePagingIndex) {

        let serverUrlFileName = metadata.serverUrl + "/" + metadata.fileName
        NCActivityIndicator.shared.start(backgroundView: viewController.view)
        NCNetworking.shared.readFile(serverUrlFileName: serverUrlFileName, queue: .main) { account, metadata, error in
            NCActivityIndicator.shared.stop()
            if let metadata = metadata, error == .success {
                let shareNavigationController = UIStoryboard(name: "NCShare", bundle: nil).instantiateInitialViewController() as! UINavigationController
                let shareViewController = shareNavigationController.topViewController as! NCSharePaging

                shareViewController.metadata = metadata
                shareViewController.indexPage = indexPage

                shareNavigationController.modalPresentationStyle = .formSheet
                viewController.present(shareNavigationController, animated: true, completion: nil)
            }
        }
    }

    // MARK: -

    func openDownload(metadata: tableMetadata, selector: String) {

        if CCUtility.fileProviderStorageExists(metadata) {

            NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterDownloadedFile, userInfo: ["ocId": metadata.ocId, "selector": selector, "error": NKError(), "account": metadata.account])

        } else {

            NCNetworking.shared.download(metadata: metadata, selector: selector) { _, _ in }
        }
    }

    // MARK: - Open in ...

    func openDocumentController(metadata: tableMetadata) {

        guard let mainTabBar = self.appDelegate.mainTabBar else { return }
        let fileURL = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView))

        documentController = UIDocumentInteractionController(url: fileURL)
        documentController?.presentOptionsMenu(from: mainTabBar.menuRect, in: mainTabBar, animated: true)
    }

    func openActivityViewController(selectedMetadata: [tableMetadata]) {
        let metadatas = selectedMetadata.filter({ !$0.directory })
        var items: [URL] = []
        var downloadMetadata: [(tableMetadata, URL)] = []

        for metadata in metadatas {
            let fileURL = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView))
            if CCUtility.fileProviderStorageExists(metadata) { items.append(fileURL) }
            else { downloadMetadata.append((metadata, fileURL)) }
        }

        let processor = ParallelWorker(n: 5, titleKey: "_downloading_", totalTasks: downloadMetadata.count, hudView: self.appDelegate.window?.rootViewController?.view)
        for (metadata, url) in downloadMetadata {
            processor.execute { completion in
                NCNetworking.shared.download(metadata: metadata, selector: "", completion: { _, _ in
                    if CCUtility.fileProviderStorageExists(metadata) { items.append(url) }
                    completion()
                })
            }
        }

        processor.completeWork {
            guard !items.isEmpty, let mainTabBar = self.appDelegate.mainTabBar else { return }
            let activityViewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
            activityViewController.popoverPresentationController?.permittedArrowDirections = .any
            activityViewController.popoverPresentationController?.sourceView = mainTabBar
            activityViewController.popoverPresentationController?.sourceRect = mainTabBar.menuRect
            self.appDelegate.window?.rootViewController?.present(activityViewController, animated: true)
        }
    }

    // MARK: - Save as scan

    func saveAsScan(metadata: tableMetadata) {

        let fileNamePath = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!
        let fileNameDestination = CCUtility.createFileName("scan.png", fileDate: Date(), fileType: PHAssetMediaType.image, keyFileName: NCGlobal.shared.keyFileNameMask, keyFileNameType: NCGlobal.shared.keyFileNameType, keyFileNameOriginal: NCGlobal.shared.keyFileNameOriginal, forcedNewFileName: true)!
        let fileNamePathDestination = CCUtility.getDirectoryScan() + "/" + fileNameDestination

        NCUtilityFileSystem.shared.copyFile(atPath: fileNamePath, toPath: fileNamePathDestination)

        let storyboard = UIStoryboard(name: "NCScan", bundle: nil)
        let navigationController = storyboard.instantiateInitialViewController()!

        navigationController.modalPresentationStyle = UIModalPresentationStyle.pageSheet

        appDelegate.window?.rootViewController?.present(navigationController, animated: true, completion: nil)
    }

    // MARK: - Print

    func printDocument(metadata: tableMetadata) {
        let fileNameURL = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!)
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.jobName = fileNameURL.lastPathComponent
        printInfo.outputType = metadata.classFile == NKCommon.typeClassFile.image.rawValue ? .photo : .general
        printController.printInfo = printInfo
        printController.showsNumberOfCopies = true

        guard !UIPrintInteractionController.canPrint(fileNameURL) else {
            printController.printingItem = fileNameURL
            printController.present(animated: true)
            return
        }

        // can't print without data
        guard let data = try? Data(contentsOf: fileNameURL) else { return }

        if let svg = SVGKImage(data: data) {
            printController.printingItem = svg.uiImage
            printController.present(animated: true)
            return
        }

        guard let text = String(data: data, encoding: .utf8) else { return }
        let formatter = UISimpleTextPrintFormatter(text: text)
        formatter.perPageContentInsets.top = 72
        formatter.perPageContentInsets.bottom = 72
        formatter.perPageContentInsets.left = 72
        formatter.perPageContentInsets.right = 72
        printController.printFormatter = formatter
        printController.present(animated: true)
    }

    // MARK: - Save photo

    func saveAlbum(metadata: tableMetadata) {

        let fileNamePath = CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!

        NCAskAuthorization.shared.askAuthorizationPhotoLibrary(viewController: appDelegate.mainTabBar?.window?.rootViewController) { hasPermission in
            guard hasPermission else {
                let error = NKError(errorCode: NCGlobal.shared.errorFileNotSaved, errorDescription: "_access_photo_not_enabled_msg_")
                return NCContentPresenter.shared.messageNotification("_access_photo_not_enabled_", error: error, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error)
            }
            if metadata.classFile == NKCommon.typeClassFile.image.rawValue, let image = UIImage(contentsOfFile: fileNamePath) {
                UIImageWriteToSavedPhotosAlbum(image, self, #selector(self.saveAlbum(_:didFinishSavingWithError:contextInfo:)), nil)
            } else if metadata.classFile == NKCommon.typeClassFile.video.rawValue, UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(fileNamePath) {
                UISaveVideoAtPathToSavedPhotosAlbum(fileNamePath, self, #selector(self.saveAlbum(_:didFinishSavingWithError:contextInfo:)), nil)
            } else {
                let error = NKError(errorCode: NCGlobal.shared.errorFileNotSaved, errorDescription: "_file_not_saved_cameraroll_")
                NCContentPresenter.shared.messageNotification("_save_selected_files_", error: error, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error)
            }
        }
    }

    @objc private func saveAlbum(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {

        if error != nil {
            let error = NKError(errorCode: NCGlobal.shared.errorFileNotSaved, errorDescription: "_file_not_saved_cameraroll_")
            NCContentPresenter.shared.messageNotification("_save_selected_files_", error: error, delay: NCGlobal.shared.dismissAfterSecond, type: NCContentPresenter.messageType.error)
        }
    }

    func saveLivePhoto(metadata: tableMetadata, metadataMOV: tableMetadata) {

        if !CCUtility.fileProviderStorageExists(metadata) {
            NCOperationQueue.shared.download(metadata: metadata, selector: NCGlobal.shared.selectorSaveAlbumLivePhotoIMG)
        }

        if !CCUtility.fileProviderStorageExists(metadataMOV) {
            NCOperationQueue.shared.download(metadata: metadataMOV, selector: NCGlobal.shared.selectorSaveAlbumLivePhotoMOV)
        }

        if CCUtility.fileProviderStorageExists(metadata) && CCUtility.fileProviderStorageExists(metadataMOV) {
            saveLivePhotoToDisk(metadata: metadata, metadataMov: metadataMOV)
        }
    }

    func saveLivePhotoToDisk(metadata: tableMetadata, metadataMov: tableMetadata) {

        let fileNameImage = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(metadata.ocId, fileNameView: metadata.fileNameView)!)
        let fileNameMov = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(metadataMov.ocId, fileNameView: metadataMov.fileNameView)!)
        let hud = JGProgressHUD()
        
        hud.indicatorView = JGProgressHUDRingIndicatorView()
        if let indicatorView = hud.indicatorView as? JGProgressHUDRingIndicatorView {
            indicatorView.ringWidth = 1.5
        }
        hud.textLabel.text = NSLocalizedString("_saving_", comment: "")
        hud.show(in: (appDelegate.window?.rootViewController?.view)!)

        NCLivePhoto.generate(from: fileNameImage, videoURL: fileNameMov, progress: { progress in
            
            hud.progress = Float(progress)

        }, completion: { _, resources in

            if resources != nil {
                NCLivePhoto.saveToLibrary(resources!) { result in
                    DispatchQueue.main.async {
                        if !result {
                            hud.indicatorView = JGProgressHUDErrorIndicatorView()
                            hud.textLabel.text = NSLocalizedString("_livephoto_save_error_", comment: "")
                        } else {
                            hud.indicatorView = JGProgressHUDSuccessIndicatorView()
                            hud.textLabel.text = NSLocalizedString("_success_", comment: "")
                        }
                        hud.dismiss(afterDelay: 1)
                    }
                }
            } else {
                hud.indicatorView = JGProgressHUDErrorIndicatorView()
                hud.textLabel.text = NSLocalizedString("_livephoto_save_error_", comment: "")
                hud.dismiss(afterDelay: 1)
            }
        })
    }

    // MARK: - Copy & Paste

    func copyPasteboard(pasteboardOcIds: [String], hudView: UIView) {
        var items = [[String: Any]]()
        let hud = JGProgressHUD()
        hud.textLabel.text = NSLocalizedString("_wait_", comment: "")
        hud.show(in: hudView)

        // getting file data can take some time and block the main queue
        DispatchQueue.global(qos: .userInitiated).async {
            var downloadMetadatas: [tableMetadata] = []
            for ocid in pasteboardOcIds {
                guard let metadata = NCManageDatabase.shared.getMetadataFromOcId(ocid) else { continue }
                if let pasteboardItem = metadata.toPasteBoardItem() { items.append(pasteboardItem) }
                else { downloadMetadatas.append(metadata) }
            }

            DispatchQueue.main.async(execute: hud.dismiss)

            // do 5 downloads in parallel to optimize efficiency
            let parallelizer = ParallelWorker(n: 5, titleKey: "_downloading_", totalTasks: downloadMetadatas.count, hudView: hudView)

            for metadata in downloadMetadatas {
                parallelizer.execute { completion in
                    NCNetworking.shared.download(metadata: metadata, selector: "") { _, _ in completion() }
                }
            }
            parallelizer.completeWork {
                items.append(contentsOf: downloadMetadatas.compactMap({ $0.toPasteBoardItem() }))
                UIPasteboard.general.setItems(items, options: [:])
            }
        }
    }

    func pastePasteboard(serverUrl: String) {
        let parallelizer = ParallelWorker(n: 5, titleKey: "_uploading_", totalTasks: nil, hudView: appDelegate.window?.rootViewController?.view)

        func uploadPastePasteboard(fileName: String, serverUrlFileName: String, fileNameLocalPath: String, serverUrl: String, completion: @escaping () -> Void) {
            NextcloudKit.shared.upload(serverUrlFileName: serverUrlFileName, fileNameLocalPath: fileNameLocalPath) { request in
                NCNetworking.shared.uploadRequest[fileNameLocalPath] = request
            } progressHandler: { progress in
            } completionHandler: { account, ocId, etag, _, _, _, afError, error in
                NCNetworking.shared.uploadRequest.removeValue(forKey: fileNameLocalPath)
                if error == .success && etag != nil && ocId != nil {
                    let toPath = CCUtility.getDirectoryProviderStorageOcId(ocId!, fileNameView: fileName)!
                    NCUtilityFileSystem.shared.moveFile(atPath: fileNameLocalPath, toPath: toPath)
                    NCManageDatabase.shared.addLocalFile(account: account, etag: etag!, ocId: ocId!, fileName: fileName)
                    NotificationCenter.default.postOnMainThread(name: NCGlobal.shared.notificationCenterReloadDataSourceNetworkForced, userInfo: ["serverUrl": serverUrl])
                } else if afError?.isExplicitlyCancelledError ?? false {
                    print("cancel")
                } else {
                    NCContentPresenter.shared.showError(error: error)
                }
                completion()
            }
        }

        for (index, items) in UIPasteboard.general.items.enumerated() {
            for item in items {
                let results = NKCommon.shared.getFileProperties(inUTI: item.key as CFString)
                guard !results.ext.isEmpty,
                      let data = UIPasteboard.general.data(forPasteboardType: item.key, inItemSet: IndexSet([index]))?.first
                else { continue }
                let fileName = results.name + "_" + CCUtility.getIncrementalNumber() + "." + results.ext
                let serverUrlFileName = serverUrl + "/" + fileName
                let ocIdUpload = UUID().uuidString
                let fileNameLocalPath = CCUtility.getDirectoryProviderStorageOcId(ocIdUpload, fileNameView: fileName)!
                do { try data.write(to: URL(fileURLWithPath: fileNameLocalPath)) } catch { continue }
                parallelizer.execute { completion in
                    uploadPastePasteboard(fileName: fileName, serverUrlFileName: serverUrlFileName, fileNameLocalPath: fileNameLocalPath, serverUrl: serverUrl, completion: completion)
                }
            }
        }
        parallelizer.completeWork()
    }

    // MARK: -

    func openFileViewInFolder(serverUrl: String, fileNameBlink: String?, fileNameOpen: String?) {

        appDelegate.isSearchingMode = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var topNavigationController: UINavigationController?
            var pushServerUrl = NCUtilityFileSystem.shared.getHomeServer(urlBase: self.appDelegate.urlBase, userId: self.appDelegate.userId)
            guard var mostViewController = self.appDelegate.window?.rootViewController?.topMostViewController() else { return }

            if mostViewController.isModal {
                mostViewController.dismiss(animated: false)
                if let viewController = self.appDelegate.window?.rootViewController?.topMostViewController() {
                    mostViewController = viewController
                }
            }
            mostViewController.navigationController?.popToRootViewController(animated: false)

            if let tabBarController = self.appDelegate.window?.rootViewController as? UITabBarController {
                tabBarController.selectedIndex = 0
                if let navigationController = tabBarController.viewControllers?.first as? UINavigationController {
                    navigationController.popToRootViewController(animated: false)
                    topNavigationController = navigationController
                }
            }
            if pushServerUrl == serverUrl {
                let viewController = topNavigationController?.topViewController as? NCFiles
                viewController?.blinkCell(fileName: fileNameBlink)
                viewController?.openFile(fileName: fileNameOpen)
                return
            }
            guard let topNavigationController = topNavigationController else { return }

            let diffDirectory = serverUrl.replacingOccurrences(of: pushServerUrl, with: "")
            var subDirs = diffDirectory.split(separator: "/")

            while pushServerUrl != serverUrl, subDirs.count > 0  {

                guard let dir = subDirs.first, let viewController = UIStoryboard(name: "NCFiles", bundle: nil).instantiateInitialViewController() as? NCFiles else { return }
                pushServerUrl = pushServerUrl + "/" + dir

                viewController.serverUrl = pushServerUrl
                viewController.isRoot = false
                viewController.titleCurrentFolder = String(dir)
                if pushServerUrl == serverUrl {
                    viewController.fileNameBlink = fileNameBlink
                    viewController.fileNameOpen = fileNameOpen
                }
                self.appDelegate.listFilesVC[serverUrl] = viewController

                viewController.navigationItem.backButtonTitle = viewController.titleCurrentFolder
                topNavigationController.pushViewController(viewController, animated: false)

                subDirs.remove(at: 0)
            }
        }
    }


    // MARK: - NCSelect + Delegate

    func dismissSelect(serverUrl: String?, metadata: tableMetadata?, type: String, items: [Any], overwrite: Bool, copy: Bool, move: Bool) {
        if serverUrl != nil && items.count > 0 {
            if copy {
                for metadata in items as! [tableMetadata] {
                    NCOperationQueue.shared.copyMove(metadata: metadata, serverUrl: serverUrl!, overwrite: overwrite, move: false)
                }
            } else if move {
                for metadata in items as! [tableMetadata] {
                    NCOperationQueue.shared.copyMove(metadata: metadata, serverUrl: serverUrl!, overwrite: overwrite, move: true)
                }
            }
        }
    }

    func openSelectView(items: [tableMetadata]) {

        let navigationController = UIStoryboard(name: "NCSelect", bundle: nil).instantiateInitialViewController() as! UINavigationController
        let topViewController = navigationController.topViewController as! NCSelect
        var listViewController = [NCSelect]()

        var copyItems: [tableMetadata] = []
        for item in items {
            copyItems.append(item)
        }

        let homeUrl = NCUtilityFileSystem.shared.getHomeServer(urlBase: appDelegate.urlBase, userId: appDelegate.userId)
        var serverUrl = copyItems[0].serverUrl

        // Setup view controllers such that the current view is of the same directory the items to be copied are in
        while true {
            // If not in the topmost directory, create a new view controller and set correct title.
            // If in the topmost directory, use the default view controller as the base.
            var viewController: NCSelect?
            if serverUrl != homeUrl {
                viewController = UIStoryboard(name: "NCSelect", bundle: nil).instantiateViewController(withIdentifier: "NCSelect.storyboard") as? NCSelect
                if viewController == nil {
                    return
                }
                viewController!.titleCurrentFolder = (serverUrl as NSString).lastPathComponent
            } else {
                viewController = topViewController
            }
            guard let vc = viewController else { return }

            vc.delegate = self
            vc.typeOfCommandView = .copyMove
            vc.items = copyItems
            vc.serverUrl = serverUrl

            vc.navigationItem.backButtonTitle = vc.titleCurrentFolder
            listViewController.insert(vc, at: 0)

            if serverUrl != homeUrl {
                if let path = NCUtilityFileSystem.shared.deleteLastPath(serverUrlPath: serverUrl) {
                    serverUrl = path
                }
            } else {
                break
            }
        }

        navigationController.setViewControllers(listViewController, animated: false)
        navigationController.modalPresentationStyle = .formSheet

        appDelegate.window?.rootViewController?.present(navigationController, animated: true, completion: nil)
    }

    // MARK: - Context Menu Configuration

    func contextMenuConfiguration(ocId: String, viewController: UIViewController, enableDeleteLocal: Bool, enableViewInFolder: Bool, image: UIImage?) -> UIMenu {

        guard let metadata = NCManageDatabase.shared.getMetadataFromOcId(ocId) else {
            return UIMenu()
        }
        let isFolderEncrypted = CCUtility.isFolderEncrypted(metadata.serverUrl, e2eEncrypted: metadata.e2eEncrypted, account: metadata.account, urlBase: metadata.urlBase, userId: metadata.userId)
        var titleDeleteConfirmFile = NSLocalizedString("_delete_file_", comment: "")
        if metadata.directory { titleDeleteConfirmFile = NSLocalizedString("_delete_folder_", comment: "") }
        var titleSave: String = NSLocalizedString("_save_selected_files_", comment: "")
        let metadataMOV = NCManageDatabase.shared.getMetadataLivePhoto(metadata: metadata)
        if metadataMOV != nil {
            titleSave = NSLocalizedString("_livephoto_save_", comment: "")
        }
        let titleFavorite = metadata.favorite ? NSLocalizedString("_remove_favorites_", comment: "") : NSLocalizedString("_add_favorites_", comment: "")

        let serverUrl = metadata.serverUrl + "/" + metadata.fileName
        var isOffline = false
        if metadata.directory {
            if let directory = NCManageDatabase.shared.getTableDirectory(predicate: NSPredicate(format: "account == %@ AND serverUrl == %@", appDelegate.account, serverUrl)) {
                isOffline = directory.offline
            }
        } else {
            if let localFile = NCManageDatabase.shared.getTableLocalFile(predicate: NSPredicate(format: "ocId == %@", metadata.ocId)) {
                isOffline = localFile.offline
            }
        }
        let titleOffline = isOffline ? NSLocalizedString("_remove_available_offline_", comment: "") :  NSLocalizedString("_set_available_offline_", comment: "")
        let titleLock = metadata.lock ? NSLocalizedString("_unlock_file_", comment: "") :  NSLocalizedString("_lock_file_", comment: "")
        let iconLock = metadata.lock ? "lock.open" : "lock"
        let copy = UIAction(title: NSLocalizedString("_copy_file_", comment: ""), image: UIImage(systemName: "doc.on.doc")) { _ in
            self.copyPasteboard(pasteboardOcIds: [metadata.ocId], hudView: viewController.view)
        }

        let copyPath = UIAction(title: NSLocalizedString("_copy_path_", comment: ""), image: UIImage(systemName: "doc.on.clipboard")) { _ in
            let board = UIPasteboard.general
            board.string = NCUtilityFileSystem.shared.getPath(path: metadata.path, user: metadata.user, fileName: metadata.fileName)
            let error = NKError(errorCode: NCGlobal.shared.errorInternalError, errorDescription: "_copied_path_")
            NCContentPresenter.shared.showInfo(error: error)
        }

        let detail = UIAction(title: NSLocalizedString("_details_", comment: ""), image: UIImage(systemName: "info")) { _ in
            self.openShare(viewController: viewController, metadata: metadata, indexPage: .activity)
        }

        let offline = UIAction(title: titleOffline, image: UIImage(systemName: "tray.and.arrow.down")) { _ in
            self.setMetadataAvalableOffline(metadata, isOffline: isOffline)
            if let viewController = viewController as? NCCollectionViewCommon {
                viewController.reloadDataSource()
            }
        }
        
        let lockUnlock = UIAction(title: titleLock, image: UIImage(systemName: iconLock)) { _ in
            NCNetworking.shared.lockUnlockFile(metadata, shoulLock: !metadata.lock)
        }
        let save = UIAction(title: titleSave, image: UIImage(systemName: "square.and.arrow.down")) { _ in
            if metadataMOV != nil {
                self.saveLivePhoto(metadata: metadata, metadataMOV: metadataMOV!)
            } else {
                if CCUtility.fileProviderStorageExists(metadata) {
                    self.saveAlbum(metadata: metadata)
                } else {
                    NCOperationQueue.shared.download(metadata: metadata, selector: NCGlobal.shared.selectorSaveAlbum)
                }
            }
        }

        let viewInFolder = UIAction(title: NSLocalizedString("_view_in_folder_", comment: ""), image: UIImage(systemName: "arrow.forward.square")) { _ in
            self.openFileViewInFolder(serverUrl: metadata.serverUrl, fileNameBlink: metadata.fileName, fileNameOpen: nil)
        }

        let openIn = UIAction(title: NSLocalizedString("_open_in_", comment: ""), image: UIImage(systemName: "square.and.arrow.up") ) { _ in
            self.openDownload(metadata: metadata, selector: NCGlobal.shared.selectorOpenIn)
        }

        let print = UIAction(title: NSLocalizedString("_print_", comment: ""), image: UIImage(systemName: "printer") ) { _ in
            self.openDownload(metadata: metadata, selector: NCGlobal.shared.selectorPrint)
        }

        let modify = UIAction(title: NSLocalizedString("_modify_", comment: ""), image: UIImage(systemName: "pencil.tip.crop.circle")) { _ in
            self.openDownload(metadata: metadata, selector: NCGlobal.shared.selectorLoadFileQuickLook)
        }

        let saveAsScan = UIAction(title: NSLocalizedString("_save_as_scan_", comment: ""), image: UIImage(systemName: "viewfinder.circle")) { _ in
            self.openDownload(metadata: metadata, selector: NCGlobal.shared.selectorSaveAsScan)
        }

        // let open = UIMenu(title: NSLocalizedString("_open_", comment: ""), image: UIImage(systemName: "square.and.arrow.up"), children: [openIn, openQuickLook])

        let moveCopy = UIAction(title: NSLocalizedString("_move_or_copy_", comment: ""), image: UIImage(systemName: "arrow.up.right.square")) { _ in
            self.openSelectView(items: [metadata])
        }

        let rename = UIAction(title: NSLocalizedString("_rename_", comment: ""), image: UIImage(systemName: "pencil")) { _ in

            if let vcRename = UIStoryboard(name: "NCRenameFile", bundle: nil).instantiateInitialViewController() as? NCRenameFile {

                vcRename.metadata = metadata
                vcRename.imagePreview = image

                let popup = NCPopupViewController(contentController: vcRename, popupWidth: vcRename.width, popupHeight: vcRename.height)

                viewController.present(popup, animated: true)
            }
        }

        let favorite = UIAction(title: titleFavorite, image: NCUtility.shared.loadImage(named: "star.fill", color: NCBrandColor.shared.yellowFavorite)) { _ in

            NCNetworking.shared.favoriteMetadata(metadata) { error in
                if error != .success {
                    NCContentPresenter.shared.showError(error: error)
                }
            }
        }

        let deleteConfirmFile = UIAction(title: titleDeleteConfirmFile, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            NCNetworking.shared.deleteMetadata(metadata, onlyLocalCache: false) { error in
                if error != .success {
                    NCContentPresenter.shared.showError(error: error)
                }
            }
        }

        let deleteConfirmLocal = UIAction(title: NSLocalizedString("_remove_local_file_", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            NCNetworking.shared.deleteMetadata(metadata, onlyLocalCache: true) { _ in
            }
        }

        var delete = UIMenu(title: NSLocalizedString("_delete_file_", comment: ""), image: UIImage(systemName: "trash"), options: .destructive, children: [deleteConfirmLocal, deleteConfirmFile])

        if !enableDeleteLocal {
            delete = UIMenu(title: NSLocalizedString("_delete_file_", comment: ""), image: UIImage(systemName: "trash"), options: .destructive, children: [deleteConfirmFile])
        }

        if metadata.directory {
            delete = UIMenu(title: NSLocalizedString("_delete_folder_", comment: ""), image: UIImage(systemName: "trash"), options: .destructive, children: [deleteConfirmFile])
        }

        // ------ MENU -----

        // DIR

        guard !metadata.directory else {
            let submenu = UIMenu(title: "", options: .displayInline, children: [favorite, offline, rename, moveCopy, copyPath, delete])
            guard appDelegate.disableSharesView == false else { return submenu }
            return UIMenu(title: "", children: [detail, submenu])
        }

        // FILE

        var children: [UIMenuElement] = [offline, openIn, moveCopy, copy, copyPath]
        
        if !metadata.lock {
            // Workaround: PROPPATCH doesn't work (favorite)
            // https://github.com/nextcloud/files_lock/issues/68
            children.insert(favorite, at: 0)
            children.append(delete)
            children.insert(rename, at: 3)
        } else if enableDeleteLocal {
            children.append(deleteConfirmLocal)
        }

        if NCManageDatabase.shared.getCapabilitiesServerInt(account: appDelegate.account, elements: NCElementsJSON.shared.capabilitiesFilesLockVersion) >= 1, metadata.canUnlock(as: appDelegate.userId) {
            children.insert(lockUnlock, at: metadata.lock ? 0 : 1)
        }

        if (metadata.contentType != "image/svg+xml") && (metadata.classFile == NKCommon.typeClassFile.image.rawValue || metadata.classFile == NKCommon.typeClassFile.video.rawValue) {
            children.insert(save, at: 2)
        }

        if (metadata.contentType != "image/svg+xml") && (metadata.classFile == NKCommon.typeClassFile.image.rawValue) {
            children.insert(saveAsScan, at: 2)
        }

        if (metadata.contentType != "image/svg+xml") && (metadata.classFile == NKCommon.typeClassFile.image.rawValue || metadata.contentType == "application/pdf" || metadata.contentType == "com.adobe.pdf") {
            children.insert(print, at: 2)
        }

        if enableViewInFolder {
            children.insert(viewInFolder, at: children.count - 1)
        }

        if (!isFolderEncrypted && metadata.contentType != "image/gif" && metadata.contentType != "image/svg+xml") && (metadata.contentType == "com.adobe.pdf" || metadata.contentType == "application/pdf" || metadata.classFile == NKCommon.typeClassFile.image.rawValue) {
            children.insert(modify, at: children.count - 1)
        }

        let submenu = UIMenu(title: "", options: .displayInline, children: children)
        guard appDelegate.disableSharesView == false else { return submenu }
        return UIMenu(title: "", children: [detail, submenu])
    }
}

fileprivate extension tableMetadata {
    func toPasteBoardItem() -> [String: Any]? {
        // Get Data
        let fileUrl = URL(fileURLWithPath: CCUtility.getDirectoryProviderStorageOcId(ocId, fileNameView: fileNameView))
        guard CCUtility.fileProviderStorageExists(self),
              let data = try? Data(contentsOf: fileUrl),
              let unmanagedFileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension as CFString, nil)
        else { return nil }
        // Pasteboard item
        let fileUTI = unmanagedFileUTI.takeRetainedValue() as String
        return [fileUTI: data]
    }
}
