import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list { let o = w[kCGWindowOwnerName as String] as? String ?? ""; if o.contains("phone") { print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, w[kCGWindowBounds as String]!, w[kCGWindowIsOnscreen as String] ?? "-") } }
