// ★ 独立校验器：用 **macOS 自带的 PDFKit**（不是我们自己的解析器）打开
// 经 D61 自研增量更新处理过的 PDF，列出页数与每页注释。
//
//   swift tool/verify_pdf_annots.swift /tmp/drive_pdf_annot_sample.pdf
//
// 为什么需要它：D61 的写法是否正确，不能只由"写它的那份代码"来证明。
// PDFKit 是另一套独立实现；它若能打开并列出 `/Highlight`、`/Ink`、`/Text`，
// 就说明我们确实把**真正的注释对象**写进了原文件的对象图。
//
// 输出是 JSON，便于脚本/文档引用。
import Foundation
import PDFKit

let path = CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : "/tmp/drive_pdf_annot_sample.pdf"

guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
  FileHandle.standardError.write("PDFKit 打不开: \(path)\n".data(using: .utf8)!)
  exit(2)
}

var pages: [[String: Any]] = []
for i in 0..<doc.pageCount {
  guard let page = doc.page(at: i) else { continue }
  var annots: [[String: Any]] = []
  for a in page.annotations {
    var entry: [String: Any] = [
      "type": a.type ?? "",
      "contents": a.contents ?? "",
    ]
    if let b = a.bounds as CGRect? {
      entry["bounds"] = [b.origin.x, b.origin.y, b.size.width, b.size.height]
    }
    annots.append(entry)
  }
  pages.append(["page": i + 1, "annots": annots])
}

let result: [String: Any] = [
  "validator": "macOS PDFKit",
  "file": path,
  "pageCount": doc.pageCount,
  "pages": pages,
]
let data = try JSONSerialization.data(
  withJSONObject: result,
  options: [.prettyPrinted, .sortedKeys]
)
print(String(data: data, encoding: .utf8)!)
