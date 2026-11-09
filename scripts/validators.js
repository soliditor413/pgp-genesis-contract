const web3 = require('web3');
const RLP = require('rlp');

// Configure
const validators = [
  {
    consensusAddr: '0x9fB29AAc15b9A4B7F17c3385939b007540f4d791',
    feeAddr: '0x9fB29AAc15b9A4B7F17c3385939b007540f4d791',
    bscFeeAddr: '0x9fB29AAc15b9A4B7F17c3385939b007540f4d791',
    votingPower: 0x0000000000000064,
  },
];
const bLSPublicKeys = [
  '0x85e6972fc98cd3c81d64d40e325acfed44365b97a7567a27939c14dbc7512ddcf54cb1284eb637cfa308ae4e00cb5588',
];

// ======== Do not edit below ========
function generateExtraData(validators) {
  let extraVanity = Buffer.alloc(32);
  let validatorsBytes = extraDataSerialize(validators);
  let extraSeal = Buffer.alloc(65);
  return Buffer.concat([extraVanity, validatorsBytes, extraSeal]);
}

function extraDataSerialize(validators) {
  let n = validators.length;
  let arr = [];
  for (let i = 0; i < n; i++) {
    let validator = validators[i];
    arr.push(Buffer.from(web3.utils.hexToBytes(validator.consensusAddr)));
  }
  return Buffer.concat(arr);
}

// NOTE: address strings must be turned into bytes before RLP encoding.
// `rlp` (v2.2.7) treats a JS string as UTF-8, so passing '0x1234...' as-is yields a
// 40-char ASCII blob instead of a 20-byte address. packageType stays the JS number 0,
// which RLP encodes as 0x80 (empty string) -- matching BSC mainnet, not 0x00.
// Ground truth: the 1-validator fixture in extension/BSCValidatorSetTool.sol decodes as
// `f845 80 f842 f840 94<20> 94<20> 94<20> 64`.
function validatorUpdateRlpEncode(validators, bLSPublicKeys) {
  let n = validators.length;
  let vals = [];
  for (let i = 0; i < n; i++) {
    vals.push([
      web3.utils.hexToBytes(validators[i].consensusAddr),
      web3.utils.hexToBytes(validators[i].bscFeeAddr),
      web3.utils.hexToBytes(validators[i].feeAddr),
      validators[i].votingPower,
      bLSPublicKeys[i],
    ]);
  }
  let pkg = [0x00, vals];
  return web3.utils.bytesToHex(RLP.encode(pkg));
}

extraValidatorBytes = generateExtraData(validators);
validatorSetBytes = validatorUpdateRlpEncode(validators, bLSPublicKeys);

exports = module.exports = {
  extraValidatorBytes: extraValidatorBytes,
  validatorSetBytes: validatorSetBytes,
};
