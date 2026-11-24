import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l { if let o = w[kCGWindowOwnerName as String] as? String, o == "Whopper" || o == "Whoprrr", let n = w[kCGWindowNumber as String] as? Int, (w[kCGWindowLayer as String] as? Int) == 0 { print(n, w[kCGWindowBounds as String] ?? "") } }
