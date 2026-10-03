import SwiftUI
import AppKit

struct LibrarySettingsPane: View {
    @ObservedObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StoredState<BackupPreview?> private var preview = nil
    @StoredState<String?> private var failure = nil
    @StoredState<String?> private var result = nil
    @StoredState<Bool> private var busy = false
    @StoredState<URL?> private var backupURL = nil
    @StoredState<Bool> private var confirmRestore = false
    @StoredState<Bool> private var recoveryRequired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("资料库设置").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Label("保存在这台 Mac", systemImage: "internaldrive").font(.headline)
                Text("\(session.store.papers.count) 篇论文 · \(session.store.data.notes.count) 条记录 · \(session.features.data.drafts.count) 份草稿")
                    .font(.callout).foregroundStyle(StudyTheme.muted)
                Text(session.store.dataURL.path).font(.caption).foregroundStyle(StudyTheme.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("在访达中打开资料库") { NSWorkspace.shared.open(session.store.dataURL) }.buttonStyle(.link)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(StudyTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button("备份学习资料…", action: backup).buttonStyle(.borderedProminent)
                Button("恢复备份…", action: chooseBackup).buttonStyle(.bordered)
            }.disabled(recoveryRequired)
            Text("备份包含个人记录、草稿、整理、书签和自行导入的文件。内置论文和学习材料随应用提供。")
                .font(.caption).foregroundStyle(StudyTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let preview {
                VStack(alignment: .leading, spacing: 12) {
                    Text("备份已检查").font(.headline)
                    Text("\(preview.noteCount) 条记录 · \(preview.unresolvedCount) 个待解疑问\n\(preview.importedPaperCount) 篇自导论文 · \(preview.documentCount) 份自导材料 · \(preview.bookmarkCount) 个书签")
                        .font(.callout).lineSpacing(5)
                    if let date = preview.createdAt { Text(date, style: .date).font(.caption).foregroundStyle(StudyTheme.muted) }
                    Text(preview.isLegacy ? "这是旧版目录备份，已检查可恢复的数据和资源。" : "文件完整性校验通过。")
                        .font(.caption).foregroundStyle(StudyTheme.muted)
                    Text("恢复会切换为这份备份；当前资料会先保存为可恢复副本。")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("使用这份备份") { confirmRestore = true }.buttonStyle(.borderedProminent).disabled(recoveryRequired)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(StudyTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
            }
            if busy { HStack { ProgressView().controlSize(.small); Text("正在检查并保存资料…").font(.callout) } }
            if let failure { Text(failure).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let result {
                Text(result).font(.callout).foregroundStyle(StudyTheme.accent).fixedSize(horizontal: false, vertical: true)
                if let backupURL { Button("在访达中查看备份") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }.buttonStyle(.link) }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(28).frame(width: 530).background(StudyTheme.paper).foregroundStyle(StudyTheme.text).tint(StudyTheme.accent)
            .disabled(busy).interactiveDismissDisabled(busy)
            .confirmationDialog("恢复后将使用所选备份", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("恢复并保留当前资料副本", action: restore)
                Button("取消", role: .cancel) {}
            } message: { Text("你现在的资料会单独保留，不会直接删除。") }
    }
    private func prepare() -> Bool {
        guard session.store.save(), session.documents.flushProgress(), session.features.flushPendingChanges() else {
            failure = "有修改未保存，暂未开始操作。请先检查保存位置，再重试。"; return false
        }
        return true
    }
    private func backup() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择备份存放的位置"
        guard panel.runModal() == .OK, let parent = panel.url, prepare() else { return }
        failure = nil; result = nil; busy = true; session.suspendPersistence(true)
        let source = session.store.dataURL
        Task { @MainActor in
            do {
                let created = try await Task.detached { try LibraryStorage.createBackup(from: source, to: parent) }.value
                backupURL = created.directory
                result = "备份已完成并通过校验 · \(created.noteCount) 条记录"
            } catch { failure = error.localizedDescription }
            session.suspendPersistence(false); busy = false
        }
    }
    private func chooseBackup() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择 Fishbook 备份目录，也支持旧版的学习资料目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        failure = nil; result = nil; preview = nil; busy = true
        Task { @MainActor in
            do { preview = try await Task.detached { try LibraryStorage.inspectBackup(at: url) }.value }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
    private func restore() {
        guard let preview else { return }
        // A damaged store must remain recoverable. Never serialize its fallback
        // model over the original bytes; restore archives that directory as-is.
        if session.store.ready && !session.store.save() { failure = "当前记录尚未保存，请先处理保存错误。"; return }
        if session.store.ready && session.documents.ready && !session.documents.flushProgress() { failure = "当前阅读位置尚未保存，请重试。"; return }
        if session.features.ready && !session.features.flushPendingChanges() { failure = "复述内容尚未保存，请重试。"; return }
        failure = nil; busy = true; session.suspendPersistence(true)
        let source = preview.directory, destination = session.store.dataURL
        Task { @MainActor in
            do {
                _ = try await Task.detached { try LibraryStorage.restore(from: source, to: destination) }.value
                // Old controllers retain suspended stores. Late WebKit/PDF callbacks
                // therefore cannot overwrite the restored library during teardown.
                session.reload()
                session.store.notice = "备份已恢复，原资料副本已保留"
                dismiss()
            } catch let error as LibraryRestoreError {
                // The target directory may no longer be the one these controllers
                // loaded. Keep every writer paused until startup reconciles it.
                recoveryRequired = true; failure = error.localizedDescription; busy = false
                session.store.notice = "恢复未完成，已暂停保存。请保留资料副本，退出并重新打开 Fishbook。"
            } catch {
                session.suspendPersistence(false); failure = error.localizedDescription; busy = false
            }
        }
    }
}
