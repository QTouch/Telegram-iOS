import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit
import Postbox

private struct FetchManagerLocationEntryId: Hashable {
    let location: FetchManagerLocation
    let resourceId: MediaResourceId
    let locationKey: FetchManagerLocationKey
    
    static func ==(lhs: FetchManagerLocationEntryId, rhs: FetchManagerLocationEntryId) -> Bool {
        if lhs.location != rhs.location {
            return false
        }
        if !lhs.resourceId.isEqual(to: rhs.resourceId) {
            return false
        }
        if lhs.locationKey != rhs.locationKey {
            return false
        }
        return true
    }
    
    var hashValue: Int {
        return self.resourceId.hashValue &* 31 &+ self.locationKey.hashValue
    }
}

private final class FetchManagerLocationEntry {
    let id: FetchManagerLocationEntryId
    let episode: Int32
    let mediaReference: AnyMediaReference?
    let resourceReference: MediaResourceReference
    let statsCategory: MediaResourceStatsCategory
    
    var userInitiated: Bool = false
    var storeToDownloadsPeerType: AutomaticMediaDownloadPeerType?
    var referenceCount: Int32 = 0
    var elevatedPriorityReferenceCount: Int32 = 0
    var userInitiatedPriorityIndices: [Int32] = []
    
    var priorityKey: FetchManagerPriorityKey? {
        if self.referenceCount > 0 || self.userInitiated {
            return FetchManagerPriorityKey(locationKey: self.id.locationKey, hasElevatedPriority: self.elevatedPriorityReferenceCount > 0, userInitiatedPriority: userInitiatedPriorityIndices.last)
        } else {
            return nil
        }
    }
    
    init(id: FetchManagerLocationEntryId, episode: Int32, mediaReference: AnyMediaReference?, resourceReference: MediaResourceReference, statsCategory: MediaResourceStatsCategory) {
        self.id = id
        self.episode = episode
        self.mediaReference = mediaReference
        self.resourceReference = resourceReference
        self.statsCategory = statsCategory
    }
}

private final class FetchManagerActiveContext {
    let userInitiated: Bool
    var disposable: Disposable?
    
    init(userInitiated: Bool) {
        self.userInitiated = userInitiated
    }
}

private final class FetchManagerStatusContext {
    var disposable: Disposable?
    var originalStatus: MediaResourceStatus?
    var subscribers = Bag<(MediaResourceStatus) -> Void>()
    
    var hasEntry = false
    
    var isEmpty: Bool {
        return !self.hasEntry && self.subscribers.isEmpty
    }
    
    var combinedStatus: MediaResourceStatus? {
        if let originalStatus = self.originalStatus {
            if originalStatus == .Remote && self.hasEntry {
                return .Fetching(isActive: false, progress: 0.0)
            } else {
                return originalStatus
            }
        } else {
            return nil
        }
    }
}

private final class FetchManagerCategoryContext {
    private let postbox: Postbox
    private let storeManager: DownloadedMediaStoreManager?
    private let entryCompleted: (FetchManagerLocationEntryId) -> Void
    private let activeEntriesUpdated: () -> Void
    
    private var topEntryIdAndPriority: (FetchManagerLocationEntryId, FetchManagerPriorityKey)?
    private var entries: [FetchManagerLocationEntryId: FetchManagerLocationEntry] = [:]
    
    private var activeContexts: [FetchManagerLocationEntryId: FetchManagerActiveContext] = [:]
    private var statusContexts: [FetchManagerLocationEntryId: FetchManagerStatusContext] = [:]
    
    var hasActiveUserInitiatedEntries: Bool {
        for (_, context) in self.activeContexts {
            if context.userInitiated {
                return true
            }
        }
        return false
    }
    
    init(postbox: Postbox, storeManager: DownloadedMediaStoreManager?, entryCompleted: @escaping (FetchManagerLocationEntryId) -> Void, activeEntriesUpdated: @escaping () -> Void) {
        self.postbox = postbox
        self.storeManager = storeManager
        self.entryCompleted = entryCompleted
        self.activeEntriesUpdated = activeEntriesUpdated
    }
    
