// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

/**
 * @title C1-d G4: exercise `BSCValidatorSet.init` itself, not just the decoder.
 *
 * @dev Why this file exists separately from PGPValidatorInit.t.sol.
 *
 *      PGPValidatorInit.t.sol proves the *decoder* turns the Go encoder's bytes into the
 *      right six addresses. It calls `BSCValidatorSetTool.decodeInitPayload`, which is a
 *      pure helper -- it has no storage, no `onlyNotInit`, no `require` guards.
 *
 *      So none of the following was covered by anything:
 *
 *        - `init`'s four `require`s, and the order they fire in
 *        - whether a rejected `init` leaves the contract retryable
 *        - `numOfCabinets` actually landing in storage
 *        - `getMiningValidators()` right after init (the path parlia walks every block)
 *        - the second `init` on an already-initialised contract
 *
 *      That last point matters at the fork: if the H block is ever re-executed -- a
 *      reorg across the fork, a re-import after a bad restart -- the node replays the
 *      same system transactions. `onlyNotInit` is the only thing standing between that
 *      and a silently doubled validator set.
 *
 * @dev Why a bare deployment is enough -- once setUp pins two values.
 *
 *      `init` touches exactly four storage slots: `currentValidatorSet`,
 *      `currentValidatorSetMap`, `numOfCabinets`, `alreadyInit`. It reads no other system
 *      contract. It does read `block.coinbase` and `tx.gasprice`, but only through the
 *      onlyCoinbase / onlyZeroGasPrice gates, so `setUp` pins both to the values the node
 *      uses (coinbase == msg.sender, gasprice == 0) and the body is then exercised exactly
 *      as the deploy height exercises it. That keeps `deployCode` on a blank forge VM
 *      faithful, and avoids the `Deployer.sol` harness which asserts `block.chainid == 56`
 *      and etches 17 contracts at fixed addresses -- none of which `init` looks at.
 *
 *      Cross-version note: this file is ^0.8.10 while BSCValidatorSet.sol is 0.6.4, so the
 *      contract is referenced through a hand-written interface and obtained via
 *      `deployCode` rather than `import`. Importing it would drag the whole 0.6.4 tree into
 *      this compilation unit.
 */
interface IBSCValidatorSetInit {
    function init(bytes calldata initValidatorSetBytes, uint256 initNumOfCabinets) external;

    function alreadyInit() external view returns (bool);

    function numOfCabinets() external view returns (uint256);

    // Public array-of-struct getter: one tuple per validator, fields in declaration order.
    function currentValidatorSet(
        uint256 index
    ) external view returns (address consensusAddress, address feeAddress, address bbcFeeAddress, uint64 votingPower, bool jailed, uint256 incoming);

    function getValidators() external view returns (address[] memory);

    function getMiningValidators() external view returns (address[] memory, bytes[] memory);

    function getTurnLength() external view returns (uint256);
}

