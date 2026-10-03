import Foundation
@main struct Checks {
 static func main() throws {
  let project=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("zhiye-reader-test-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:root) }
  let source = #"""
# 开始

## 原文第 1 页

<a id="S01014"></a>
<!-- internal-only -->

**加粗**、*斜体*、`<code>`、$x_1 + x_2$ 与 \(y = 2\)。

| A | B |
|---|---|
| 甲 | 乙 |

![本地图](assets/figure.png)
![含空格图片](<assets/figure one.png>)
![远程图](https://example.invalid/track.png)
![越界图](../secret.png)

[原文](zhiye://page/2) [安全外链](https://example.com/) [不安全](javascript:alert(1)) [锚点](#原文第-1-页)

<script>alert('bad')</script><img src="https://example.invalid" onerror="bad()">

$$
E=mc^2
$$

```sh
<!-- code comment kept -->
<a id="code-anchor"></a>
rm -rf nope
```
"""#
  let parsed=MarkdownRenderer.parse(source,assetRoot:root)
  func expect(_ yes:Bool,_ reason:String) {if !yes {fatalError(reason)}}
  expect(parsed.html.contains("<table>"),"table rendering")
  expect(parsed.html.contains("assets/figure%20one.png"),"angle destination with spaces")
  expect(parsed.html.contains("code comment kept") && parsed.html.contains("code-anchor"),"source metadata preserved inside code")
  expect(parsed.html.contains("<strong>加粗</strong>"),"bold rendering")
  expect(parsed.html.contains("<em>斜体</em>"),"italic rendering")
  expect(parsed.html.contains("class=\"math\""),"inline math")
  expect(parsed.html.contains("class=\"math display\""),"display math")
  expect(parsed.html.contains("href=\"zhiye://page/2\""),"page link")
  expect(parsed.html.contains("id=\"原文第-1-页\""),"Chinese heading id")
  expect(!parsed.html.contains("S01014") && !parsed.html.contains("internal-only"),"metadata filtered")
  expect(!parsed.html.contains("<script>") && !parsed.html.contains("<img src=\"https://"),"raw HTML inactive")
  expect(!parsed.html.contains("src=\"https://"),"remote image blocked")
  expect(!parsed.html.contains("href=\"javascript:"),"dangerous scheme blocked")
  let repeatedSource = "## 原文第 3 页\n\n[查看此页原文](zhiye://page/3)\n\n原文：[PDF 第 3 页](zhiye://page/3)\n\n原文：[PDF 第 3 页](zhiye://page/3)\n\n第一段正文\n\n原文：[PDF 第 3 页](zhiye://page/3)\n\n第二段正文\n\n```md\n原文：[PDF 第 3 页](zhiye://page/3)\n```"
  let quietSource = MarkdownRenderer.parse(repeatedSource, assetRoot: root).html
  expect(quietSource.components(separatedBy: "class=\"page-source\"").count == 2, "one page-level backlink")
  expect(quietSource.components(separatedBy: "class=\"source-note\"").count == 3, "collapse only consecutive duplicate source labels")
  expect(quietSource.contains("第一段正文") && quietSource.contains("第二段正文") && quietSource.contains("<pre><code>原文："), "body and code survive source label cleanup")
  expect(MarkdownRenderer.imageURL("../outside.png",assetRoot:root)==nil,"parent escape")
  expect(MarkdownRenderer.imageURL("%2e%2e/outside.png",assetRoot:root)==nil,"encoded parent escape")
  expect(MarkdownRenderer.imageURL("file:///etc/passwd",assetRoot:root)==nil,"file scheme")
  expect(MarkdownRenderer.imageURL("//example.com/track.png",assetRoot:root)==nil,"protocol relative")
  expect(MarkdownRenderer.imageURL("evil.svg",assetRoot:root)==nil,"active SVG blocked")
  try? FileManager.default.removeItem(at:root.appendingPathComponent("outside"))
  try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("outside"),withDestinationURL:URL(fileURLWithPath:"/etc"))
  expect(ReaderResources.safeFile("outside/passwd",under:root)==nil,"symlink escape")
  let html=MarkdownRenderer.document(source,documentID:"</script><script>alert(1)</script>",fontSize:16,dark:false,progress:0.45,assetRoot:root)
  expect(!html.contains("const documentID=\"</script>"),"document ID not HTML injection")
  try html.write(to:root.appendingPathComponent("fixture.html"),atomically:true,encoding:.utf8)
  let real=project.deletingLastPathComponent().appendingPathComponent("translations/frugal/paper_zh.md")
  if FileManager.default.fileExists(atPath: real.path) {
   let realSource=try String(contentsOf:real,encoding:.utf8)
   let realParsed=MarkdownRenderer.parse(realSource,assetRoot:real.deletingLastPathComponent())
   expect(realParsed.headings.filter{$0.title.hasPrefix("原文第")}.count==15,"real 15 page headings")
   expect(realParsed.html.components(separatedBy:"<img src=").count-1==22,"real figure/table/equation images")
   print("PASS: optional local manuscript has 15 page anchors and 22 images.")
  }
  print("PASS: headings/table/emphasis/code/math; input HTML and anchors; unsafe links, remote images, traversal/symlink restrictions; generated-script escaping; angle-path spaces and fenced-code metadata preservation.")
 }
}
