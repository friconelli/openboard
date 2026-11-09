import XCTest
@testable import OpenBoard

final class ShellHookTests: XCTestCase {
    func testEarlierLaunchBlockIsRemovedByShape() {
        let zshrc = """
        export PATH="$HOME/bin:$PATH"

        # >>> Nome Vecchio >>>
        # Runs a command queued when a new tab opens in its folder (once per shell).
        _old_launch() {
          precmd_functions=(${precmd_functions:#_old_launch})
          local dir="$HOME/.vecchio/launch" f
        }
        precmd_functions+=(_old_launch)
        # <<< Nome Vecchio <<<

        # >>> conda initialize >>>
        conda stuff
        # <<< conda initialize <<<
        alias ll='ls -la'
        """
        let cleaned = ShellHook.withoutEarlierBlocks(zshrc)
        XCTAssertFalse(cleaned.contains("Nome Vecchio"))
        XCTAssertFalse(cleaned.contains("_old_launch"))
        XCTAssertTrue(cleaned.contains("# >>> conda initialize >>>\nconda stuff\n# <<< conda initialize <<<"), "other blocks stay")
        XCTAssertTrue(cleaned.contains("export PATH") && cleaned.contains("alias ll"))
    }
}
