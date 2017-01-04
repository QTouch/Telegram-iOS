import Foundation

final class MessageGloballyUniqueIdTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .int64)
    }
    
    private let sharedKey = ValueBoxKey(length: 8)
    private let sharedBuffer = WriteBuffer()
    
    private func key(_ id: Int64) -> ValueBoxKey {
        self.sharedKey.setInt64(0, value: id)
        return self.sharedKey
    }
    
    func set(_ globallyUniqueId: Int64, id: MessageId) {
        self.sharedBuffer.reset()
        var idPeerId: Int64 = id.peerId.toInt64()
        var idNamespace: Int32 = id.namespace
        var idId: Int32 = id.id
        self.sharedBuffer.write(&idPeerId, offset: 0, length: 8)
        self.sharedBuffer.write(&idNamespace, offset: 0, length: 4)
        self.sharedBuffer.write(&idId, offset: 0, length: 4)
        self.valueBox.set(self.table, key: self.key(globallyUniqueId), value: self.sharedBuffer)
    }
    
    func get(_ globallyUniqueId: Int64) -> MessageId? {
        if let value = self.valueBox.get(self.table, key: self.key(globallyUniqueId)) {
            var idPeerId: Int64 = 0
            var idNamespace: Int32 = 0
            var idId: Int32 = 0
            value.read(&idPeerId, offset: 0, length: 8)
            value.read(&idNamespace, offset: 0, length: 4)
            value.read(&idId, offset: 0, length: 4)
            return MessageId(peerId: PeerId(idPeerId), namespace: idNamespace, id: idId)
        }
        return nil
    }
    
    func remove(_ globallyUniqueId: Int64) {
        self.valueBox.remove(self.table, key: self.key(globallyUniqueId))
    }
}
