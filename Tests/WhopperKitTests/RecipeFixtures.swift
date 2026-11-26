import Foundation

/// A `recipes.json` exactly as the app wrote it before the format was versioned (written by the unmodified encoder, with a
/// recipe whose live audio differs from its baseline, so the file also carries an "unsaved change").
/// Three recipes: Desk (four pieces of gear, four parts, auto-apply, active), On the road (a person's name in the gear
/// name), Anywhere (no gear).
enum RecipeFixtures {
    static let deskID = UUID(uuidString: "B23E8868-2B26-444B-A9C5-7EEC9E7CC718")!
    static let v1 = #"""
{
  "activeID" : "B23E8868-2B26-444B-A9C5-7EEC9E7CC718",
  "appliedSections" : {
    "audio" : "eyJlcSI6eyJlbmFibGVkIjp0cnVlLCJ0YXJnZXRVSUQiOiJBcHBsZVVTQkF1ZGlvRW5naW5lOlhpYW9taToxIn0sImlucHV0UGluIjp7ImVuYWJsZWQiOnRydWUsInByZWZlcnJlZFVJRHMiOltdfSwia2VlcEFsaXZlIjp7fX0=",
    "display" : "eyJwcmVzZXQiOiJFdmVuaW5nIn0=",
    "features" : "WyJhdWRpbyIsImNsaXBib2FyZCIsImRpc3BsYXkiLCJ3aW5kb3dzIl0=",
    "windows" : "eyJkcmF3ZXJBY3Rpb25zIjpbImxlZnRIYWxmIiwicmlnaHRIYWxmIiwibWF4aW1pemUiXX0="
  },
  "recipes" : [
    {
      "autoApply" : true,
      "createdAt" : 780000000,
      "devices" : [
        {
          "key" : "EDID-0000-1111",
          "kind" : "display",
          "name" : "S34CG50"
        },
        {
          "key" : "AppleUSBAudioEngine:Rode:PodMic:42",
          "kind" : "audioInput",
          "name" : "RØDE PodMic USB"
        },
        {
          "key" : "BT-XIAOMI",
          "kind" : "audioOutput",
          "name" : "Xiaomi Speaker"
        },
        {
          "key" : "MX Ergo",
          "kind" : "logitech",
          "name" : "MX Ergo"
        }
      ],
      "id" : "B23E8868-2B26-444B-A9C5-7EEC9E7CC718",
      "name" : "Desk",
      "sections" : {
        "audio" : "eyJlcSI6eyJlbmFibGVkIjp0cnVlLCJ0YXJnZXRVSUQiOiJBcHBsZVVTQkF1ZGlvRW5naW5lOlhpYW9taToxIn0sImlucHV0UGluIjp7ImVuYWJsZWQiOnRydWUsInByZWZlcnJlZFVJRHMiOlsiQXBwbGVVU0JBdWRpb0VuZ2luZTpSb2RlOlBvZE1pYzo0MiJdfSwia2VlcEFsaXZlIjp7IkJULVhJQU9NSSI6eyJlbmFibGVkIjp0cnVlfX19",
        "display" : "eyJwcmVzZXQiOiJFdmVuaW5nIn0=",
        "features" : "WyJhdWRpbyIsImNsaXBib2FyZCIsImRpc3BsYXkiLCJ3aW5kb3dzIl0=",
        "windows" : "eyJkcmF3ZXJBY3Rpb25zIjpbImxlZnRIYWxmIiwicmlnaHRIYWxmIiwibWF4aW1pemUiXX0="
      },
      "symbol" : "house",
      "updatedAt" : 780100000
    },
    {
      "autoApply" : false,
      "createdAt" : 780200000,
      "devices" : [
        {
          "key" : "AIRPODS-1",
          "kind" : "audioOutput",
          "name" : "Ana’s AirPods Pro"
        }
      ],
      "id" : "FE9751D8-6CC1-463D-B8E7-AD222CAAE172",
      "name" : "On the road",
      "sections" : {
        "audio" : "eyJlcSI6eyJlbmFibGVkIjp0cnVlLCJ0YXJnZXRVSUQiOiJBcHBsZVVTQkF1ZGlvRW5naW5lOlhpYW9taToxIn0sImlucHV0UGluIjp7ImVuYWJsZWQiOnRydWUsInByZWZlcnJlZFVJRHMiOlsiQXBwbGVVU0JBdWRpb0VuZ2luZTpSb2RlOlBvZE1pYzo0MiJdfSwia2VlcEFsaXZlIjp7IkJULVhJQU9NSSI6eyJlbmFibGVkIjp0cnVlfX19",
        "windows" : "eyJkcmF3ZXJBY3Rpb25zIjpbImxlZnRIYWxmIiwicmlnaHRIYWxmIiwibWF4aW1pemUiXX0="
      },
      "symbol" : "airplane",
      "updatedAt" : 780200000
    },
    {
      "autoApply" : false,
      "createdAt" : 817363791.704205,
      "devices" : [

      ],
      "id" : "6A7341BE-B931-469E-A087-A740E046BCB3",
      "name" : "Anywhere",
      "sections" : {
        "windows" : "eyJkcmF3ZXJBY3Rpb25zIjpbImxlZnRIYWxmIiwicmlnaHRIYWxmIiwibWF4aW1pemUiXX0="
      },
      "symbol" : "cup.and.saucer",
      "updatedAt" : 817363791.704205
    }
  ]
}
"""#
}
