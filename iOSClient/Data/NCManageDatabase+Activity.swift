//
//  NCManageDatabase+Activity.swift
//  Nextcloud
//
//  Created by Henrik Storch on 30.11.21.
//  Copyright © 2021 Marino Faggiana. All rights reserved.
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

import Foundation
import RealmSwift
import NextcloudKit
import SwiftyJSON

extension NCManageDatabase {
    
    @objc func addActivity(_ activities: [NKActivity], account: String) {

        let realm = try! Realm()

        do {
            try realm.write {

                for activity in activities {

                    let addObjectActivity = tableActivity()

                    addObjectActivity.account = account
                    addObjectActivity.idActivity = activity.idActivity
                    addObjectActivity.idPrimaryKey = account + String(activity.idActivity)
                    addObjectActivity.date = activity.date
                    addObjectActivity.app = activity.app
                    addObjectActivity.type = activity.type
                    addObjectActivity.user = activity.user
                    addObjectActivity.subject = activity.subject

                    if let subject_rich = activity.subject_rich,
                       let json = JSON(subject_rich).array {

                        addObjectActivity.subjectRich = json[0].stringValue
                        if json.count > 1,
                           let dict = json[1].dictionary {

                            for (key, value) in dict {
                                let addObjectActivitySubjectRich = tableActivitySubjectRich()
                                let dict = value as JSON
                                addObjectActivitySubjectRich.account = account

                                if dict["id"].intValue > 0 {
                                    addObjectActivitySubjectRich.id = String(dict["id"].intValue)
                                } else {
                                    addObjectActivitySubjectRich.id = dict["id"].stringValue
                                }

                                addObjectActivitySubjectRich.name = dict["name"].stringValue
                                addObjectActivitySubjectRich.idPrimaryKey = account
                                + String(activity.idActivity)
                                + addObjectActivitySubjectRich.id
                                + addObjectActivitySubjectRich.name

                                addObjectActivitySubjectRich.key = key
                                addObjectActivitySubjectRich.idActivity = activity.idActivity
                                addObjectActivitySubjectRich.link = dict["link"].stringValue
                                addObjectActivitySubjectRich.path = dict["path"].stringValue
                                addObjectActivitySubjectRich.type = dict["type"].stringValue

                                realm.add(addObjectActivitySubjectRich, update: .all)
                            }
                        }
                    }

                    if let previews = activity.previews,
                       let json = JSON(previews).array {
                        for preview in json {
                            let addObjectActivityPreview = tableActivityPreview()

                            addObjectActivityPreview.account = account
                            addObjectActivityPreview.idActivity = activity.idActivity
                            addObjectActivityPreview.fileId = preview["fileId"].intValue
                            addObjectActivityPreview.filename = preview["filename"].stringValue
                            addObjectActivityPreview.idPrimaryKey = account + String(activity.idActivity) + String(addObjectActivityPreview.fileId)
                            addObjectActivityPreview.source = preview["source"].stringValue
                            addObjectActivityPreview.link = preview["link"].stringValue
                            addObjectActivityPreview.mimeType = preview["mimeType"].stringValue
                            addObjectActivityPreview.view = preview["view"].stringValue
                            addObjectActivityPreview.isMimeTypeIcon = preview["isMimeTypeIcon"].boolValue

                            realm.add(addObjectActivityPreview, update: .all)
                        }
                    }

                    addObjectActivity.icon = activity.icon
                    addObjectActivity.link = activity.link
                    addObjectActivity.message = activity.message
                    addObjectActivity.objectType = activity.object_type
                    addObjectActivity.objectId = activity.object_id
                    addObjectActivity.objectName = activity.object_name

                    realm.add(addObjectActivity, update: .all)
                }
            }
        } catch let error {
            NKCommon.shared.writeLog("Could not write to database: \(error)")
        }
    }

