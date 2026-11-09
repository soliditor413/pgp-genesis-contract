pragma solidity 0.6.4;

import "../lib/0.6.x/RLPDecode.sol";
import "../lib/0.6.x/Memory.sol";

contract BSCValidatorSetTool {
    bytes public constant INIT_VALIDATORSET_BYTES =
        hex"f84580f842f840949fb29aac15b9a4b7f17c3385939b007540f4d791949fb29aac15b9a4b7f17c3385939b007540f4d791949fb29aac15b9a4b7f17c3385939b007540f4d79164";

    using RLPDecode for *;

    struct Validator {
        address consensusAddress;
        address payable feeAddress;
        address BBCFeeAddress;
        uint64 votingPower;
    }

    struct IbcValidatorSetPackage {
        uint8 packageType;
        Validator[] validatorSet;
    }

    function init() external pure {
        bool valid = decodeValidatorSetSynPackage(INIT_VALIDATORSET_BYTES);
        require(valid, "failed to init");
    }

    function decodeValidatorSetSynPackage(bytes memory msgBytes) internal pure returns (bool) {
        (, bool success) = decodeValidatorSet(msgBytes);
        return success;
    }

    /**
     * @notice CI gate: decode the exact payload the node would hand to
     *         `BSCValidatorSet.init(bytes,uint256)`, WITHOUT starting a chain.
     * @dev Mirrors `decodeValidator`'s index-to-field mapping exactly:
     *      idx0 = consensusAddress, idx1 = feeAddress, idx2 = BBCFeeAddress,
     *      idx3 = votingPower (flips `success`), idx4 = optional BLS vote address.
     *      A 4-tuple is therefore a valid payload -- that is the format we ship.
     *
     *      This is the only honest way to prove that "the bytes the Go encoder produced"
     *      and "the list written in validators.conf" are the same thing: the check runs on
     *      the real decoder, not on a re-implementation of it.
     *
     *      All three address slots are returned, not just the consensus one. idx1 and idx2
     *      are easy to swap -- both are addresses, the payload stays well-formed either way,
     *      and the mistake is invisible in every other test. Returning them separately is
     *      what lets the caller assert the ordering rather than assume it.
     * @return valid           true if the payload parsed end-to-end
     * @return consensusAddrs  consensus addresses **in payload order** (order is consensus-critical)
     * @return feeAddrs        feeAddress per entry, same order (tuple idx 1)
     * @return bbcFeeAddrs     BBCFeeAddress per entry, same order (tuple idx 2)
     * @return votingPowers    voting power per entry, same order
     */
    function decodeInitPayload(bytes memory payload)
        public
        pure
        returns (
            bool valid,
            address[] memory consensusAddrs,
            address[] memory feeAddrs,
            address[] memory bbcFeeAddrs,
            uint64[] memory votingPowers
        )
    {
        (IbcValidatorSetPackage memory pkg, bool ok) = decodeValidatorSet(payload);
        if (!ok) {
            return (false, new address[](0), new address[](0), new address[](0), new uint64[](0));
        }
        uint256 n = pkg.validatorSet.length;
        consensusAddrs = new address[](n);
        feeAddrs = new address[](n);
        bbcFeeAddrs = new address[](n);
        votingPowers = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            consensusAddrs[i] = pkg.validatorSet[i].consensusAddress;
            feeAddrs[i] = pkg.validatorSet[i].feeAddress;
            bbcFeeAddrs[i] = pkg.validatorSet[i].BBCFeeAddress;
            votingPowers[i] = pkg.validatorSet[i].votingPower;
        }
        return (true, consensusAddrs, feeAddrs, bbcFeeAddrs, votingPowers);
    }

    function decodeValidatorSet(bytes memory msgBytes)
        internal
        pure
        returns (IbcValidatorSetPackage memory, bool)
    {
        IbcValidatorSetPackage memory validatorSetPkg;

        RLPDecode.Iterator memory iter = msgBytes.toRLPItem().iterator();
        bool success = false;
        uint256 idx = 0;
        while (iter.hasNext()) {
            if (idx == 0) {
                validatorSetPkg.packageType = uint8(iter.next().toUint());
            } else if (idx == 1) {
                RLPDecode.RLPItem[] memory items = iter.next().toList();
                validatorSetPkg.validatorSet = new Validator[](items.length);
                for (uint256 j = 0; j < items.length; ++j) {
                    (Validator memory val, bool ok) = decodeValidator(items[j]);
                    if (!ok) {
                        return (validatorSetPkg, false);
                    }
                    validatorSetPkg.validatorSet[j] = val;
                }
                success = true;
            } else {
                break;
            }
            ++idx;
        }
        return (validatorSetPkg, success);
    }

    function decodeValidator(RLPDecode.RLPItem memory itemValidator) internal pure returns (Validator memory, bool) {
        Validator memory validator;
        RLPDecode.Iterator memory iter = itemValidator.iterator();
        bool success = false;
        uint256 idx = 0;
        while (iter.hasNext()) {
            if (idx == 0) {
                validator.consensusAddress = iter.next().toAddress();
            } else if (idx == 1) {
                validator.feeAddress = address(uint160(iter.next().toAddress()));
            } else if (idx == 2) {
                validator.BBCFeeAddress = iter.next().toAddress();
            } else if (idx == 3) {
                validator.votingPower = uint64(iter.next().toUint());
                success = true;
            } else {
                break;
            }
            ++idx;
        }
        return (validator, success);
    }

    // | type   | relayFee   |package  |
    // | 1 byte | 32 bytes   | bytes    |
    function decodePayloadHeader(bytes memory payload) public pure returns (bool, uint8, uint256, bytes memory) {
        if (payload.length < 33) {
            return (false, 0, 0, new bytes(0));
        }

        uint256 ptr;
        assembly {
            ptr := payload
        }

        uint8 packageType;
        ptr += 1;
        assembly {
            packageType := mload(ptr)
        }

        uint256 relayFee;
        ptr += 32;
        assembly {
            relayFee := mload(ptr)
        }

        ptr += 32;
        bytes memory msgBytes = new bytes(payload.length - 33);
        (uint256 dst,) = Memory.fromBytes(msgBytes);
        Memory.copy(ptr, dst, payload.length - 33);

        return (true, packageType, relayFee, msgBytes);
    }
}