    func withEntry(id: FetchManagerLocationEntryId, takeNew: (() -> (AnyMediaReference?, MediaResourceReference, MediaResourceStatsCategory, Int32))?, _ f: (FetchManagerLocationEntry) -> Void) {
        let entry: FetchManagerLocationEntry
        let previousPriorityKey: FetchManagerPriorityKey?
        
        if let current = self.entries[id] {
            entry = current
            previousPriorityKey = entry.priorityKey
        } else if let takeNew = takeNew {
            previousPriorityKey = nil
            let (mediaReference, resourceReference, statsCategory, episode) = takeNew()
            entry = FetchManagerLocationEntry(id: id, episode: episode, mediaReference: mediaReference, resourceReference: resourceReference, statsCategory: statsCategory)
            self.entries[id] = entry
        } else {
            return
        }
        
        f(entry)
        
        var removedEntries = false
        
        let updatedPriorityKey = entry.priorityKey
        if previousPriorityKey != updatedPriorityKey {
            if let updatedPriorityKey = updatedPriorityKey {
                if let (topId, topPriority) = self.topEntryIdAndPriority {
                    if updatedPriorityKey < topPriority {
                        self.topEntryIdAndPriority = (entry.id, updatedPriorityKey)
                    } else if updatedPriorityKey > topPriority && topId == id {
                        self.topEntryIdAndPriority = nil
                    }
                } else {
                    self.topEntryIdAndPriority = (entry.id, updatedPriorityKey)
                }
            } else {
                if self.topEntryIdAndPriority?.0 == id {
                    self.topEntryIdAndPriority = nil
                }
                self.entries.removeValue(forKey: id)
                removedEntries = true
            }
        }
        
        var activeContextsUpdated = false
        
        if self.maybeFindAndActivateNewTopEntry() {
            activeContextsUpdated = true
        }
        
        if removedEntries {
            var removedIds: [FetchManagerLocationEntryId] = []
            for (entryId, activeContext) in self.activeContexts {
                if self.entries[entryId] == nil {
                    removedIds.append(entryId)
                    activeContext.disposable?.dispose()
                }
            }
            for entryId in removedIds {
                self.activeContexts.removeValue(forKey: entryId)
                activeContextsUpdated = true
            }
        }
        
        if let activeContext = self.activeContexts[id] {
            if activeContext.disposable == nil {
                if let entry = self.entries[id] {
                    let entryCompleted = self.entryCompleted
                    let storeManager = self.storeManager
                    activeContext.disposable = (fetchedMediaResource(postbox: self.postbox, reference: entry.resourceReference, statsCategory: entry.statsCategory, reportResultStatus: true, continueInBackground: entry.userInitiated)
                    |> mapToSignal { type -> Signal<FetchResourceSourceType, NoError> in
                        if let storeManager = storeManager, let mediaReference = entry.mediaReference, case .remote = type, let peerType = entry.storeToDownloadsPeerType {
                            return storeDownloadedMedia(storeManager: storeManager, media: mediaReference, peerType: peerType)
                            |> mapToSignal { _ -> Signal<FetchResourceSourceType, NoError> in
                                return .complete()
                            }
                            |> then(.single(type))
                        }
                        return .single(type)
                    }
                    |> deliverOnMainQueue).start(next: { _ in
                        entryCompleted(id)
                    })
                } else {
                    assertionFailure()
                }
            }
        }
        
        if (previousPriorityKey != nil) != (updatedPriorityKey != nil) {
            if let statusContext = self.statusContexts[id] {
                if updatedPriorityKey != nil {
                    if !statusContext.hasEntry {
                        let previousStatus = statusContext.combinedStatus
                        statusContext.hasEntry = true
                        if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                            for f in statusContext.subscribers.copyItems() {
                                f(combinedStatus)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                } else {
                    if statusContext.hasEntry {
                        let previousStatus = statusContext.combinedStatus
                        statusContext.hasEntry = false
                        if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                            for f in statusContext.subscribers.copyItems() {
                                f(combinedStatus)
                            }
                        }
                    } else {
                        assertionFailure()
                    }
                }
            }
        }
        
        if activeContextsUpdated {
            self.activeEntriesUpdated()
        }
    }
    
    func maybeFindAndActivateNewTopEntry() -> Bool {
        if self.topEntryIdAndPriority == nil && !self.entries.isEmpty {
            var topEntryIdAndPriority: (FetchManagerLocationEntryId, FetchManagerPriorityKey)?
            for (id, entry) in self.entries {
                if let entryPriorityKey = entry.priorityKey {
                    if let (_, topKey) = topEntryIdAndPriority {
                        if entryPriorityKey < topKey {
                            topEntryIdAndPriority = (id, entryPriorityKey)
                        }
                    } else {
                        topEntryIdAndPriority = (id, entryPriorityKey)
                    }
                } else {
                    assertionFailure()
                }
            }
            
            self.topEntryIdAndPriority = topEntryIdAndPriority
        }
        
        if let topEntryId = self.topEntryIdAndPriority?.0, self.activeContexts[topEntryId] == nil {
            if let entry = self.entries[topEntryId] {
                let activeContext = FetchManagerActiveContext(userInitiated: entry.userInitiated)
                self.activeContexts[topEntryId] = activeContext
                let entryCompleted = self.entryCompleted
                let storeManager = self.storeManager
                activeContext.disposable = (fetchedMediaResource(postbox: self.postbox, reference: entry.resourceReference, statsCategory: entry.statsCategory, reportResultStatus: true, continueInBackground: entry.userInitiated)
                |> mapToSignal { type -> Signal<FetchResourceSourceType, NoError> in
                    if let storeManager = storeManager, let mediaReference = entry.mediaReference, case .remote = type, let peerType = entry.storeToDownloadsPeerType {
                        return storeDownloadedMedia(storeManager: storeManager, media: mediaReference, peerType: peerType)
                        |> mapToSignal { _ -> Signal<FetchResourceSourceType, NoError> in
                            return .complete()
                        }
                        |> then(.single(type))
                    }
                    return .single(type)
                }
                |> deliverOnMainQueue).start(next: { _ in
                    entryCompleted(topEntryId)
                    
                })
                return true
            } else {
                assertionFailure()
                return false
            }
        } else {
            return false
        }
    }
    
    func cancelEntry(_ entryId: FetchManagerLocationEntryId) {
        var id: FetchManagerLocationEntryId = entryId
        if self.entries[id] == nil {
            for (key, _) in self.entries {
                if key.resourceId.isEqual(to: entryId.resourceId) {
                    id = key
                    break
                }
            }
        }
        
        if let _ = self.entries[id] {
            self.entries.removeValue(forKey: id)
            
            if let statusContext = self.statusContexts[id] {
                if statusContext.hasEntry {
                    let previousStatus = statusContext.combinedStatus
                    statusContext.hasEntry = false
                    if let combinedStatus = statusContext.combinedStatus, combinedStatus != previousStatus {
                        for f in statusContext.subscribers.copyItems() {
                            f(combinedStatus)
                        }
                    }
                } else {
                    assertionFailure()
                }
            }
        }
        
        var activeContextsUpdated = false
        
        if let activeContext = self.activeContexts[id] {
            activeContext.disposable?.dispose()
            activeContext.disposable = nil
            self.activeContexts.removeValue(forKey: id)
            activeContextsUpdated = true
        }
        
        if self.topEntryIdAndPriority?.0 == id {
            self.topEntryIdAndPriority = nil
        }
        
        if self.maybeFindAndActivateNewTopEntry() {
            activeContextsUpdated = true
        }
        
        if activeContextsUpdated {
            self.activeEntriesUpdated()
        }
    }
    
    func withFetchStatusContext(_ id: FetchManagerLocationEntryId, _ f: (FetchManagerStatusContext) -> Void) {
        let statusContext: FetchManagerStatusContext
        if let current = self.statusContexts[id] {
            statusContext = current
        } else {
            statusContext = FetchManagerStatusContext()
            self.statusContexts[id] = statusContext
            if self.entries[id] != nil {
                statusContext.hasEntry = true
            }
        }
        
        f(statusContext)
        
        if statusContext.isEmpty {
            statusContext.disposable?.dispose()
            self.statusContexts.removeValue(forKey: id)
        }
    }
    
    var isEmpty: Bool {
        return self.entries.isEmpty && self.activeContexts.isEmpty && self.statusContexts.isEmpty
    }
}

public final class FetchManager {
    private let queue = Queue.mainQueue()
    private let postbox: Postbox
    private let storeManager: DownloadedMediaStoreManager?
    private var nextEpisodeId: Int32 = 0
    private var nextUserInitiatedIndex: Int32 = 0
    
