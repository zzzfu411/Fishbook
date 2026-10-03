import Foundation
import PDFKit
import CryptoKit

@main struct Smoke {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("paper-study-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let s=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(s.ready,s.error ?? "not ready")
        let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:root.appendingPathComponent("content/library.json")))
        let supplementalURL=root.appendingPathComponent("content/supplemental-papers.json")
        let supplemental=FileManager.default.fileExists(atPath:supplementalURL.path)
            ? try JSONDecoder().decode([Paper].self,from:Data(contentsOf:supplementalURL)) : []
        let expectedIDs=catalog.papers.map(\.id)+supplemental.map(\.id)
        let initialCount=expectedIDs.count
        precondition(catalog.papers.count==47,"Original 47-paper collection must be retained")
        precondition(s.papers.map(\.id)==expectedIDs && s.guides.count==catalog.guides.count)
        precondition(s.contentWarnings.isEmpty,s.contentWarnings.joined(separator:"\n"))
        var anchors=0
        func normal(_ str:String)->String { str.lowercased().filter { $0.isLetter || $0.isNumber } }
        for paper in s.papers {
            let bytes=try Data(contentsOf:s.fileURL(paper))
            precondition(SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()==paper.sha256)
            let doc=PDFDocument(data:bytes)!
            precondition(doc.pageCount==paper.pages)
            if let guide=s.guides[paper.id] {
                for c in guide.concepts {
                    precondition(c.sections.count==7 && c.sections.allSatisfy{!$0.body.isEmpty})
                    let page=doc.page(at:c.anchor.page)!
                    let actual=page.selection(for:c.anchor.rects[0].cg)?.string ?? ""
                    precondition(normal(actual).contains(normal(c.anchor.quote)),
                                 "\(paper.id) \(c.id): bad source mapping [\(actual)] vs [\(c.anchor.quote)]")
                    anchors+=1
                }
            }
        }
        s.select("R01")
        let note=StudyNote(paperID:"R01",kind:"疑问",body:"测试：为什么只复制尾块？",quote:"copy-on-write",
                           anchors:[s.guides["R01"]!.concepts[2].anchor])
        s.upsert(note)
        s.data.exercises["R01"]="我自己的手推过程"
        s.setPosition("R01",ReadingPosition(page:6,x:0,y:650))
        let restarted=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(restarted.data.notes.first?.body==note.body)
        precondition(restarted.canLocate(restarted.data.notes.first!))
        precondition(restarted.data.positions["R01"]?.page==6)
        precondition(restarted.readingPosition(for:"R01")?.page==6)
        precondition(restarted.data.exercises["R01"]=="我自己的手推过程")
        var update=restarted.guides["R01"]!
        update.subtitle="测试内容更新"
        let updateURL=temp.appendingPathComponent("update-test.json")
        try restarted.encoder.encode([update]).write(to:updateURL)
        restarted.importGuides(updateURL)
        precondition(restarted.guides["R01"]?.subtitle==update.subtitle)
        precondition(restarted.data.notes.first?.id==note.id)
        let reloaded=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(reloaded.guides["R01"]?.subtitle==update.subtitle)
        update.sha256="wrong-version"
        try reloaded.encoder.encode([update]).write(to:updateURL)
        reloaded.importGuides(updateURL)
        precondition(reloaded.error != nil && reloaded.guides["R01"]?.sha256 != "wrong-version")
        let export=temp.appendingPathComponent("notes.md")
        reloaded.exportMarkdown(export)
        let md=try String(contentsOf:export,encoding:.utf8)
        precondition(md.contains(note.body) && md.contains("第 7 页") && md.contains("我自己的手推过程"))
        reloaded.error=nil
        reloaded.importPDF([reloaded.fileURL(reloaded.papers[0])])
        precondition(reloaded.papers.count==initialCount)
        let sample=PDFDocument()
        let samplePage=PDFPage();samplePage.setBounds(CGRect(x:0,y:0,width:612,height:792),for:.mediaBox)
        sample.insert(samplePage,at:0)
        let sampleURL=temp.appendingPathComponent("sample.pdf")
        try sample.dataRepresentation()!.write(to:sampleURL)
        reloaded.importPDF([sampleURL])
        precondition(reloaded.papers.count==initialCount+1 && reloaded.error == nil)
        let imported=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(imported.papers.count==initialCount+1 && imported.data.importedPapers.count==1)
        precondition(FileManager.default.fileExists(atPath:imported.fileURL(imported.data.importedPapers[0]).path))
        let undo=UndoManager();undo.groupsByEvent=false
        let storedNote=imported.data.notes.first!
        undo.beginUndoGrouping();precondition(imported.remove(storedNote,undo:undo));undo.endUndoGrouping()
        precondition(imported.data.notes.isEmpty)
        undo.undo();precondition(imported.data.notes.first?.id==note.id && undo.canRedo)
        undo.redo();precondition(imported.data.notes.isEmpty)
        undo.undo();precondition(imported.canLocate(imported.data.notes.first!))
        let backupParent=FileManager.default.temporaryDirectory.appendingPathComponent("paper-study-backup-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:backupParent)}
        try FileManager.default.createDirectory(at:backupParent,withIntermediateDirectories:true)
        imported.backup(to:backupParent)
        let backup=try FileManager.default.contentsOfDirectory(at:backupParent,includingPropertiesForKeys:nil).first!
        let restored=StudyStore(resourceDirectory:root,dataDirectory:backup)
        precondition(restored.ready && restored.data.notes.first?.id==note.id && restored.papers.count==initialCount+1)

        // Invalid optional content is isolated; it must not disable the library.
        let guidesURL=temp.appendingPathComponent("guides.json")
        let guidesBefore=try Data(contentsOf:guidesURL)
        try Data("broken optional guide".utf8).write(to:guidesURL)
        let badGuide=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(badGuide.ready && badGuide.selectedID != nil && !badGuide.saveFailed)
        precondition(badGuide.guides.count==catalog.guides.count && !badGuide.contentWarnings.isEmpty)
        precondition(badGuide.data.notes.first?.id==note.id)
        badGuide.importGuides(root.appendingPathComponent("content/guides.json"))
        let recovered=try FileManager.default.contentsOfDirectory(at:temp,includingPropertiesForKeys:nil).filter {$0.lastPathComponent.hasPrefix("guides-recovery-")}
        precondition(recovered.count==1)
        let recoveredBytes=try Data(contentsOf:recovered[0])
        precondition(recoveredBytes==Data("broken optional guide".utf8))
        try guidesBefore.write(to:guidesURL)

        // Packages with empty sections, wrong source text, or off-page geometry
        // are rejected atomically, retaining the already installed guide.
        for kind in ["empty", "quote", "bounds"] {
            var bad=reloaded.guides["R01"]!
            if kind=="empty" {bad.concepts[0].sections[0].body=""}
            if kind=="quote" {bad.concepts[0].anchor.quote="THIS QUOTE DOES NOT OCCUR IN THE PAPER"}
            if kind=="bounds" {bad.concepts[0].anchor.rects=[Box(CGRect(x:100000,y:100000,width:20,height:20))]}
            try reloaded.encoder.encode([bad]).write(to:updateURL)
            reloaded.error=nil
            reloaded.importGuides(updateURL)
            precondition(reloaded.error != nil)
            let unchangedGuides=try Data(contentsOf:guidesURL)
            precondition(unchangedGuides==guidesBefore)
        }

        // Legacy 0.3 state without sourceSHA256 is pinned to the old manifest,
        // while unknown legacy IDs remain readable but cannot be located.
        let legacyDir=temp.appendingPathComponent("legacy-test")
        try FileManager.default.createDirectory(at:legacyDir,withIntermediateDirectories:true)
        var legacyObject=try JSONSerialization.jsonObject(with:restarted.encoder.encode(restarted.data)) as! [String:Any]
        var legacyNotes=legacyObject["notes"] as! [[String:Any]]
        for i in legacyNotes.indices {legacyNotes[i].removeValue(forKey:"sourceSHA256")}
        legacyObject["notes"]=legacyNotes
        var legacyPositions=legacyObject["positions"] as! [String:[String:Any]]
        for id in Array(legacyPositions.keys) {legacyPositions[id]?.removeValue(forKey:"sourceSHA256")}
        legacyObject["positions"]=legacyPositions
        try JSONSerialization.data(withJSONObject:legacyObject).write(to:legacyDir.appendingPathComponent("state.json"))
        let legacy=StudyStore(resourceDirectory:root,dataDirectory:legacyDir)
        precondition(legacy.ready && legacy.canLocate(legacy.data.notes[0]) && legacy.readingPosition(for:"R01")?.page==6)
        let unknown=StudyNote(paperID:"missing-paper",kind:"笔记",body:"原论文不在目录也不能丢失",quote:"",anchors:[Anchor(page:0,rects:[],quote:"")])
        legacy.data.notes.append(unknown);legacy.save()
        legacy.exportMarkdown(legacyDir.appendingPathComponent("orphan.md"))
        let orphanMarkdown=try String(contentsOf:legacyDir.appendingPathComponent("orphan.md"),encoding:.utf8)
        precondition(orphanMarkdown.contains(unknown.body))
        precondition(!legacy.canLocate(unknown))

        // Updating a same-ID PDF must not inherit old locations or highlights.
        let revisedRoot=temp.appendingPathComponent("revised-resource")
        let revisedContent=revisedRoot.appendingPathComponent("content")
        try FileManager.default.createDirectory(at:revisedContent,withIntermediateDirectories:true)
        var revisedCatalog=catalog
        let paperIndex=revisedCatalog.papers.firstIndex {$0.id=="R01"}!
        let replacement=sample.dataRepresentation()!
        revisedCatalog.papers[paperIndex].sha256=SHA256.hash(data:replacement).map {String(format:"%02x",$0)}.joined()
        revisedCatalog.papers[paperIndex].pages=1;revisedCatalog.papers[paperIndex].file="revised.pdf"
        revisedCatalog.guides=[]
        try s.encoder.encode(revisedCatalog).write(to:revisedContent.appendingPathComponent("library.json"))
        try replacement.write(to:revisedContent.appendingPathComponent("revised.pdf"))
        try FileManager.default.copyItem(at:root.appendingPathComponent("content/legacy-paper-fingerprints.json"),to:revisedContent.appendingPathComponent("legacy-paper-fingerprints.json"))
        let upgraded=StudyStore(resourceDirectory:revisedRoot,dataDirectory:legacyDir)
        precondition(upgraded.ready && upgraded.data.notes.first?.body==note.body)
        precondition(!upgraded.canLocate(upgraded.data.notes[0]) && upgraded.annotationNotes(for:"R01").isEmpty)
        precondition(upgraded.readingPosition(for:"R01")==nil)
        var oldEdit=upgraded.data.notes[0];oldEdit.body="仍可修改旧版本笔记正文"
        precondition(upgraded.upsert(oldEdit) && !upgraded.canLocate(upgraded.data.notes[0]))
        upgraded.exportMarkdown(legacyDir.appendingPathComponent("changed-version.md"))
        let changedMarkdown=try String(contentsOf:legacyDir.appendingPathComponent("changed-version.md"),encoding:.utf8)
        precondition(changedMarkdown.contains("不自动定位"))

        // A real write failure must never report success, duplicate a retried
        // note, hide a failed deletion, or leave an imported catalog entry.
        let failureDir=temp.appendingPathComponent("save-failure")
        let failing=StudyStore(resourceDirectory:root,dataDirectory:failureDir)
        try FileManager.default.createDirectory(at:failing.stateURL,withIntermediateDirectories:true)
        precondition(!failing.upsert(note) && failing.saveFailed && failing.notice==nil)
        precondition(!failing.upsert(note) && failing.data.notes.isEmpty)
        precondition(!failing.remove(note,undo:nil) && failing.data.notes.isEmpty)
        failing.importPDF([sampleURL])
        precondition(failing.papers.count==initialCount && failing.data.importedPapers.isEmpty)
        try FileManager.default.removeItem(at:failing.stateURL)
        precondition(failing.upsert(note) && !failing.saveFailed && failing.data.notes.count==1)
        let retry=StudyStore(resourceDirectory:root,dataDirectory:failureDir)
        precondition(retry.data.notes.count==1 && retry.canLocate(retry.data.notes[0]))

        // Normalize the selected backup parent, including symlink aliases.
        let alias=backupParent.appendingPathComponent("alias-to-data")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:imported.dataURL)
        imported.error=nil;imported.backup(to:alias)
        precondition(imported.error?.contains("学习资料目录之外")==true)
        let stateBefore=try Data(contentsOf:reloaded.stateURL)
        try Data("broken state".utf8).write(to:reloaded.stateURL)
        let broken=StudyStore(resourceDirectory:root,dataDirectory:temp)
        precondition(!broken.ready && broken.error != nil)
        broken.save()
        let corruptBytes=try Data(contentsOf:broken.stateURL)
        precondition(corruptBytes==Data("broken state".utf8))
        try stateBefore.write(to:reloaded.stateURL)
        print("PASS: \(initialCount) PDF hashes/pages; \(anchors) PDFKit source anchors; seven-part guides; persistence; isolated optional failures; source-version migration and mismatch protection; invalid guide rejection; failed-save recovery; complete Markdown export; transactional PDF import; backup reload/symlink guard; corrupt state retained.")
    }
}
