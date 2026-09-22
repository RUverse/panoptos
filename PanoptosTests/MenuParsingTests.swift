import ApplicationServices
import XCTest
@testable import Panoptos

final class MenuParsingTests: XCTestCase {
    func testFeedbackLinkUsesGitHubIssuesWithoutQueryMetadata() {
        XCTAssertEqual(PanoptosLinks.feedback.absoluteString, "https://github.com/RUverse/panoptos/issues")
        XCTAssertNil(PanoptosLinks.feedback.query)
    }

    func testNestedTreePreservesStableIndexPathsAndState() {
        let snapshots = [
            MenuSnapshot(
                title: "File",
                role: kAXMenuBarItemRole as String,
                isEnabled: true,
                mark: nil,
                commandCharacter: nil,
                commandModifiers: nil,
                virtualKey: nil,
                actions: [],
                children: [
                    MenuSnapshot(
                        title: "New Window",
                        role: kAXMenuItemRole as String,
                        isEnabled: true,
                        mark: "✓",
                        commandCharacter: "n",
                        commandModifiers: 0,
                        virtualKey: nil,
                        actions: [kAXPickAction as String],
                        children: []
                    ),
                    MenuSnapshot(
                        title: "Unavailable",
                        role: kAXMenuItemRole as String,
                        isEnabled: false,
                        mark: nil,
                        commandCharacter: nil,
                        commandModifiers: nil,
                        virtualKey: nil,
                        actions: [],
                        children: []
                    )
                ]
            )
        ]

        let result = MenuTreeParser.parse(snapshots)

        XCTAssertEqual(result[0].indexPath, [0])
        XCTAssertEqual(result[0].children[0].indexPath, [0, 0])
        XCTAssertEqual(result[0].children[0].shortcut, "⌘N")
        XCTAssertEqual(result[0].children[0].mark, "✓")
        XCTAssertTrue(result[0].children[0].isInvokable)
        XCTAssertFalse(result[0].children[1].isInvokable)
    }

    func testSeparatorAndMissingAttributes() {
        let separator = MenuSnapshot(
            title: nil,
            role: kAXMenuItemRole as String,
            isEnabled: nil,
            mark: "",
            commandCharacter: nil,
            commandModifiers: nil,
            virtualKey: nil,
            actions: [],
            children: []
        )

        let result = MenuTreeParser.parse([separator])[0]

        XCTAssertTrue(result.isSeparator)
        XCTAssertTrue(result.isEnabled)
        XCTAssertNil(result.mark)
        XCTAssertNil(result.shortcut)
    }

    func testShortcutModifierFormatting() {
        XCTAssertEqual(ShortcutFormatter.format(character: "s", modifiers: 0, virtualKey: nil), "⌘S")
        XCTAssertEqual(ShortcutFormatter.format(character: "s", modifiers: 1 | 2 | 4, virtualKey: nil), "⌃⌥⇧⌘S")
        XCTAssertEqual(ShortcutFormatter.format(character: "x", modifiers: 8, virtualKey: nil), "X")
        XCTAssertEqual(ShortcutFormatter.format(character: nil, modifiers: nil, virtualKey: 53), "key:53")
        XCTAssertNil(ShortcutFormatter.format(character: nil, modifiers: nil, virtualKey: nil))
    }

    func testVirtualMenuKeyEquivalents() {
        XCTAssertEqual(MenuVirtualKeyEquivalent.character(for: 53), "\u{1b}")
        XCTAssertEqual(MenuVirtualKeyEquivalent.character(for: 123), UnicodeScalar(0xF702).map(String.init))
        XCTAssertEqual(MenuVirtualKeyEquivalent.character(for: 122), UnicodeScalar(0xF704).map(String.init))
        XCTAssertNil(MenuVirtualKeyEquivalent.character(for: 999))
    }

    func testActionPreference() {
        XCTAssertEqual(
            MenuActionSelector.preferredAction(in: [kAXPressAction as String, kAXPickAction as String]),
            kAXPickAction as String
        )
        XCTAssertEqual(MenuActionSelector.preferredAction(in: [kAXPressAction as String]), kAXPressAction as String)
        XCTAssertNil(MenuActionSelector.preferredAction(in: ["AXShowMenu"]))
    }

    func testErrorsDescribeStaleAndUnavailableTargets() {
        XCTAssertTrue(AccessibilityClientError.stalePath([1, 2]).localizedDescription.contains("1.2"))
        XCTAssertTrue(AccessibilityClientError.applicationUnavailable(42).localizedDescription.contains("42"))
    }

    func testAppSpecificMenusRemoveOnlyLeadingAppleMenu() {
        let menus = MenuTreeParser.parse([
            menuBarItem("Apple"),
            menuBarItem("File"),
            menuBarItem("Apple")
        ])

        XCTAssertEqual(menus.appSpecificMenus.map(\.title), ["File", "Apple"])
        XCTAssertEqual(Array(menus.dropFirst()).appSpecificMenus.map(\.title), ["File", "Apple"])
    }

    func testMenuStripMergesApplicationMenuIntoAppTitle() {
        let menus = MenuTreeParser.parse([
            menuBarItem("Apple"),
            menuBarItem("Code"),
            menuBarItem("File"),
            menuBarItem("Edit")
        ])

        XCTAssertEqual(menus.menuStripAppMenu?.title, "Code")
        XCTAssertEqual(menus.menuStripCommandMenus.map(\.title), ["File", "Edit"])

        let menusWithoutApple = Array(menus.dropFirst())
        XCTAssertNil(menusWithoutApple.menuStripAppMenu)
        XCTAssertEqual(menusWithoutApple.menuStripCommandMenus.map(\.title), ["Code", "File", "Edit"])
    }

    private func menuBarItem(_ title: String) -> MenuSnapshot {
        MenuSnapshot(
            title: title,
            role: kAXMenuBarItemRole as String,
            isEnabled: true,
            mark: nil,
            commandCharacter: nil,
            commandModifiers: nil,
            virtualKey: nil,
            actions: [],
            children: []
        )
    }
}