    private var categoryContexts: [FetchManagerCategory: FetchManagerCategoryContext] = [:]
    
    private let hasUserInitiatedEntriesValue = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var hasUserInitiatedEntries: Signal<Bool, NoError> {
        return self.hasUserInitiatedEntriesValue.get()
    }
    
    init(postbox: Postbox, storeManager: DownloadedMediaStoreManager?) {
        self.postbox = postbox
        self.storeManager = storeManager
    }
    
    private func takeNextEpisodeId() -> Int32 {
        let value = self.nextEpisodeId
        self.nextEpisodeId += 1
        return value
    }
    
    private func takeNextUserInitiatedIndex() -> Int32 {
        let value = self.nextUserInitiatedIndex
        self.nextUserInitiatedIndex += 1
        return value
    }
    
    private func withCategoryContext(_ key: FetchManagerCategory, _ f: (FetchManagerCategoryContext) -> Void) {
        assert(self.queue.isCurrent())
        let context: FetchManagerCategoryContext
        if let current = self.categoryContexts[key] {
            context = current
        } else {
            let queue = self.queue
            context = FetchManagerCategoryContext(postbox: self.postbox, storeManager: self.storeManager, entryCompleted: { [weak self] id in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.withCategoryContext(key, { context in
                        context.cancelEntry(id)
                    })
                }
            }, activeEntriesUpdated: { [weak self] in
                queue.async {
                    guard let strongSelf = self else {
                        return
                    }
                    var hasActiveUserInitiatedEntries = false
                    for (_, context) in strongSelf.categoryContexts {
                        if context.hasActiveUserInitiatedEntries {
                            hasActiveUserInitiatedEntries = true
                            break
                        }
                    }
                    strongSelf.hasUserInitiatedEntriesValue.set(hasActiveUserInitiatedEntries)
                }
            })
            self.categoryContexts[key] = context
        }
        