contract PGPValidatorSetInitTest is Test {
    /// @dev Same fixture the Go encoder writes, same bytes PGPValidatorInit.t.sol reads.
    string internal constant FIXTURE = "./test/fixtures/pgp_validators_6.hex";

    /// @dev Configuration order, mirroring bsc(go)/consensus/parlia `devnetValidators`.
    ///      EIP-55 form because solc rejects bare lowercase address literals; the value is
    ///      identical, the checksum is not part of the 20 bytes that go into the payload.
    address[6] internal devnetValidators = [
        0x53781E106a2e3378083bdcEdE1874E5c2a7225f8,
        0xd9758863F280c25B0D1F2f81705E3725Ccd5ac49,
        0x9B170f914eF3541cd29ee672a11c56d4b96b4B6F,
        0xFD7F1F6e2c5157A33ddA2e91f58f32862f864d70,
        0x8aEf2209EAb2f60BC13dA5e669aD832709f5e71D,
        0x05F9B7a73f6BA0298C5c1943204a6a54839166B2
    ];

    IBSCValidatorSetInit internal validatorSet;
    bytes internal payload;

    function setUp() public {
        // The node initialises from SystemAddress with block.coinbase == SystemAddress and a
        // zero gas price; core/pgp_systemcontract_deploy.go builds its own block context for
        // exactly this reason. A direct call in a forge test comes from this contract, so
        // pinning coinbase to it reproduces the legitimate path instead of the gate.
        vm.coinbase(address(this));
        vm.txGasPrice(0);

        // Fresh contract per test: these assertions are about storage transitions, so a
        // shared instance would make every test depend on execution order.
        validatorSet = IBSCValidatorSetInit(deployCode("BSCValidatorSet.sol"));
        payload = vm.parseBytes(vm.trim(vm.readFile(FIXTURE)));
    }

    /*//////////////////////////////////////////////////////////////
                      G4: the numOfCabinets guard
    //////////////////////////////////////////////////////////////*/

    /// @notice G4: `init(payload, 0)` reverts, and reverts for the cabinets reason.
    /// @dev `numOfCabinets == 0` is not merely useless, it is actively broken: every
    ///      consumer computes `validators.length - numOfCabinets` or slices
    ///      `[0, numOfCabinets)`. Zero makes the first a no-op subtraction and the second
    ///      an empty slice, so `getMiningValidators()` would return nobody and the chain
    ///      would stall one block after the fork with no log pointing at the cause.
    ///      Catching it at init time turns a silent stall into a startup failure.
    function testG4ZeroCabinetsReverts() public {
        vm.expectRevert(bytes("numOfCabinets must be positive"));
        validatorSet.init(payload, 0);
    }

    /// @notice A rejected `init` must leave the contract untouched, i.e. retryable.
    /// @dev This is what makes a mistyped genesis recoverable: the node fails the H block,
    ///      the operator fixes the config and restarts, and the retry has to succeed. If
    ///      `init` set `alreadyInit = true` before validating, the corrected retry would
    ///      hit `onlyNotInit` and the chain would be stuck for good.
    ///
    ///      Solidity's revert already guarantees state rollback, so this test is really
    ///      pinning the absence of a `try`/`catch` or a low-level call in the path -- i.e.
    ///      it fails the day someone "improves" init by swallowing the error.
    function testZeroCabinetsLeavesContractRetryable() public {
        vm.expectRevert(bytes("numOfCabinets must be positive"));
        validatorSet.init(payload, 0);

        assertFalse(validatorSet.alreadyInit(), "alreadyInit must stay false after a revert");
        assertEq(validatorSet.numOfCabinets(), 0, "numOfCabinets must stay zero");
        assertEq(validatorSet.getValidators().length, 0, "no validator may be stored");

        // The corrected retry -- same payload, cabinets fixed -- has to work.
        validatorSet.init(payload, 6);

        assertTrue(validatorSet.alreadyInit(), "retry must take effect");
        assertEq(validatorSet.numOfCabinets(), 6, "retry must store cabinets");
        assertEq(validatorSet.getValidators().length, 6, "retry must store validators");
    }

    /// @notice The cabinets check runs *before* the payload is decoded.
    /// @dev Ordering is observable and worth pinning, because the two failure modes mean
    ///      very different things to an operator: "numOfCabinets must be positive" is a
    ///      node-config bug, "failed to parse init validatorSet" is an encoder bug. With a
    ///      garbage payload and zero cabinets together, the message must name the config,
    ///      since that is the check that actually fired.
    function testCabinetsCheckPrecedesDecode() public {
        bytes memory garbage = hex"deadbeef";

        vm.expectRevert(bytes("numOfCabinets must be positive"));
        validatorSet.init(garbage, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      Happy path: the six devnet seats
    //////////////////////////////////////////////////////////////*/

    /// @notice The payload the Go encoder emits initialises exactly the configured set.
    /// @dev This is the end state parlia reads on every subsequent block, so it is asserted
    ///      field by field rather than by count: order, addresses, and voting power.
    function testInitStoresSixValidatorsInOrder() public {
        validatorSet.init(payload, 6);

        assertTrue(validatorSet.alreadyInit(), "alreadyInit");
        assertEq(validatorSet.numOfCabinets(), 6, "numOfCabinets");

        address[] memory validators = validatorSet.getValidators();
        assertEq(validators.length, devnetValidators.length, "validator count");

        for (uint256 i; i < devnetValidators.length; ++i) {
            assertEq(validators[i], devnetValidators[i], _at("consensus address at index ", i));

            (
                address consensus,
                address fee,
                address bbcFee,
                uint64 power,
                bool jailed,
                uint256 incoming
            ) = validatorSet.currentValidatorSet(i);
            assertEq(consensus, devnetValidators[i], _at("stored consensus address at index ", i));
            // The 4-tuple carries feeAddr == consensusAddr and bbcFeeAddr == consensusAddr,
            // which is what the Go encoder packs. Not independently interesting, but it is
            // where a future 5-tuple encoder would first diverge.
            assertEq(fee, devnetValidators[i], _at("stored fee address at index ", i));
            assertEq(bbcFee, devnetValidators[i], _at("stored bbcFee address at index ", i));
            assertEq(uint256(power), 100, _at("stored voting power at index ", i));
            assertFalse(jailed, _at("jailed at index ", i));
            assertEq(incoming, 0, _at("incoming at index ", i));
        }
    }

    /// @notice `getMiningValidators()` -- the call parlia makes every block -- works right
    ///         after init, with the zero-BLS vote addresses.
    /// @dev `numOfCabinets == validators.length` takes the early return in
    ///      getMiningValidators, so no shuffle runs. That is the devnet shape: everyone
    ///      mines, there are no standby candidates.
    ///
    ///      `voteAddrs` being six empty byte strings is the BEP-126 zero-BLS path. Parlia
    ///      unpacks these into `[]types.BLSPublicKey`; the Go side was verified separately
    ///      to accept empty entries and yield 48 zero bytes each. Asserting the emptiness
    ///      here keeps the contract side of that agreement honest -- a 4-tuple payload must
    ///      never produce a non-empty vote address.
    function testMiningValidatorsAfterInit() public {
        validatorSet.init(payload, 6);

        (address[] memory mining, bytes[] memory voteAddrs) = validatorSet.getMiningValidators();

        assertEq(mining.length, 6, "mining validator count");
        for (uint256 i; i < 6; ++i) {
            assertEq(mining[i], devnetValidators[i], _at("mining order at index ", i));
        }
        assertEq(voteAddrs.length, 6, "vote address count");
        for (uint256 i; i < 6; ++i) {
            assertEq(voteAddrs[i].length, 0, _at("vote address must be empty at index ", i));
        }

        // turnLength is not set by init and getTurnLength maps 0 -> 1. This is the value
        // that feeds `minerHistoryCheckLen = (N/2+1) * TurnLength - 1` on the node, i.e.
        // 6 seats with turnLength 1 gives a check length of 3 -- the number that decided
        // the first validator-set switch lands on block 203, not 200.
        assertEq(validatorSet.getTurnLength(), 1, "default turnLength");
    }

    /*//////////////////////////////////////////////////////////////
                     The already-init guard (fork safety)
    //////////////////////////////////////////////////////////////*/

    /// @notice A second `init` reverts: the H block is not replayable into a doubled set.
    /// @dev Reachable in practice on a reorg across the fork height, or when a node
    ///      re-imports blocks after an unclean restart. Without `onlyNotInit`, the second
    ///      pass would append six more entries, `currentValidatorSetMap` would point at the
    ///      duplicates, and `getMiningValidators` would slice the first twelve.
    function testSecondInitReverts() public {
        validatorSet.init(payload, 6);

        vm.expectRevert(bytes("the contract already init"));
        validatorSet.init(payload, 6);
    }

    /// @notice After init, the guard fires before the cabinets check.
    /// @dev Modifier-before-body: `onlyNotInit` wraps the whole function, so the
    ///      "numOfCabinets must be positive" require is never reached on an initialised
    ///      contract. Worth a test because it decides which message a replaying node
    ///      logs -- and "the contract already init" is the one that tells an operator the
    ///      block really was a duplicate, rather than suggesting the config is wrong.
    function testAlreadyInitBeatsCabinetsCheck() public {
        validatorSet.init(payload, 6);

        vm.expectRevert(bytes("the contract already init"));
        validatorSet.init(payload, 0);
    }

    /*//////////////////////////////////////////////////////////////
          Malformed payloads: which ones init rejects, which it accepts
    //////////////////////////////////////////////////////////////*/

    /// @notice An outer list with only `packageType` and no validator list is rejected.
    /// @dev `decodeValidatorSet` sets `success = true` only inside the `idx == 1` branch, so
    ///      a one-element outer list returns `valid == false` and `init` trips
    ///      `require(valid, "failed to parse init validatorSet")`. RLP([0x80]) = c1 80.
    ///
    ///      This is the one malformed shape that fails *cleanly* -- the payload is not
    ///      interpreted at all. Contrast with PGPValidatorInit.t.sol's truncation test,
    ///      where a payload cut short keeps decoding into a shorter-but-valid set.
    function testOuterListWithoutValidatorListReverts() public {
        vm.expectRevert(bytes("failed to parse init validatorSet"));
        validatorSet.init(hex"c180", 6);
    }

    /// @notice A 3-tuple validator is rejected by init -- the decoder needs the 4th field.
    /// @dev `decodeValidator` sets `success = true` *at* idx == 3, not after the loop, so a
    ///      tuple of [consensus, fee, bbcFee] returns ok == false and the whole set fails.
    ///      This is the safety net that would catch an encoder regression from 4-tuple to
    ///      3-tuple: it fails loudly at the H block instead of initialising a set with
    ///      votingPower 0 (which, unlike a missing voting power, is itself legal).
    ///
    ///      Payload: RLP([0x80, [[addr, addr, addr]]]).
    function testThreeTupleValidatorReverts() public {
        address a = devnetValidators[0];
        bytes memory tuple = _rlpList(abi.encodePacked(hex"94", a, hex"94", a, hex"94", a));
        bytes memory body = abi.encodePacked(hex"80", _rlpList(tuple));

        vm.expectRevert(bytes("failed to parse init validatorSet"));
        validatorSet.init(_rlpList(body), 6);
    }

    /// @notice An empty validator list decodes, then dies on init's own length guard.
    /// @dev Two separate gates, two separate messages. The decoder is happy with
    ///      `RLP([0x80, []])`; `require(validatorSetPkg.validatorSet.length > 0)` is what
    ///      rejects it. Anyone auditing the decoder alone would think an empty set was
    ///      handled there. It is not.
    function testEmptyValidatorListRevertsInInit() public {
        vm.expectRevert(bytes("empty validator set"));
        validatorSet.init(hex"c280c0", 6);
    }

    /// @notice A payload truncated mid-set still initialises -- the contract has no
    ///         length or voting-power safety net.
    /// @dev Same finding as PGPValidatorInit.t.sol's truncation test, but asserted at the
    ///      init level, which is what actually matters: the result is a *shorter, accepted*
    ///      validator set. Cutting the last 5 bytes off the 403-byte payload keeps all six
    ///      addresses and zeroes the last voting power, because RLPDecode walks the
    ///      declared list length and reads zero-filled memory past the buffer end, and
    ///      `toUint()` on a zero-length slice returns 0 -- a legal voting power.
    ///
    ///      There is no fix on the contract side (the fork block's calldata is consensus
    ///      data, and matching the node's encoder exactly is the contract's only job).
    ///      The mitigation is the cross-repo fixture check plus the pinned payload hash:
    ///      a truncated encoder is caught before it ever reaches a chain.
    function testTruncatedPayloadInitialisesShorterSet() public {
        bytes memory cut = new bytes(payload.length - 5);
        for (uint256 i; i < cut.length; ++i) {
            cut[i] = payload[i];
        }

        validatorSet.init(cut, 6);

        assertTrue(validatorSet.alreadyInit(), "truncated payload is accepted, not rejected");
        address[] memory validators = validatorSet.getValidators();
        assertEq(validators.length, 6, "all six addresses survive the truncation");
        for (uint256 i; i < 6; ++i) {
            assertEq(validators[i], devnetValidators[i], _at("address at index ", i));
        }

        (, , , uint64 lastPower, , ) = validatorSet.currentValidatorSet(5);
        assertEq(uint256(lastPower), 0, "the trailing bytes lost are the last voting power");
    }

    /*//////////////////////////////////////////////////////////////
                    F-03: the caller gate and the size cap
    //////////////////////////////////////////////////////////////*/

    /// @notice An ordinary transaction cannot call init, even with the right calldata.
    /// @dev This is the whole point of the gate: at the deploy height the protocol has
    ///      already run init before any transaction is executed, so a plain user call can
    ///      only ever be an attempt to get there first. Whoever wins that race fixes the
    ///      validator set for good -- `alreadyInit` cannot be undone and `_setProtector`
    ///      style governance is not available on this contract.
    function testInitRejectsNonCoinbaseCaller() public {
        vm.coinbase(address(0xBEEF));

        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("the message sender must be the block producer"));
        validatorSet.init(payload, 6);
    }

    /// @notice Even the block producer cannot call init inside a priced transaction.
    /// @dev onlyCoinbase alone would be satisfied by any validator including this call in
    ///      its own block; onlyZeroGasPrice is what makes it a system call rather than
    ///      something a producer can hide among user transactions.
    function testInitRejectsNonZeroGasPrice() public {
        vm.txGasPrice(1);

        vm.expectRevert(bytes("gasprice is not zero"));
        validatorSet.init(payload, 6);
    }

    /// @notice A rejected caller must leave the contract retryable.
    /// @dev Modifiers run before the body, so a gate rejection writes nothing. Pinned
    ///      because the opposite -- flipping alreadyInit and then failing -- would turn a
    ///      blocked attacker into a permanently uninitialisable contract.
    function testRejectedCallerLeavesContractRetryable() public {
        vm.coinbase(address(0xBEEF));
        vm.prank(address(0xCAFE));
        vm.expectRevert(bytes("the message sender must be the block producer"));
        validatorSet.init(payload, 6);

        assertFalse(validatorSet.alreadyInit(), "a rejected caller must not consume the init");
        assertEq(validatorSet.getValidators().length, 0, "a rejected caller must store nothing");

        vm.coinbase(address(this));
        validatorSet.init(payload, 6);
        assertTrue(validatorSet.alreadyInit(), "the legitimate call still has to work");
    }

    /// @notice A set larger than 255 is rejected.
    /// @dev The node writes the count into a single byte of the header extra field
    ///      (`append(header.Extra, byte(len(newValidators)))`), so 256 wraps to 0 and the
    ///      header can never be parsed back. pgpinit refuses to encode such a payload
    ///      (maxPGPGenesisValidators = 255); this asserts the contract refuses it too, so a
    ///      second encoder written later cannot slip past.
    function testInitRejectsOversizedSet() public {
        uint256 n = 256;
        // Minimal legal 4-tuple: [consensus, fee, bbcFee, votingPower] = 64 bytes.
        bytes memory one = _rlpList(
            abi.encodePacked(
                hex"94",
                devnetValidators[0],
                hex"94",
                devnetValidators[0],
                hex"94",
                devnetValidators[0],
                hex"01"
            )
        );
        bytes memory all = new bytes(one.length * n);
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < one.length; ++j) {
                all[i * one.length + j] = one[j];
            }
        }
        bytes memory body = abi.encodePacked(hex"80", _rlpList(all));

        vm.expectRevert(bytes("validator set too large"));
        validatorSet.init(_rlpList(body), n);
    }

    /*//////////////////////////////////////////////////////////////
                    G6: the mainnet-sized set through init
    //////////////////////////////////////////////////////////////*/

    /// @notice G6: a 21-seat payload initialises, and `getMiningValidators()` returns all
    ///         twenty-one.
    /// @dev This closes the last gap on G6. Up to now the 21-seat case was only proven at
    ///      the decoder (`testDecodeTwentyOneValidators`); `getMiningValidators()` was never
    ///      driven by a real `init` for anything but six seats. The two sizes exercise
    ///      different branches in that function:
    ///
    ///        validators.length <= numOfCabinets  -> early return (devnet, 6 of 6)
    ///        validators.length >  numOfCabinets  -> candidate shuffle branch (mainnet)
    ///
    ///      With 21 of 21 the early return is taken again, so this still is not the shuffle
    ///      path -- that needs `numOfCabinets < validators.length`, i.e. BEP-131 standby
    ///      candidates, which the pgp config does not have. Worth stating plainly rather
    ///      than letting a green 21-seat test imply the candidate logic is covered.
    ///
    ///      The value here is the size independence: no hardcoded 6 or 21 survives in the
    ///      init loop, the count byte, or the RLP header width for the mainnet shape either.
    function testTwentyOneSeatMiningValidators() public {
        bytes memory p21 = vm.parseBytes(vm.trim(vm.readFile("./test/fixtures/pgp_validators_21.hex")));

        validatorSet.init(p21, 21);

        assertEq(validatorSet.numOfCabinets(), 21, "numOfCabinets");

        (address[] memory mining, bytes[] memory voteAddrs) = validatorSet.getMiningValidators();
        assertEq(mining.length, 21, "mining validator count");
        assertEq(voteAddrs.length, 21, "vote address count");

        for (uint256 i; i < 21; ++i) {
            // Same synthetic derivation the Go generator uses: keccak256 of the label,
            // truncated to the low 20 bytes. Re-derived rather than pasted so this test
            // states what the fixture holds instead of encoding 21 magic constants.
            address want = address(uint160(uint256(keccak256(bytes(_label(i))))));
            assertEq(mining[i], want, _at("21-seat mining address at index ", i));
            assertEq(voteAddrs[i].length, 0, _at("21-seat vote address must be empty at index ", i));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev "pgp-devnet-validator-%02d" with zero padding, matching the Go generator.
    function _label(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked("pgp-devnet-validator-", i < 10 ? "0" : "", _toString(i)));
    }

    /// @dev Minimal RLP list encoder. Handles bodies up to 65535 bytes, which covers the
    ///      hand-built malformed payloads above and the 256-seat oversize case (16,896
    ///      bytes); deliberately not a general RLP implementation.
    function _rlpList(bytes memory body) internal pure returns (bytes memory) {
        if (body.length <= 55) {
            return abi.encodePacked(bytes1(uint8(0xc0 + body.length)), body);
        }
        if (body.length <= 0xff) {
            return abi.encodePacked(hex"f8", uint8(body.length), body);
        }
        require(body.length <= 0xffff, "body too long for this helper");
        return abi.encodePacked(hex"f9", uint16(body.length), body);
    }

    function _at(string memory prefix, uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked(prefix, _toString(i)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        bytes memory buffer = new bytes(20);
        uint256 digits;
        while (value != 0) {
            digits++;
            buffer[20 - digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        bytes memory out = new bytes(digits);
        for (uint256 i; i < digits; ++i) {
            out[i] = buffer[20 - digits + i];
        }
        return string(out);
    }
}
