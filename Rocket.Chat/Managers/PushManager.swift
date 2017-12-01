//
//  PushManager.swift
//  Rocket.Chat
//
//  Created by Gradler Kim on 2017. 1. 23..
//  Copyright © 2017 Rocket.Chat. All rights reserved.
//

import Foundation
import SwiftyJSON
import RealmSwift
import UserNotifications

final class PushManager {
    static let delegate = UserNotificationCenterDelegate()

    static let kDeviceTokenKey = "deviceToken"
    static let kPushIdentifierKey = "pushIdentifier"

    static var lastNotificationRoomId: String?

    static func updatePushToken() {
        guard let deviceToken = getDeviceToken() else { return }
        guard let userIdentifier = AuthManager.isAuthenticated()?.userId else { return }

        let request = [
            "msg": "method",
            "method": "raix:push-update",
            "params": [[
                "id": getOrCreatePushId(),
                "userId": userIdentifier,
                "token": ["apn": deviceToken],
                "appName": Bundle.main.bundleIdentifier ?? "main",
                "metadata": [:]
                ]]
            ] as [String: Any]

        SocketManager.send(request)
    }

    static func updateUser(_ userIdentifier: String) {
        let request = [
            "msg": "method",
            "method": "raix:push-setuser",
            "userId": userIdentifier,
            "params": [getOrCreatePushId()]
            ] as [String: Any]

        SocketManager.send(request)
    }

    fileprivate static func getOrCreatePushId() -> String {
        guard let pushId = UserDefaults.standard.string(forKey: kPushIdentifierKey) else {
            let randomId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            UserDefaults.standard.set(randomId, forKey: kPushIdentifierKey)
            return randomId
        }

        return pushId
    }

    fileprivate static func getDeviceToken() -> String? {
        guard let deviceToken = UserDefaults.standard.string(forKey: kDeviceTokenKey) else {
            return nil
        }

        return deviceToken
    }

}

// MARK: Handle Notifications

struct PushNotification {
    let host: String
    let username: String
    let roomId: String
    let roomType: SubscriptionType

    init?(raw: [AnyHashable: Any]) {
        guard
            let json = JSON(parseJSON: (raw["ejson"] as? String) ?? "").dictionary,
            let host = json["host"]?.string,
            let username = json["sender"]?["username"].string,
            let roomType = json["type"]?.string,
            let roomId = json["rid"]?.string
            else {
                return nil
        }

        self.host = host
        self.username = username
        self.roomId = roomId
        self.roomType = SubscriptionType(rawValue: roomType) ?? .group
    }
}

// MARK: Categories

extension UNNotificationAction {
    static var reply: UNNotificationAction {
        return UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Repla",
            options: .authenticationRequired
        )
    }
}

extension UNNotificationCategory {
    static var message: UNNotificationCategory {
        return UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [.reply],
            intentIdentifiers: [],
            options: []
        )
    }

    static var messageNoReply: UNNotificationCategory {
        return UNNotificationCategory(
            identifier: "REPLY",
            actions: [.reply],
            intentIdentifiers: [],
            options: []
        )
    }
}

extension PushManager {
    static func setupNotificationCenter() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = PushManager.delegate
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { (_, _) in }
        notificationCenter.setNotificationCategories([.message, .messageNoReply])
    }

    @discardableResult
    static func handleNotification(raw: [AnyHashable: Any], reply: String? = nil) -> Bool {
        guard let notification = PushNotification(raw: raw) else { return false }
        return handleNotification(notification, reply: reply)
    }

    fileprivate static func hostToServerUrl(_ host: String) -> String? {
        return URL(string: host)?.socketURL()?.absoluteString
    }

    @discardableResult
    static func handleNotification(_ notification: PushNotification, reply: String? = nil) -> Bool {
        guard
            let serverUrl = hostToServerUrl(notification.host),
            let index = DatabaseManager.serverIndexForUrl(serverUrl)
            else {
                return false
        }

        // side effect: needed for Subscription.notificationSubscription()
        lastNotificationRoomId = notification.roomId
        guard let subscription = Subscription.notificationSubscription() else { return false }

        if index != DatabaseManager.selectedIndex {
            AppManager.changeSelectedServer(index: index)
        } else {
            ChatViewController.shared?.subscription = subscription
        }

        if let reply = reply {
            let appendage = subscription.type == .directMessage ? "" : " @\(notification.username)"

            let message = Message()
            message.subscription = subscription
            message.text = "\(reply)\(appendage)"

            let backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
            API.shared.fetch(PostMessageRequest(message: message), { _ in
                UIApplication.shared.endBackgroundTask(backgroundTask)
            })
        }

        return true
    }
}

class UserNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        PushManager.handleNotification(raw: response.notification.request.content.userInfo,
                                       reply: (response as? UNTextInputNotificationResponse)?.userText)
    }
}

