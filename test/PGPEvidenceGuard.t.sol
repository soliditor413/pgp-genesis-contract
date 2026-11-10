// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

/**
 * @title F-11b(2): the 0x68 precompile call in SlashIndicator has to fail closed.
 *
 * @dev Why this file is standalone rather than a case in SlashIndicator.t.sol.
 *
 *      That suite builds the whole 17-contract world through Deployer.sol and runs its
 *      setup through governance; it is currently blocked before any assertion by the
 *      harness's missing block-D initialisation. The property under test here needs none of
 *      that: `submitDoubleSignEvidence` is `onlyInit` and nothing else, so a bare
 *      `deployCode` plus `init()` reaches the precompile call in two lines.
 *
 * @dev What the two cases prove together.
 *
 *      `staticcall` to an address with no code SUCCEEDS and returns nothing. That is the
 *      whole bug: the old code checked only the success flag, so on a chain where 0x68 is
 *      not a precompile the 52-byte output buffer stayed all zeros, the recovered signer
 *      was address(0), and the caller saw "validator not migrated" -- a message that sends
 *      whoever is debugging it to the validator set, which is fine.
 *
 *      Case 1 (nothing at 0x68) must now fail on the size check.
 *      Case 2 (exactly 52 bytes of zeros) must get PAST the size check and fail on the
 *      migration check, which is what proves the guard tests the size and not the content.
 */
interface ISlashIndicatorSubmit {
    function init() external;

    function submitDoubleSignEvidence(bytes memory header1, bytes memory header2) external;
}

contract PGPEvidenceGuardTest is Test {
    ISlashIndicatorSubmit internal slash;

    function setUp() public {
        // The node calls init() from SystemAddress with block.coinbase == SystemAddress and
        // a zero gas price; a direct call here comes from this contract, so pin coinbase to
        // it. Same two lines as PGPValidatorSetInit.t.sol's setUp, same reason.
        vm.coinbase(address(this));
        vm.txGasPrice(0);

        slash = ISlashIndicatorSubmit(deployCode("SlashIndicator.sol"));
        slash.init();
    }

    /// @notice No precompile at 0x68 -- exactly the shape that used to pass silently.
    function testRejectsEmptyEvidenceReturn() public {
        vm.expectRevert(bytes("invalid double sign evidence return size"));
        slash.submitDoubleSignEvidence(hex"01", hex"02");
    }

    /// @notice Right size, wrong content: the guard must stand aside and let the real check
    ///         fire, otherwise the guard would have replaced a fail-open with a fail-closed
    ///         that also rejects every legitimate call.
    function testAcceptsExactEvidenceReturn() public {
        vm.mockCall(address(0x68), bytes(""), new bytes(52));
        // signer decodes to address(0); pin the migration lookup to "not migrated" so the
        // test names the check it expects rather than accepting any revert.
        vm.mockCall(
            address(0x2002),
            abi.encodeWithSignature("consensusToOperator(address)", address(0)),
            abi.encode(address(0))
        );

        vm.expectRevert(bytes("validator not migrated"));
        slash.submitDoubleSignEvidence(hex"01", hex"02");
    }
}
