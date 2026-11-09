// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface BSCValidatorSetTool {
    function INIT_VALIDATORSET_BYTES() external view returns (bytes memory);
    function decodePayloadHeader(bytes memory payload) external pure returns (bool, uint8, uint256, bytes memory);
    function decodeInitPayload(bytes memory payload)
        external
        pure
        returns (
            bool valid,
            address[] memory consensusAddrs,
            address[] memory feeAddrs,
            address[] memory bbcFeeAddrs,
            uint64[] memory votingPowers
        );
    function init() external pure;
}
