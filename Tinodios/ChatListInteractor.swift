//
//  ChatListInteractor.swift
//  Tinodios
//
//  Copyright © 2018 Tinode. All rights reserved.
//

import Foundation
import UIKit
import TinodeSDK

protocol ChatListBusinessLogic: class {
    func loadAndPresentTopics()
    func attachToMeTopic()
    func updateChat(_ name: String)
    func setup()
    func cleanup()
    func deleteTopic(_ name: String)
}

protocol ChatListDataStore: class {
    var topics: [DefaultComTopic]? { get set }
}

class ChatListInteractor: ChatListBusinessLogic, ChatListDataStore {
    private class MeListener: DefaultMeTopic.Listener {
        weak var interactor: ChatListBusinessLogic?
        //public init() {}
        override func onInfo(info: MsgServerInfo) {
            print("Contacts got onInfo update \(String(describing: info.what))")
        }
        override func onPres(pres: MsgServerPres) {
            if pres.what == "msg" || pres.what == "off" || pres.what == "on" {
                if let name = pres.src {
                    interactor?.updateChat(name)
                }
            }
        }
        override func onMetaSub(sub: Subscription<VCard, PrivateType>) {
            // TODO: sub.pub?.constructBitmap()
            print("on meta sub")
            if Tinode.topicTypeByName(name: sub.topic) == .p2p {
                ContactsManager.default.processSubscription(sub: sub)
            }
        }
        override func onMetaDesc(desc: Description<VCard, PrivateType>) {
            // TODO: desc.pub?.constructBitmap()
            print("on meta desc")
        }
        override func onSubsUpdated() {
            // datasetChanged()
            print("on subs updated")
            interactor?.loadAndPresentTopics()
        }
        override func onContUpdate(sub: Subscription<VCard, PrivateType>) {
            // Method makes no sense in context of MeTopic.
            // throw new UnsupportedOperationException();
        }
    }
    private class ChatEventListener: UiTinodeEventListener {
        private weak var interactor: ChatListBusinessLogic?
        init(interactor: ChatListBusinessLogic?, connected: Bool) {
            super.init(connected: connected)
            self.interactor = interactor
        }
        override func onLogin(code: Int, text: String) {
            super.onLogin(code: code, text: text)
            self.interactor?.attachToMeTopic()
        }
        override func onDisconnect(byServer: Bool, code: Int, reason: String) {
            // TODO: update presence, etc.
        }
    }

    var presenter: ChatListPresentationLogic?
    var router: ChatListRoutingLogic?
    var topics: [DefaultComTopic]?
    private var meListener: MeListener? = nil
    private var meTopic: DefaultMeTopic? = nil
    private var tinodeEventListener: ChatEventListener? = nil

    func attachToMeTopic() {
        let tinode = Cache.getTinode()
        do {
            try UiUtils.attachToMeTopic(meListener: self.meListener)?.then(
                onSuccess: { [weak self] msg in
                    self?.loadAndPresentTopics()
                    self?.meTopic = tinode.getMeTopic()
                    return nil
                }, onFailure: { [weak self] err in
                    print("err = ")
                    if let e = err as? TinodeError, case .serverResponseError(let code, _, _) = e {
                        if code == 404 {
                            tinode.logout()
                            self?.router?.routeToLogin()
                        }
                    }
                    return nil
                })
        } catch {
            tinode.logout()
            self.router?.routeToLogin()
        }
    }
    func setup() {
        meListener = MeListener()
        self.meListener?.interactor = self
        let tinode = Cache.getTinode()
        self.tinodeEventListener = ChatEventListener(
            interactor: self, connected: tinode.isConnected)
        tinode.listener = self.tinodeEventListener
    }
    func cleanup() {
        self.meTopic?.listener = nil
        Cache.getTinode().listener = nil
        if self.meTopic?.attached ?? false {
            self.meTopic?.leave()
        }
    }
    func loadAndPresentTopics() {
        self.topics = Cache.getTinode().getFilteredTopics(filter: {(topic: TopicProto) in
            return topic.topicType.matches(TopicType.user)
        })?.map {
            // Must succeed.
            $0 as! DefaultComTopic
        }
        self.presenter?.presentTopics(self.topics ?? [])
    }

    func updateChat(_ name: String) {
        self.presenter?.updateChat(name)
    }

    func deleteTopic(_ name: String) {
        Cache.getTinode().delTopic(name)
    }

}
