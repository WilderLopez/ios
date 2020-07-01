//
//  SharedUtils.swift
//  TinodiosDB
//
//  Copyright © 2020 Tinode. All rights reserved.
//

import Foundation
import SwiftKeychainWrapper
import SwiftWebSocket
import TinodeSDK

public class SharedUtils {
    static public let kTinodeHasRunBefore = "tinodeHasRunBefore"
    static public let kTinodePrefLastLogin = "tinodeLastLogin"
    static public let kTinodePrefReadReceipts = "tinodePrefSendReadReceipts"
    static public let kTinodePrefTypingNotifications = "tinodePrefTypingNoficications"

    static public let kAppDefaults = UserDefaults(suiteName: BaseDb.kAppGroupId)!
    static let kAppKeychain = KeychainWrapper(serviceName: "co.tinode.tinodios", accessGroup: BaseDb.kAppGroupId)

    // Keys we store in keychain.
    static let kTokenKey = "co.tinode.token"
    static let kTokenExpiryKey = "co.tinode.token_expiry"

    // Default connection params.
    #if DEBUG
        public static let kHostName = "127.0.0.1:6060" // localhost
        public static let kUseTLS = false
    #else
        public static let kHostName = "api.tinode.co" // production cluster
        public static let kUseTLS = true
    #endif

    public static func getSavedLoginUserName() -> String? {
        return SharedUtils.kAppDefaults.string(forKey: SharedUtils.kTinodePrefLastLogin)
    }
    private static func appDidRunBefore() -> Bool {
        guard SharedUtils.kAppDefaults.bool(forKey: SharedUtils.kTinodeHasRunBefore) else {
            // Clear the app keychain.
            SharedUtils.kAppKeychain.removeAllKeys()
            SharedUtils.kAppDefaults.set(true, forKey: SharedUtils.kTinodeHasRunBefore)
            return false
        }
        return true
    }

    public static func getAuthToken() -> String? {
        guard SharedUtils.appDidRunBefore() else { return nil }
        return SharedUtils.kAppKeychain.string(
            forKey: SharedUtils.kTokenKey, withAccessibility: .afterFirstUnlock)
    }

    public static func getAuthTokenExpiryDate() -> Date? {
         guard let expString = SharedUtils.kAppKeychain.string(
             forKey: SharedUtils.kTokenExpiryKey, withAccessibility: .afterFirstUnlock) else { return nil }
         return Formatter.rfc3339.date(from: expString)
    }

    public static func removeAuthToken() {
        SharedUtils.kAppDefaults.removeObject(forKey: SharedUtils.kTinodePrefLastLogin)
        SharedUtils.kAppKeychain.removeAllKeys()
    }

    public static func saveAuthToken(for userName: String, token: String?, expires expiryDate: Date?) {
        SharedUtils.kAppDefaults.set(userName, forKey: SharedUtils.kTinodePrefLastLogin)
        if let token = token, !token.isEmpty {
            if !SharedUtils.kAppKeychain.set(token, forKey: SharedUtils.kTokenKey, withAccessibility: .afterFirstUnlock) {
                BaseDb.log.error("Could not save auth token")
            }
            if let expiryDate = expiryDate {
                SharedUtils.kAppKeychain.set(
                    Formatter.rfc3339.string(from: expiryDate),
                    forKey: SharedUtils.kTokenExpiryKey,
                    withAccessibility: .afterFirstUnlock)
            } else {
                SharedUtils.kAppKeychain.removeObject(forKey: SharedUtils.kTokenExpiryKey)
            }
        }
    }

    public static func registerUserDefaults() {
        /// Here you can give default values to your UserDefault keys
        SharedUtils.kAppDefaults.register(defaults: [
            SharedUtils.kTinodePrefReadReceipts: true,
            SharedUtils.kTinodePrefTypingNotifications: true
        ])

        let (hostName, _, _) = ConnectionSettingsHelper.getConnectionSettings()
        if hostName == nil {
            // If hostname is nil, sync values to defaults
            ConnectionSettingsHelper.setHostName(Bundle.main.object(forInfoDictionaryKey: "HOST_NAME") as? String)
            ConnectionSettingsHelper.setUseTLS(Bundle.main.object(forInfoDictionaryKey: "USE_TLS") as? String)
        }
        if !SharedUtils.appDidRunBefore() {
            BaseDb.log.info("App started for the first time.")
        }
    }

