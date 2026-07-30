import Foundation

struct PendingUICommand<Command: Equatable>: Equatable {
  let sequence: UInt64
  let command: Command
}

struct UICommandQueue<Command: Equatable> {
  private(set) var nextSequence: UInt64 = 0
  private(set) var pendingCommand: PendingUICommand<Command>?

  @discardableResult
  mutating func queue(_ command: Command) -> PendingUICommand<Command> {
    nextSequence &+= 1
    let pending = PendingUICommand(sequence: nextSequence, command: command)
    pendingCommand = pending
    return pending
  }

  mutating func complete(_ pending: PendingUICommand<Command>) {
    guard pendingCommand == pending else { return }
    pendingCommand = nil
  }
}

enum MessagesUICommand: Equatable {
  case setSort(MessageSortDescriptor)
  case setFilter(MessageFilter, Bool)
  case resetFilters
}

enum RecoveryUICommand: Equatable {
  case setSeverity(RecoverySeverity, Bool)
  case setIssueKind(RecoveryIssueKind?)
  case resetFilters
}

enum SourceUICommand: Equatable {
  case addSource(MailSourceKind)
}

enum IndexUICommand: Equatable {
  case build
  case rebuild
}