    func getActivity(predicate: NSPredicate, filterFileId: String?) -> (all: [tableActivity], filter: [tableActivity]) {

        let realm = try! Realm()

        let results = realm.objects(tableActivity.self).filter(predicate).sorted(byKeyPath: "idActivity", ascending: false)
        let allActivity = Array(results.map(tableActivity.init))
        guard let filterFileId = filterFileId else {
            return (all: allActivity, filter: allActivity)
        }

        // comments are loaded seperately, see NCManageDatabase.getComments
        let filtered = allActivity.filter({ String($0.objectId) == filterFileId && $0.type != "comments" })
        return (all: allActivity, filter: filtered)
    }

    @objc func getActivitySubjectRich(account: String, idActivity: Int, key: String) -> tableActivitySubjectRich? {

        let realm = try! Realm()

        let results = realm.objects(tableActivitySubjectRich.self).filter("account == %@ && idActivity == %d && key == %@", account, idActivity, key).first

        return results.map { tableActivitySubjectRich.init(value: $0) }
    }

    @objc func getActivitySubjectRich(account: String, idActivity: Int, id: String) -> tableActivitySubjectRich? {

        let realm = try! Realm()

        let results = realm.objects(tableActivitySubjectRich.self).filter("account == %@ && idActivity == %d && id == %@", account, idActivity, id)
        var activitySubjectRich = results.first
        if results.count == 2 {
            for result in results {
                if result.key == "newfile" {
                    activitySubjectRich = result
                }
            }
        }

        return activitySubjectRich.map { tableActivitySubjectRich.init(value: $0) }
    }

    @objc func getActivityPreview(account: String, idActivity: Int, orderKeysId: [String]) -> [tableActivityPreview] {

        let realm = try! Realm()

        var results: [tableActivityPreview] = []

        for id in orderKeysId {
            if let result = realm.objects(tableActivityPreview.self).filter("account == %@ && idActivity == %d && fileId == %d", account, idActivity, Int(id) ?? 0).first {
                results.append(result)
            }
        }

        return results
    }

   func updateLatestActivityId(activityFirstKnown: Int, activityLastGiven: Int, account: String) {
        let realm = try! Realm()

        do {
            try realm.write {
                let newRecentActivity = tableActivityLatestId()
                newRecentActivity.activityFirstKnown = activityFirstKnown
                newRecentActivity.activityLastGiven = activityLastGiven
                newRecentActivity.account = account
                realm.add(newRecentActivity, update: .all)
            }
        } catch {
            NKCommon.shared.writeLog("Could not write to database: \(error)")
        }
    }

    func getLatestActivityId(account: String) -> tableActivityLatestId? {

        let realm = try! Realm()
        return realm.objects(tableActivityLatestId.self).filter("account == %@", account).first
    }
    
    // MARK: -
    // MARK: Table Comments

    @objc func addComments(_ comments: [NKComments], account: String, objectId: String) {

        let realm = try! Realm()

        do {
            try realm.write {

                let results = realm.objects(tableComments.self).filter("account == %@ AND objectId == %@", account, objectId)
                realm.delete(results)

                for comment in comments {

                    let object = tableComments()

                    object.account = account
                    object.actorDisplayName = comment.actorDisplayName
                    object.actorId = comment.actorId
                    object.actorType = comment.actorType
                    object.creationDateTime = comment.creationDateTime as NSDate
                    object.isUnread = comment.isUnread
                    object.message = comment.message
                    object.messageId = comment.messageId
                    object.objectId = comment.objectId
                    object.objectType = comment.objectType
                    object.path = comment.path
                    object.verb = comment.verb

                    realm.add(object, update: .all)
                }
            }
        } catch let error {
            NKCommon.shared.writeLog("Could not write to database: \(error)")
        }
    }

    @objc func getComments(account: String, objectId: String) -> [tableComments] {

        let realm = try! Realm()

        let results = realm.objects(tableComments.self).filter("account == %@ AND objectId == %@", account, objectId).sorted(byKeyPath: "creationDateTime", ascending: false)

        return Array(results.map(tableComments.init))
    }
}