    public static func connectAndLoginSync(using tinode: Tinode, inBackground bkg: Bool) -> Bool {
        guard let userName = SharedUtils.getSavedLoginUserName(), !userName.isEmpty else {
            BaseDb.log.error("Connect&Login Sync - missing user name")
            return false
        }
        guard let token = SharedUtils.getAuthToken(), !token.isEmpty else {
            BaseDb.log.error("Connect&Login Sync - missing auth token")
            return false
        }
        if let tokenExpires = SharedUtils.getAuthTokenExpiryDate(), tokenExpires < Date() {
            // Token has expired.
            // TODO: treat tokenExpires == nil as a reason to reject.
            BaseDb.log.error("Connect&Login Sync - auth token expired")
            return false
        }
        BaseDb.log.info("Connect&Login Sync - will attempt to login (user name: %@)", userName)
        var success = false
        do {
            tinode.setAutoLoginWithToken(token: token)
            // Tinode.connect() will automatically log in.
            let msg = try tinode.connectDefault(inBackground: bkg)?.getResult()
            if let code = msg?.ctrl?.code {
                // Assuming success by default.
                success = true
                switch code {
                case 0..<300:
                    BaseDb.log.info("Connect&Login Sync - login successful for: %@", tinode.myUid!)
                    if tinode.authToken != token {
                    SharedUtils.saveAuthToken(for: userName, token: tinode.authToken, expires: tinode.authTokenExpires)
                }
                case 409:
                    BaseDb.log.info("Connect&Login Sync - already authenticated.")
                case 500..<600:
                    BaseDb.log.error("Connect&Login Sync - server error on login: %d", code)
                default:
                    success = false
                }
            }
        } catch SwiftWebSocket.WebSocketError.network(let e)  {
            // No network connection.
            BaseDb.log.debug("Connect&Login Sync [network] - could not connect to Tinode: %@", e)
            success = true
        } catch {
            BaseDb.log.error("Connect&Login Sync - failed to automatically login to Tinode: %@", error.localizedDescription)
        }
        return success
    }

    // Synchronously fetches description for topic |topicName|
    // (and saves the description locally).
    @discardableResult
    public static func fetchDesc(using tinode: Tinode, for topicName: String) -> UIBackgroundFetchResult {
        guard tinode.isConnectionAuthenticated || SharedUtils.connectAndLoginSync(using: tinode, inBackground: true) else {
            return .failed
        }
        // If we have topic data, we are done.
        guard !tinode.isTopicTracked(topicName: topicName) else {
            return .noData
        }
        do {
            if let msg = try tinode.getMeta(topic: topicName, query: MsgGetMeta.desc()).getResult(),
                (msg.ctrl?.code ?? 500) < 300 {
                return .newData
            }
        } catch {
            BaseDb.log.error("Failed to fetch topic description for [%@]: %@", topicName, error.localizedDescription)
        }
        return .failed
    }

    // Synchronously connects to topic |topicName| and fetches its messages
    // if the last received message was prior to |seq|.
    @discardableResult
    public static func fetchData(using tinode: Tinode, for topicName: String, seq: Int) -> UIBackgroundFetchResult {
        guard tinode.isConnectionAuthenticated || SharedUtils.connectAndLoginSync(using: tinode, inBackground: true) else {
            return .failed
        }
        var topic: DefaultComTopic
        var builder: DefaultComTopic.MetaGetBuilder
        if !tinode.isTopicTracked(topicName: topicName) {
            // New topic. Create it.
            guard let t = tinode.newTopic(for: topicName) as? DefaultComTopic else {
                return .failed
            }
            topic = t
            builder = topic.metaGetBuilder().withDesc().withSub()
        } else {
            // Existing topic.
            guard let t = tinode.getTopic(topicName: topicName) as? DefaultComTopic else { return .failed }
            topic = t
            builder = topic.metaGetBuilder()
        }

        guard !topic.attached else {
            // No need to fetch: topic is already subscribed and got data through normal channel.
            return .noData
        }
        if (topic.recv ?? 0) >= seq {
            return .noData
        }
        if let msg = try? topic.subscribe(set: nil, get: builder.withLaterData(limit: 10).withDel().build()).getResult(), (msg.ctrl?.code ?? 500) < 300 {
            // Data messages are sent asynchronously right after ctrl message.
            // Give them 1 second to arrive - so we reply back with {note recv}.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
                if topic.attached {
                    topic.leave()
                }
            }
            return .newData
        }
        return .failed
    }
}

extension Tinode {
    public static func getConnectionParams() -> (String, Bool) {
        let (hostName, useTLS, _) = ConnectionSettingsHelper.getConnectionSettings()
        return (hostName ?? SharedUtils.kHostName, useTLS ?? SharedUtils.kUseTLS)
    }
    public func connectDefault(inBackground bkg: Bool) throws -> PromisedReply<ServerMessage>? {
        let (hostName, useTLS) = Tinode.getConnectionParams()
        BaseDb.log.debug("Connecting to %@, secure %@", hostName, useTLS ? "YES" : "NO")
        return try connect(to: hostName, useTLS: useTLS, inBackground: bkg)
    }
}
