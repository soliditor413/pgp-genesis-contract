const RLP = require('rlp');
const fs = require('fs');
const lines = fs.readFileSync('scripts/validators-dev.conf','utf8').split('\n').filter(l=>l.trim());
const vals = lines.map(l=>{ const [consensus, fee, bscFee, power] = l.split(',').map(s=>s.trim()); return {consensus,fee,bscFee,power}; });
const buf = h => Buffer.from(h.replace(/^0x/,''),'hex');
// C) packageType 用 number 0（=> 0x80）；地址/power 用 Buffer —— 与 BSC 链上格式一致
const c = RLP.encode([0, vals.map(v => [buf(v.consensus), buf(v.bscFee), buf(v.fee), Buffer.from([Number(v.power)])])]).toString('hex');
fs.writeFileSync('.baseline/_js_c.hex', c);
console.log('C) 长度:', c.length/2, '字节  前 40:', c.slice(0,40));
console.log('rlp 版本:', require('rlp/package.json').version);