        f(context)
        
        if context.isEmpty {
            self.categoryContexts.removeValue(forKey: key)
        }
    }
    
    func interactivelyFetched(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, mediaReference: AnyMediaReference?, resourceReference: MediaResourceReference, statsCategory: MediaResourceStatsCategory, elevatedPriority: Bool, userInitiated: Bool, storeToDownloadsPeerType: AutomaticMediaDownloadPeerType? = nil) -> Signal<Void, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            if let strongSelf = self {
                var assignedEpisode: Int32?
                var assignedUserInitiatedIndex: Int32?
                
                strongSelf.withCategoryContext(category, { context in
                    context.withEntry(id: FetchManagerLocationEntryId(location: location, resourceId: resourceReference.resource.id, locationKey: locationKey), takeNew: { return (mediaReference, resourceReference, statsCategory, strongSelf.takeNextEpisodeId()) }, { entry in
                        assignedEpisode = entry.episode
                        if userInitiated {
                            entry.userInitiated = true
                        }
                        if let peerType = storeToDownloadsPeerType {
                            entry.storeToDownloadsPeerType = peerType
                        }
                        entry.referenceCount += 1
                        if elevatedPriority {
                            entry.elevatedPriorityReferenceCount += 1
                        }
                        if userInitiated {
                            let userInitiatedIndex = strongSelf.takeNextUserInitiatedIndex()
                            assignedUserInitiatedIndex = userInitiatedIndex
                            entry.userInitiatedPriorityIndices.append(userInitiatedIndex)
                            entry.userInitiatedPriorityIndices.sort()
                        }
                    })
                })
                
                return ActionDisposable {
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.withCategoryContext(category, { context in
                                context.withEntry(id: FetchManagerLocationEntryId(location: location, resourceId: resourceReference.resource.id, locationKey: locationKey), takeNew: nil, { entry in
                                    if entry.episode == assignedEpisode {
                                        entry.referenceCount -= 1
                                        assert(entry.referenceCount >= 0)
                                        if elevatedPriority {
                                            entry.elevatedPriorityReferenceCount -= 1
                                            assert(entry.elevatedPriorityReferenceCount >= 0)
                                        }
                                        if let userInitiatedIndex = assignedUserInitiatedIndex {
                                            if let index = entry.userInitiatedPriorityIndices.index(of: userInitiatedIndex) {
                                                entry.userInitiatedPriorityIndices.remove(at: index)
                                            } else {
                                                assertionFailure()
                                            }
                                        }
                                    }
                                })
                            })
                        }
                    }
                }
            } else {
                return EmptyDisposable
            }
        } |> runOn(self.queue)
    }
    
    func cancelInteractiveFetches(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, resource: MediaResource) {
        self.queue.async {
            self.withCategoryContext(category, { context in
                context.cancelEntry(FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey))
            })
            
            self.postbox.mediaBox.cancelInteractiveResourceFetch(resource)
        }
    }
    
    func fetchStatus(category: FetchManagerCategory, location: FetchManagerLocation, locationKey: FetchManagerLocationKey, resource: MediaResource) -> Signal<MediaResourceStatus, NoError> {
        let queue = self.queue
        return Signal { [weak self] subscriber in
            if let strongSelf = self {
                var assignedIndex: Int?
                
                let entryId = FetchManagerLocationEntryId(location: location, resourceId: resource.id, locationKey: locationKey)
                strongSelf.withCategoryContext(category, { context in
                    context.withFetchStatusContext(entryId, { statusContext in
                        assignedIndex = statusContext.subscribers.add({ status in
                            subscriber.putNext(status)
                            if case .Local = status {
                                subscriber.putCompletion()
                            }
                        })
                        if let status = statusContext.combinedStatus {
                            subscriber.putNext(status)
                            if case .Local = status {
                                subscriber.putCompletion()
                            }
                        }
                        if statusContext.disposable == nil {
                            statusContext.disposable = strongSelf.postbox.mediaBox.resourceStatus(resource).start(next: { status in
                                queue.async {
                                    if let strongSelf = self {
                                        strongSelf.withCategoryContext(category, { context in
                                            context.withFetchStatusContext(entryId, { statusContext in
                                                statusContext.originalStatus = status
                                                if let combinedStatus = statusContext.combinedStatus {
                                                    for f in statusContext.subscribers.copyItems() {
                                                        f(combinedStatus)
                                                    }
                                                }
                                            })
                                        })
                                    }
                                }
                            })
                        }
                    })
                })
                
                return ActionDisposable {
                    queue.async {
                        if let strongSelf = self {
                            strongSelf.withCategoryContext(category, { context in
                                context.withFetchStatusContext(entryId, { statusContext in
                                    if let assignedIndex = assignedIndex {
                                        statusContext.subscribers.remove(assignedIndex)
                                    }
                                })
                            })
                        }
                    }
                }
            } else {
                return EmptyDisposable
            }
        } |> runOn(self.queue)
    }
}
