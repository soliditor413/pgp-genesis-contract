// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import "./utils/interface/IBSCValidatorSetTool.sol";

/**
 * @title C1-d golden test: the payload the Go node encoder produces must parse on
 *        the real Solidity decoder.
 *
 * @dev What is being proven, and what is not.
 *
 *      The fixture `test/fixtures/pgp_validators_6.hex` is written by
 *      `bsc(go)/consensus/parlia/testdata/pgp_validators_6.hex`, i.e. it is byte-for-byte
 *      what `pgpValidatorInitArgs` returns for the six devnet validators. This test feeds
 *      it to `BSCValidatorSetTool.decodeInitPayload`, which runs the same RLPDecode code
 *      and the same index-to-field mapping as `BSCValidatorSet.init` -> `decodeValidatorSet`
 *      -> `decodeValidator`.
 *
 *      So the chain of custody is:
 *
 *        Go encoder --writes--> fixture --reads--> Solidity decoder --assert--> same 6 addresses
 *
 *      Neither implementation is re-derived from the other, which is the only way this
 *      check has any value. A test that re-implemented the RLP layout in Solidity would
 *      agree with a wrong encoder as long as both were wrong the same way.
 *
 *      What it does NOT prove: that `BSCValidatorSet.init` was actually reached on chain.
 *      That is the H-block smoke test's job (V3/V6/V7 in the design doc), because it
 *      requires a running node.
 */
