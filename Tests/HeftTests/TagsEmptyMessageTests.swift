import Testing
@testable import Heft

/// A focused window lists only its folder's tags, so an empty list says so.
@MainActor
@Suite("The empty Tags list says where it looked")
struct TagsEmptyMessageTests {

    @Test("A focused folder is named, the whole vault is not")
    func namesTheFolder() {
        #expect(SidebarView.noTagsMessage(filtered: false, focusedFolder: "Projects") == "No tags in Projects")
        #expect(SidebarView.noTagsMessage(filtered: false, focusedFolder: nil) == "No tags in this vault")
        #expect(SidebarView.noTagsMessage(filtered: true, focusedFolder: "Projects") == "No matching tags")
    }
}
