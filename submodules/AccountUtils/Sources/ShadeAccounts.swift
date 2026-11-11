import Foundation
import UIKit
import CryptoKit
import SwiftSignalKit
import Display
import TelegramCore
import AccountContext

// Shadegram: contas ocultas.
//
// Uma conta marcada como oculta some de todas as listas de contas do app (Configurações,
// seletor da aba, atalhos do ícone, badge/avatar da aba) enquanto o modo não estiver revelado.
//
// Comandos digitados na busca de Configurações:
//   #shade:<código>#      oculta a conta ATUAL e define o código (mínimo 4 caracteres)
//   <código>              revela as contas ocultas e troca para a oculta (de novo = esconde)
//   #shadeoff:<código>#   desfaz tudo (só funciona com o modo revelado)
//
// Ao ir para segundo plano o app volta a esconder e, se a conta ativa for oculta,
// troca para uma conta visível.
public final class ShadeAccounts {
    public static let shared = ShadeAccounts()

    private static let hiddenKey = "shadegram.hiddenAccountIds"
    private static let codeKey = "shadegram.codeHash"
    private static let minimumCodeLength = 4

    private let defaults = UserDefaults.standard

    private var hiddenIds: Set<Int64>
    private var revealed = false
    private let statePromise: ValuePromise<ShadeState>

    private weak var sharedContext: SharedAccountContext?
    private let enforceDisposable = MetaDisposable()
    private var backgroundObserver: NSObjectProtocol?

    private init() {
        let stored = (UserDefaults.standard.array(forKey: ShadeAccounts.hiddenKey) as? [NSNumber]) ?? []
        self.hiddenIds = Set(stored.map { $0.int64Value })
        self.statePromise = ValuePromise(ShadeState(hiddenIds: self.hiddenIds, revealed: false), ignoreRepeated: true)

        self.backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.conceal()
        })
    }

    deinit {
        if let backgroundObserver = self.backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        self.enforceDisposable.dispose()
    }

    public var state: Signal<ShadeState, NoError> {
        return self.statePromise.get()
    }

    public func isVisible(_ id: AccountRecordId, state: ShadeState) -> Bool {
        return state.revealed || !state.hiddenIds.contains(id.int64)
    }

    // Chamado sempre que a lista de contas é montada: garante que a regra
    // "conta oculta nunca fica ativa sem estar revelada" esteja valendo.
    public func attach(_ sharedContext: SharedAccountContext) {
        if self.sharedContext === sharedContext {
            return
        }
        self.sharedContext = sharedContext

        self.enforceDisposable.set((combineLatest(queue: .mainQueue(), sharedContext.activeAccountContexts, self.state)
        |> deliverOnMainQueue).start(next: { [weak sharedContext] accounts, state in
            guard let sharedContext = sharedContext, !state.revealed, let primary = accounts.primary else {
                return
            }
            if !state.hiddenIds.contains(primary.account.id.int64) {
                return
            }
            if let visible = accounts.accounts.first(where: { !state.hiddenIds.contains($0.0.int64) }) {
                ShadeAccounts.safeSwitch(sharedContext, to: visible.0)
            }
        }))
    }

    // Só verifica, sem efeito: o texto é um comando que handleSearch vai aceitar?
    // A busca usa isso para fechar o teclado ANTES de trocar de conta.
    public func isCommand(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = ShadeAccounts.extract(query, prefix: "#shade:") {
            return code.count >= ShadeAccounts.minimumCodeLength
        }
        if let code = ShadeAccounts.extract(query, prefix: "#shadeoff:") {
            return self.revealed && self.matches(code)
        }
        return !self.hiddenIds.isEmpty && query.count >= ShadeAccounts.minimumCodeLength && self.matches(query)
    }

    // Retorna true quando o texto foi um comando reconhecido.
    @discardableResult
    public func handleSearch(text: String, context: AccountContext) -> Bool {
        self.attach(context.sharedContext)

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let code = ShadeAccounts.extract(query, prefix: "#shade:") {
            guard code.count >= ShadeAccounts.minimumCodeLength else {
                return false
            }
            self.defaults.set(ShadeAccounts.hash(code), forKey: ShadeAccounts.codeKey)
            self.hiddenIds.insert(context.account.id.int64)
            self.revealed = false
            self.persistAndPublish()
            return true
        }

        if let code = ShadeAccounts.extract(query, prefix: "#shadeoff:") {
            guard self.revealed, self.matches(code) else {
                return false
            }
            self.defaults.removeObject(forKey: ShadeAccounts.codeKey)
            self.hiddenIds.removeAll()
            self.revealed = false
            self.persistAndPublish()
            return true
        }

        if !self.hiddenIds.isEmpty, query.count >= ShadeAccounts.minimumCodeLength, self.matches(query) {
            if self.revealed {
                self.conceal()
            } else {
                self.reveal(from: context)
            }
            return true
        }

        return false
    }

    private func reveal(from context: AccountContext) {
        self.revealed = true
        self.publish()

        let hiddenIds = self.hiddenIds
        let currentId = context.account.id
        let sharedContext = context.sharedContext
        let _ = (sharedContext.activeAccountContexts
        |> take(1)
        |> deliverOnMainQueue).start(next: { accounts in
            if hiddenIds.contains(currentId.int64) {
                return
            }
            if let target = accounts.accounts.first(where: { hiddenIds.contains($0.0.int64) }) {
                ShadeAccounts.safeSwitch(sharedContext, to: target.0)
            }
        })
    }

    private func conceal() {
        if !self.revealed {
            return
        }
        self.revealed = false
        self.publish()
    }

    private func matches(_ code: String) -> Bool {
        guard let stored = self.defaults.string(forKey: ShadeAccounts.codeKey) else {
            return false
        }
        return stored == ShadeAccounts.hash(code)
    }

    private func persistAndPublish() {
        self.defaults.set(self.hiddenIds.map { NSNumber(value: $0) }, forKey: ShadeAccounts.hiddenKey)
        self.publish()
    }

    private func publish() {
        self.statePromise.set(ShadeState(hiddenIds: self.hiddenIds, revealed: self.revealed))
    }

    private static func extract(_ query: String, prefix: String) -> String? {
        guard query.lowercased().hasPrefix(prefix), query.hasSuffix("#"), query.count > prefix.count + 1 else {
            return nil
        }
        return String(query.dropFirst(prefix.count).dropLast())
    }

    // Trocar de conta com teclado/busca abertos deixa o espaço do teclado "preso" na tela nova
    // (metade de baixo escura e sem toque). Fecha o teclado e espera ele sair antes de trocar.
    private static func safeSwitch(_ sharedContext: SharedAccountContext, to id: AccountRecordId) {
        sharedContext.mainWindow?.hostView.eventView.window?.endEditing(true)
        Queue.mainQueue().after(0.45, {
            sharedContext.switchToAccount(id: id, fromSettingsController: nil, withChatListController: nil)
        })
    }

    private static func hash(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(("shadegram:" + code).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ShadeState: Equatable {
    public let hiddenIds: Set<Int64>
    public let revealed: Bool
}