contract PGPValidatorInitTest is Test {
    /// @dev Same fixture the Go side writes. Kept as a path so a drift in either repo is a
    ///      test failure rather than a silently stale constant.
    string internal constant FIXTURE = "./test/fixtures/pgp_validators_6.hex";

    /// @dev Mirror of `devnetValidators` in
    ///      bsc(go)/consensus/parlia/pgp_validator_init_test.go, in configuration order.
    ///      Written in EIP-55 checksum form because solc rejects bare lowercase address
    ///      literals. The Go side and the genesis JSON use lowercase; `parsePGPValidatorAddress`
    ///      accepts both, and the checksum is not part of the value, so this is purely a
    ///      source-level concern -- the RLP payload still contains the same 20 bytes.
    address[6] internal devnetValidators = [
        0x53781E106a2e3378083bdcEdE1874E5c2a7225f8,
        0xd9758863F280c25B0D1F2f81705E3725Ccd5ac49,
        0x9B170f914eF3541cd29ee672a11c56d4b96b4B6F,
        0xFD7F1F6e2c5157A33ddA2e91f58f32862f864d70,
        0x8aEf2209EAb2f60BC13dA5e669aD832709f5e71D,
        0x05F9B7a73f6BA0298C5c1943204a6a54839166B2
    ];

    /// @dev keccak256 of the payload, as recorded in the design doc and reproduced
    ///      independently by bsc-genesis-contract/scripts/gen-pgp-genesis-config.py.
    bytes32 internal constant PINNED_PAYLOAD_HASH =
        0xe18ed4d5bd8063537f924de9a7700ec2343d4c5c48de231bc704d15aed46ce03;

    /// @dev Payload size for six 4-tuple validators:
    ///      3 (inner list header f9 018c) + 6 * 66 (f8 40 + 64 bytes of tuple)
    ///      + 3 (outer list header f9 0190) + 1 (packageType 0x80) = 403.
    ///      Written out in full rather than computed, so an encoder that changes the tuple
    ///      width fails here instead of silently producing a different payload.
    uint256 internal constant PAYLOAD_LEN = 403;

    BSCValidatorSetTool internal tool;
    bytes internal payload;

    function setUp() public {
        tool = BSCValidatorSetTool(deployCode("BSCValidatorSetTool.sol"));
        // vm.parseBytes requires a 0x prefix and no surrounding whitespace, which is why
        // the fixture is stored 0x-prefixed and trimmed here rather than in the file.
        payload = vm.parseBytes(vm.trim(vm.readFile(FIXTURE)));
    }

    /*//////////////////////////////////////////////////////////////
                            Fixture integrity
    //////////////////////////////////////////////////////////////*/

    /// @notice The fixture is what the design doc says it is.
    function testFixtureShape() public view {
        assertEq(payload.length, PAYLOAD_LEN, "payload length");

        // Outer RLP list, long form, 400 bytes of body: f9 01 90.
        assertEq(uint8(payload[0]), 0xf9, "outer list prefix");
        assertEq(uint8(payload[1]), 0x01, "outer list length hi");
        assertEq(uint8(payload[2]), 0x90, "outer list length lo (400)");

        // packageType 0 must be RLP's empty string (0x80), not a zero byte (0x00).
        // Both decode to 0, so only a byte-level assertion catches the difference.
        assertEq(uint8(payload[3]), 0x80, "packageType must be RLP empty string");
    }

    /// @notice The fixture hashes to the value pinned in the design doc.
    function testFixtureHash() public view {
        assertEq(keccak256(payload), PINNED_PAYLOAD_HASH, "payload hash drifted from the design doc");
    }

    /*//////////////////////////////////////////////////////////////
                          Decode: the real check
    //////////////////////////////////////////////////////////////*/

    /// @notice G1: the decoder recovers exactly the six configured consensus addresses,
    ///         in configuration order.
    /// @dev Order is consensus critical. `BSCValidatorSet.init` assigns
    ///      `currentValidatorSetMap[addr] = i + 1` while iterating the payload, and
    ///      `getMiningValidators` slices `currentValidatorSet[0..numOfCabinets)`, so a
    ///      permutation produces a valid state with a different mining order -- and a
    ///      different state root than every node that read the config in the right order.
    function testDecodeRecoversConsensusAddressesInOrder() public view {
        (bool valid, address[] memory consensus,,,) = tool.decodeInitPayload(payload);
        assertTrue(valid, "payload must decode");
        assertEq(consensus.length, devnetValidators.length, "validator count");

        for (uint256 i; i < devnetValidators.length; ++i) {
            assertEq(consensus[i], devnetValidators[i], _at("consensus address at index ", i));
        }
    }

    /// @notice G2: voting powers come back as configured.
    function testDecodeRecoversVotingPowers() public view {
        (,,,, uint64[] memory powers) = tool.decodeInitPayload(payload);
        assertEq(powers.length, devnetValidators.length, "power count");
        for (uint256 i; i < powers.length; ++i) {
            assertEq(uint256(powers[i]), 100, _at("voting power at index ", i));
        }
    }

    /// @notice G3: with no fee overrides, all three address slots hold the consensus
    ///         address -- i.e. the encoder does not leave idx1/idx2 empty.
    /// @dev An empty idx1 or idx2 would decode to address(0) and still "succeed", so this
    ///      is the assertion that catches a tuple built with fewer than four fields.
    function testDecodeFeeSlotsDefaultToConsensusAddress() public view {
        (,, address[] memory fee, address[] memory bbcFee,) = tool.decodeInitPayload(payload);
        assertEq(fee.length, devnetValidators.length, "fee count");
        for (uint256 i; i < devnetValidators.length; ++i) {
            assertEq(fee[i], devnetValidators[i], _at("fee address at index ", i));
            assertEq(bbcFee[i], devnetValidators[i], _at("bbcFee address at index ", i));
        }
    }

    /// @notice G3': a payload with distinct fee slots decodes with those slots in the
    ///         positions the contract names them.
    /// @dev This payload is built by hand here rather than by the Go encoder, because the
    ///      devnet config has no fee overrides. Its purpose is only to pin the decoder's
    ///      idx1/idx2 mapping, which the Go encoder's ordering test assumes but cannot see
    ///      through the decoder's field names.
    function testDecodeSeparatesFeeFromBbcFee() public view {
        address consensus = devnetValidators[0];
        address fee = address(0xF1);
        address bbcFee = address(0xF2);

        // RLP([0x80, [[consensus, fee, bbcFee, 100]]])
        bytes memory tuple = abi.encodePacked(hex"94", consensus, hex"94", fee, hex"94", bbcFee, hex"64");
        bytes memory validatorItem = _rlpList(tuple); // f8 40 + 64
        bytes memory validatorList = _rlpList(validatorItem); // f8 42 + 66
        bytes memory handBuilt = _rlpList(abi.encodePacked(hex"80", validatorList)); // f8 45 + 69

        (bool valid, address[] memory consensusAddrs, address[] memory feeAddrs, address[] memory bbcAddrs,) =
            tool.decodeInitPayload(handBuilt);
        assertTrue(valid, "hand-built payload must decode");
        assertEq(consensusAddrs.length, 1, "one validator");
        assertEq(consensusAddrs[0], consensus, "idx0 = consensus");
        assertEq(feeAddrs[0], fee, "idx1 = feeAddress");
        assertEq(bbcAddrs[0], bbcFee, "idx2 = BBCFeeAddress");
    }

    /*//////////////////////////////////////////////////////////////
                        Negative cases / honest limits
    //////////////////////////////////////////////////////////////*/

    /// @notice A truncated payload is silently accepted, and the last validator's voting
    ///         power silently becomes 0.
    /// @dev This started life as `testRejectsTruncatedPayload` and the assertion was
    ///      wrong: RLPDecode reads to the length *declared* in the list header, not to the
    ///      length actually supplied, so the missing tail bytes are read out of the memory
    ///      word padding as zeros. `toUint()` on a zero-length slice returns 0, which is a
    ///      legal voting power, so `decodeValidator` still reports success.
    ///
    ///      Measured (see the design doc, C1-d G4): chopping 1, 2, 3, 4 or 5 trailing bytes
    ///      all yield valid = true, 6 validators, correct addresses, and a final voting
    ///      power of 0. The payload only starts reverting once the cut reaches ~22 bytes and
    ///      eating into the third address breaks the string framing.
    ///
    ///      Why this matters: `BSCValidatorSet.init` has no length check and no
    ///      votingPower > 0 check, so the contract cannot notice a short payload. The only
    ///      defence against a malformed init payload is that the node's encoder is
    ///      deterministic and cross-checked byte for byte -- which is exactly what the
    ///      fixture in this test does. There is no contract-side safety net here, and it is
    ///      better to say so than to assert a guarantee that does not exist.
    function testTruncationIsSilentlyAccepted() public view {
        for (uint256 cut = 1; cut <= 5; ++cut) {
            bytes memory truncated = new bytes(payload.length - cut);
            for (uint256 i; i < truncated.length; ++i) {
                truncated[i] = payload[i];
            }
            (bool valid, address[] memory consensus,,, uint64[] memory powers) = tool.decodeInitPayload(truncated);

            assertTrue(valid, _at("a payload short by N bytes still decodes, cut=", cut));
            assertEq(consensus.length, devnetValidators.length, "the validator list is unchanged");
            assertEq(consensus[consensus.length - 1], devnetValidators[devnetValidators.length - 1], "last address");
            assertEq(uint256(powers[powers.length - 1]), 0, "and the last voting power became 0");
        }
    }

    /// @notice A single flipped address byte is NOT rejected -- it decodes into a
    ///         different validator.
    /// @dev This is the failure mode the whole C1-c/C1-d exercise exists to catch, stated
    ///      plainly: the decoder has no checksum and no cross-field invariant that a wrong
    ///      address would violate. It cannot tell "the payload I was given" from "a payload
    ///      with one corrupted byte". Cross-implementation byte equality (Go vs Python vs
    ///      JS, and this fixture) is the only defence, because the contract will happily
    ///      accept either and produce two different chains.
    ///
    ///      Byte offsets in the fixture (verified by flipping each of them in turn):
    ///        0..2   outer list header  f9 01 90
    ///        3      packageType        80
    ///        4..6   inner list header  f9 01 8c
    ///        7..8   first tuple header f8 40
    ///        9      string prefix      94
    ///        10..29 first consensus address
    ///      Flipping any of 0..9 breaks the framing and reverts; flipping 10..29 decodes
    ///      cleanly into a different address.
    function testCorruptedAddressDecodesAsDifferentValidator() public view {
        bytes memory corrupted = bytes(payload);
        corrupted[10] = bytes1(uint8(corrupted[10]) ^ 0x01);

        (bool valid, address[] memory consensus,,,) = tool.decodeInitPayload(corrupted);
        assertTrue(valid, "a corrupted address still decodes -- the decoder has no checksum");
        assertTrue(consensus[0] != devnetValidators[0], "the corruption changed the address");
        assertEq(consensus.length, devnetValidators.length, "and the shape is unchanged");
    }

    /// @notice Flipping a list or string header reverts, which is the one thing the
    ///         decoder does defend: its own RLP framing must stay walkable.
    /// @dev Measured over every header byte (offsets 0..9 of the fixture, XOR 0x01). The
    ///      set below is exactly the set that reverts. Offsets 1, 2, 3 and 5 do not, and
    ///      are covered by the two tests that follow -- they are the interesting ones,
    ///      because they show what the decoder does *not* defend.
    function testFramingCorruptionReverts() public {
        uint256[6] memory reverting = [uint256(0), 4, 6, 7, 8, 9];
        for (uint256 k; k < reverting.length; ++k) {
            bytes memory corrupted = bytes(payload);
            corrupted[reverting[k]] = bytes1(uint8(corrupted[reverting[k]]) ^ 0x01);
            vm.expectRevert();
            tool.decodeInitPayload(corrupted);
        }
    }

    /// @notice Corrupting the inner list's length byte silently *shrinks* the validator
    ///         set: the payload still decodes, reporting 3 validators instead of 6.
    /// @dev This is the sharpest demonstration that there is no safety net. Byte 5 is the
    ///      low byte of the inner list header (`f9 01 8c` -> `f9 01 8d`), i.e. the declared
    ///      body length goes from 396 to 397, one byte short of the third tuple's end. The
    ///      iterator walks what fits and stops, so `decodeValidatorSet` returns
    ///
    ///          success = true, validatorSet.length = 3
    ///
    ///      and `BSCValidatorSet.init` would accept it, because its only guard is
    ///      `require(length > 0)`. A chain that initialised from this payload would come up
    ///      with half its validators, no error, and a state root nobody else reproduces.
    ///
    ///      Practical consequence: the init payload's integrity rests entirely on the
    ///      encoder being deterministic and cross-checked, never on the contract. That is
    ///      why the fixture in test/fixtures/ is generated by the node's own encoder rather
    ///      than hand-written.
    function testInnerLengthByteSilentlyShrinksValidatorSet() public view {
        bytes memory corrupted = bytes(payload);
        corrupted[5] = bytes1(uint8(corrupted[5]) ^ 0x01);

        (bool valid, address[] memory consensus,,,) = tool.decodeInitPayload(corrupted);
        assertTrue(valid, "the corrupted payload still decodes");
        assertEq(consensus.length, 3, "and reports only 3 of the 6 validators");
        assertEq(consensus[0], devnetValidators[0], "the first three are still intact");
        assertEq(consensus[2], devnetValidators[2], "through index 2");
    }

    /// @notice Flipping the outer length bytes (offsets 1 and 2) is also accepted, because
    ///         the outer list simply contains fewer or more of the bytes that follow.
    /// @dev Asserted as "does not revert" rather than pinned to a shape: the exact result
    ///      depends on how much slack the padding provides, which is an implementation
    ///      detail of RLPDecode rather than a property anyone should rely on. What matters
    ///      is the negative result -- the decoder does not reject it.
    function testOuterLengthByteCorruptionIsAccepted() public {
        for (uint256 i = 1; i <= 2; ++i) {
            bytes memory corrupted = bytes(payload);
            corrupted[i] = bytes1(uint8(corrupted[i]) ^ 0x01);
            tool.decodeInitPayload(corrupted); // must not revert
        }
    }

    /// @notice An empty validator list decodes successfully; the guard is `init`'s
    ///         `require(length > 0)`, not the decoder.
    /// @dev Worth pinning because it locates the check: someone reading the decoder would
    ///      reasonably conclude an empty list is rejected there, and it is not.
    function testEmptyValidatorListDecodesButInitWouldRevert() public view {
        // RLP([0x80, []]) = c2 80 c0
        (bool valid, address[] memory consensus,,,) = tool.decodeInitPayload(hex"c280c0");
        assertTrue(valid, "empty list decodes");
        assertEq(consensus.length, 0, "and yields zero validators");
        // BSCValidatorSet.init: require(validatorSetPkg.validatorSet.length > 0, "empty validator set")
    }

    /// @notice packageType is carried but never validated, on either side.
    /// @dev Neither BSCValidatorSetTool.decodeValidatorSet nor BSCValidatorSet.decodeValidatorSet
    ///      dispatches on packageType -- both read it into the struct and move on. So a
    ///      non-zero packageType is accepted.
    ///
    ///      It is still worth pinning the byte: the payload is the calldata of a system
    ///      transaction, so it feeds the transaction hash, hence the receipt, hence
    ///      receiptsRoot, hence the block hash. A wrong packageType does not change state
    ///      but it does change every block hash from ForkHeight onwards, i.e. it forks the
    ///      chain -- and nothing on the contract side would stop it.
    function testNonZeroPackageTypeStillDecodes() public view {
        bytes memory flipped = bytes(payload);
        flipped[3] = 0x01;

        (bool valid, address[] memory consensus,,,) = tool.decodeInitPayload(flipped);
        assertTrue(valid, "packageType is not validated by the decoder");
        assertEq(consensus.length, devnetValidators.length, "the rest still parses");
    }

    /*//////////////////////////////////////////////////////////////
                         G6: mainnet-sized set
    //////////////////////////////////////////////////////////////*/

    /// @notice G6: a 21-seat set goes through the same encoder and the same decoder.
    /// @dev The point is not the addresses -- they are synthetic -- but that nothing on
    ///      either side assumes a particular set size. A hardcoded 6 or 21 in the tuple
    ///      loop, the count byte, or the RLP header width shows up here and nowhere else,
    ///      because in a single-size test the wrong constant usually equals the right one.
    ///
    ///      The 21 addresses are keccak256 of "pgp-devnet-validator-00".."20", truncated to
    ///      their low 20 bytes -- regenerated here from the same rule rather than pasted in
    ///      as 21 magic constants, so the test states what the fixture contains.
    function testDecodeTwentyOneValidators() public view {
        bytes memory p21 = vm.parseBytes(vm.trim(vm.readFile("./test/fixtures/pgp_validators_21.hex")));

        // 3 (outer header) + 1 (packageType) + 3 (inner header) + 21 * 66.
        // Both list headers widen to two bytes once the body exceeds 55 bytes, which is
        // exactly where an off-by-one in the RLP header would hide.
        assertEq(p21.length, 1393, "21-seat payload length");
        assertEq(uint8(p21[0]), 0xf9, "outer header prefix");
        assertEq(uint8(p21[3]), 0x80, "packageType");

        (bool valid, address[] memory consensus,,, uint64[] memory powers) = tool.decodeInitPayload(p21);
        assertTrue(valid, "21-seat payload must decode");
        assertEq(consensus.length, 21, "validator count");

        for (uint256 i; i < 21; ++i) {
            address want = address(uint160(uint256(keccak256(bytes(_label(i))))));
            assertEq(consensus[i], want, _at("synthetic validator at index ", i));
            assertEq(uint256(powers[i]), 100, _at("voting power at index ", i));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                Helpers
    //////////////////////////////////////////////////////////////*/

    /// @dev "pgp-devnet-validator-%02d" with zero padding, matching the Go generator.
    function _label(uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked("pgp-devnet-validator-", i < 10 ? "0" : "", _toString(i)));
    }

    /// @dev Minimal RLP list encoder, sufficient for bodies up to 255 bytes. Only used to
    ///      build the hand-written fixture above -- never to second-guess the decoder.
    function _rlpList(bytes memory body) internal pure returns (bytes memory) {
        require(body.length <= 0xff, "body too long for this helper");
        if (body.length <= 55) {
            return abi.encodePacked(bytes1(uint8(0xc0 + body.length)), body);
        }
        return abi.encodePacked(hex"f8", uint8(body.length), body);
    }

    function _at(string memory prefix, uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked(prefix, _toString(i)));
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
